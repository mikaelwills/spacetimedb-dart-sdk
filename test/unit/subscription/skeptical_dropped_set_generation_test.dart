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

Uint8List _createUnsubscribeApplied({
  required int requestId,
  required int querySetId,
}) {
  final encoder = BsatnEncoder();
  encoder.writeU8(0);
  encoder.writeU8(2);
  encoder.writeU32(requestId);
  encoder.writeU32(querySetId);
  encoder.writeU8(1);
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
  group('S4 — a query set retired mid-reconnect must not strand its rows', () {
    late MockConnection mockConnection;
    late SubscriptionManager subscriptionManager;

    setUp(() {
      mockConnection = MockConnection();
      subscriptionManager = SubscriptionManager(mockConnection);
      subscriptionManager.cache.registerDecoder<String>(
        'sa',
        _JsonStringDecoder(),
      );
      subscriptionManager.cache.registerDecoder<String>(
        'sb',
        _JsonStringDecoder(),
      );
    });

    tearDown(() async {
      await subscriptionManager.dispose();
    });

    test('rows whose only owner set is dropped during the resubscribe window '
        'are evicted, not stranded as permanently immortal', () async {
      final sa = subscriptionManager.cache.getTableByName('sa');
      final sb = subscriptionManager.cache.getTableByName('sb');
      if (sa == null || sb == null) fail('tables not registered');

      await mockConnection.connect();

      final pendingA = subscriptionManager.subscribe(['SELECT * FROM sa']);
      mockConnection.simulateIncoming(
        _createSubscribeApplied(
          requestId: 0,
          querySetId: 1,
          rowsByTable: {
            'sa': ['a1'],
          },
        ),
      );
      await pendingA.timeout(_timeout);

      final pendingB = subscriptionManager.subscribe(['SELECT * FROM sb']);
      mockConnection.simulateIncoming(
        _createSubscribeApplied(
          requestId: 1,
          querySetId: 2,
          rowsByTable: {
            'sb': ['b1'],
          },
        ),
      );
      await pendingB.timeout(_timeout);

      expect(sa.iter(), contains('a1'));
      expect(sb.iter(), contains('b1'));

      await mockConnection.disconnect();
      await mockConnection.connect();
      await pumpEventQueue();

      expect(
        sa.ownedKeys('a1'),
        isNotEmpty,
        reason: 'a1 is state (b) pending-reclaim while the generation is open',
      );

      mockConnection.simulateIncoming(
        _createUnsubscribeApplied(requestId: 2, querySetId: 1),
      );
      await pumpEventQueue();

      mockConnection.simulateIncoming(
        _createSubscribeApplied(
          requestId: 1,
          querySetId: 2,
          rowsByTable: {
            'sb': ['b1'],
          },
        ),
      );
      await pumpEventQueue();
      await pumpEventQueue();

      expect(
        sb.iter(),
        contains('b1'),
        reason: 'set 2 re-applied and re-claimed b1',
      );

      expect(
        sa.ownedKeys('a1'),
        isEmpty,
        reason:
            'S4 CORE (ownership half): query set 1 was retired by '
            'UnsubscribeApplied while the reconnect generation was open. '
            'dropQuerySet only walks _rowOwners, which is empty for a1 mid '
            'generation, so set 1 is never stripped from a1\'s entry in '
            '_previousOwners. finalizeReconnectGeneration then clears '
            '_previousOwners wholesale, so a1 is left with no owner record in '
            'either map while its row stays in _rowsByPrimaryKey — a row no '
            'query set can ever reclaim and no eviction path can ever reach.',
      );

      expect(
        sa.iter(),
        isNot(contains('a1')),
        reason:
            'S4 CORE (row half): a1\'s only owning set was dropped, so the row '
            'must be evicted exactly as dropQuerySet would have evicted it '
            'outside the reconnect window. Retaining it makes the row '
            'immortal: retainWhere sees set 1 in a1\'s previous-owner set, '
            'set 1 is no longer in liveSetIds, so !owners.any(live) is true '
            'and the row is spared — then _previousOwners.clear() destroys '
            'the only remaining record that it was ever owned.',
      );
    });
  });
}
