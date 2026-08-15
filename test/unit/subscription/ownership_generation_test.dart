import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:spacetimedb_sdk/codegen.dart';

import '../../mocks/mock_connection.dart';

const _timeout = Duration(seconds: 2);

Uint8List _createSubscribeApplied({
  required int requestId,
  required int querySetId,
  Map<String, List<String>> rowsByTable = const {},
}) {
  final encoder = BsatnEncoder();
  encoder.writeU8(0);
  encoder.writeU8(1);
  encoder.writeU32(requestId);
  encoder.writeU32(querySetId);
  encoder.writeU32(rowsByTable.length);
  for (final entry in rowsByTable.entries) {
    encoder.writeString(entry.key);
    encoder.writeU8(0);
    final rowsEncoder = BsatnEncoder();
    for (final row in entry.value) {
      rowsEncoder.writeString(row);
    }
    final rowsData = rowsEncoder.toBytes();
    final rowSize =
        entry.value.isEmpty ? 0 : rowsData.length ~/ entry.value.length;
    encoder.writeU16(rowSize);
    encoder.writeU32(rowsData.length);
    encoder.writeBytes(rowsData);
  }
  return encoder.toBytes();
}

class _JsonStringDecoder extends RowDecoder<String> {
  @override
  String decode(BsatnDecoder decoder) => decoder.readString();

  @override
  dynamic getPrimaryKey(String row) => row;

  @override
  bool get supportsJsonSerialization => true;

  @override
  Map<String, dynamic>? toJson(String row) => {'v': row};

  @override
  String? fromJson(Map<String, dynamic> json) {
    final value = json['v'];
    return value is String ? value : null;
  }
}

void main() {
  group('P1 — a disk-loaded row and a pending-reclaim row are distinguishable', () {
    late MockConnection mockConnection;
    late SubscriptionManager subscriptionManager;

    setUp(() {
      mockConnection = MockConnection();
      subscriptionManager = SubscriptionManager(mockConnection);
      subscriptionManager.cache.registerDecoder<String>(
        'covered',
        _JsonStringDecoder(),
      );
      subscriptionManager.cache.registerDecoder<String>(
        'uncovered',
        _JsonStringDecoder(),
      );
    });

    tearDown(() async {
      await subscriptionManager.dispose();
    });

    test('disk-loaded rows survive while a genuinely deleted owned row is '
        'still reclaimed, and the two are told apart by ownership not by '
        'guesswork', () async {
      final uncovered = subscriptionManager.cache.getTableByName('uncovered');
      final covered = subscriptionManager.cache.getTableByName('covered');
      if (uncovered == null || covered == null) fail('tables not registered');

      uncovered.loadFromSerializable([
        {'v': 'd1'},
        {'v': 'd2'},
      ]);

      await mockConnection.connect();
      final pending = subscriptionManager.subscribe(['SELECT * FROM covered']);
      mockConnection.simulateIncoming(
        _createSubscribeApplied(
          requestId: 0,
          querySetId: 1,
          rowsByTable: {
            'covered': ['c1', 'c2'],
          },
        ),
      );
      await pending.timeout(_timeout);
      expect(covered.iter(), containsAll(['c1', 'c2']));

      await mockConnection.disconnect();
      await mockConnection.connect();
      await pumpEventQueue();

      expect(
        covered.ownedKeys('c1'),
        isNotEmpty,
        reason:
            'P1 CORE: mid-resubscribe, c1 was owned by query set 1 before the '
            'reconnect and has not yet been re-claimed. It is state (b) '
            '"pending". A disk-loaded row is state (c) "never subscribed". '
            'Today clearOwners() collapses both to isEmpty, so the eviction '
            'decision cannot tell them apart and is a guess.',
      );
      expect(
        uncovered.ownedKeys('d1'),
        isEmpty,
        reason:
            'a disk-loaded row must remain unowned — this is the other half of '
            'the distinction and is what the consumer test pins',
      );

      mockConnection.simulateIncoming(
        _createSubscribeApplied(
          requestId: 0,
          querySetId: 1,
          rowsByTable: {
            'covered': ['c1'],
          },
        ),
      );
      await pumpEventQueue();

      expect(
        covered.iter(),
        contains('c1'),
        reason: 're-delivered rows stay',
      );
      expect(
        covered.iter(),
        isNot(contains('c2')),
        reason:
            'c2 was genuinely owned and was not re-delivered, so it was '
            'deleted server-side and must still be reclaimed',
      );
      expect(
        uncovered.iter(),
        containsAll(['d1', 'd2']),
        reason: 'disk-loaded rows were never subscription-delivered and survive',
      );
    });
  });

  group('P2 — a connection bounce during the resubscribe window', () {
    late MockConnection mockConnection;
    late SubscriptionManager subscriptionManager;

    setUp(() {
      mockConnection = MockConnection();
      subscriptionManager = SubscriptionManager(mockConnection);
      subscriptionManager.cache.registerDecoder<String>(
        'ta',
        _JsonStringDecoder(),
      );
    });

    tearDown(() async {
      await subscriptionManager.dispose();
    });

    test('a Disconnected/Connected bounce mid-resubscribe must not evict rows '
        'the server never deleted', () async {
      final ta = subscriptionManager.cache.getTableByName('ta');
      if (ta == null) fail('table not registered');

      await mockConnection.connect();
      final pending = subscriptionManager.subscribe(['SELECT * FROM ta']);
      mockConnection.simulateIncoming(
        _createSubscribeApplied(
          requestId: 0,
          querySetId: 1,
          rowsByTable: {
            'ta': ['a1'],
          },
        ),
      );
      await pending.timeout(_timeout);
      expect(ta.iter(), contains('a1'));

      await mockConnection.disconnect();
      await pumpEventQueue();
      await mockConnection.connect();
      await pumpEventQueue();

      mockConnection.mockState = const Disconnected();
      mockConnection.mockState = const Connected();
      await pumpEventQueue();
      await pumpEventQueue();

      expect(
        ta.iter(),
        contains('a1'),
        reason:
            'P2 CORE: the bounce force-completed reconnect #1\'s subscribe '
            'waiter via _completeAllSubscribeWaiters(), so its future resolved '
            'true and allResubscribed stayed true; the gate also reads '
            '_connection.isConnected, already Connected again after the '
            'bounce. Eviction therefore ran against ownership that '
            'clearOwners() wiped and no SubscribeApplied rebuilt. The server '
            'deleted nothing.',
      );
    });
    test('a finalized generation leaves no skips recorded', () async {
      final ta = subscriptionManager.cache.getTableByName('ta');
      if (ta == null) fail('table not registered');

      await mockConnection.connect();
      final pending = subscriptionManager.subscribe(['SELECT * FROM ta']);
      mockConnection.simulateIncoming(
        _createSubscribeApplied(
          requestId: 0,
          querySetId: 1,
          rowsByTable: {
            'ta': ['a1'],
          },
        ),
      );
      await pending.timeout(_timeout);

      mockConnection.mockState = const Disconnected();
      mockConnection.mockState = const Connected();
      await pumpEventQueue();
      await pumpEventQueue();

      expect(subscriptionManager.consecutiveEvictionSkips, 0);
      expect(ta.iter(), contains('a1'));
    });
  });

  group('P3 — ownership guards stay live during the resubscribe window', () {
    late MockConnection mockConnection;
    late SubscriptionManager subscriptionManager;

    setUp(() {
      mockConnection = MockConnection();
      subscriptionManager = SubscriptionManager(mockConnection);
      subscriptionManager.cache.registerDecoder<String>(
        'guarded',
        _JsonStringDecoder(),
      );
    });

    tearDown(() async {
      await subscriptionManager.dispose();
    });

    test('ownedKeys answers from the previous generation for a row that has '
        'not yet been re-claimed', () async {
      final guarded = subscriptionManager.cache.getTableByName('guarded');
      if (guarded == null) fail('table not registered');

      await mockConnection.connect();
      final pending = subscriptionManager.subscribe([
        'SELECT * FROM guarded',
      ]);
      mockConnection.simulateIncoming(
        _createSubscribeApplied(
          requestId: 0,
          querySetId: 1,
          rowsByTable: {
            'guarded': ['g1'],
          },
        ),
      );
      await pending.timeout(_timeout);
      expect(guarded.ownedKeys('g1'), isNotEmpty);

      await mockConnection.disconnect();
      await mockConnection.connect();
      await pumpEventQueue();

      expect(
        guarded.ownedKeys('g1'),
        isNotEmpty,
        reason:
            'P3 CORE: g1 was server-delivered before the reconnect and no '
            'SubscribeApplied has arrived yet. Every ownership-based guard in '
            'the SDK — notably the _confirmSelfCommit cleanup guard whose '
            'whole job is to distinguish "only we believed in this row" from '
            '"the server delivered it" — reads isEmpty here today and so goes '
            'inert for the entire resubscribe window.',
      );
    });
  });
}
