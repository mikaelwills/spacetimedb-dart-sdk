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
  group('reconnect eviction spares rows no query set ever owned', () {
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

    test(
      'cache-loaded rows in an unsubscribed table survive a reconnect',
      () async {
        final uncovered = subscriptionManager.cache.getTableByName('uncovered');
        final covered = subscriptionManager.cache.getTableByName('covered');
        if (uncovered == null || covered == null) fail('tables not registered');

        uncovered.loadFromSerializable([
          {'v': 'm1'},
          {'v': 'm2'},
        ]);
        expect(uncovered.iter(), containsAll(['m1', 'm2']));
        expect(
          uncovered.ownedKeys('m1'),
          isEmpty,
          reason: 'the disk-load path leaves rows with zero query-set owners',
        );

        await mockConnection.connect();
        final pending = subscriptionManager.subscribe([
          'SELECT * FROM covered',
        ]);
        mockConnection.simulateIncoming(
          _createSubscribeApplied(
            requestId: 0,
            querySetId: 1,
            rowsByTable: {
              'covered': ['c1'],
            },
          ),
        );
        await pending.timeout(_timeout);
        expect(covered.iter(), contains('c1'));

        await mockConnection.disconnect();
        await mockConnection.connect();
        await pumpEventQueue();
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
          subscriptionManager.subscriptionsReady.value,
          isTrue,
          reason: 'the reconnect must have fully resubscribed and evicted',
        );
        expect(covered.iter(), contains('c1'));
        expect(
          uncovered.iter(),
          containsAll(['m1', 'm2']),
          reason:
              'rows that no query set owned before the reconnect were never '
              'subscription-delivered, so their absence from the re-delivered '
              'set carries no information and must not evict them',
        );
      },
    );

    test('a skipped eviction carries its candidates to the next reconnect, '
        'but cache-loaded rows are still never candidates', () async {
      final uncovered = subscriptionManager.cache.getTableByName('uncovered');
      final covered = subscriptionManager.cache.getTableByName('covered');
      if (uncovered == null || covered == null) fail('tables not registered');

      uncovered.loadFromSerializable([
        {'v': 'm1'},
      ]);

      await mockConnection.connect();
      final first = subscriptionManager.subscribe(['SELECT * FROM covered']);
      final second = subscriptionManager.subscribe([
        "SELECT * FROM covered WHERE v = 'c1'",
      ]);
      mockConnection.simulateIncoming(
        _createSubscribeApplied(
          requestId: 0,
          querySetId: 1,
          rowsByTable: {
            'covered': ['c1', 'c2'],
          },
        ),
      );
      mockConnection.simulateIncoming(
        _createSubscribeApplied(
          requestId: 0,
          querySetId: 2,
          rowsByTable: {
            'covered': ['c1'],
          },
        ),
      );
      await Future.wait([first, second]).timeout(_timeout);

      await mockConnection.disconnect();
      await mockConnection.connect();
      await pumpEventQueue();
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
      await mockConnection.disconnect();
      await pumpEventQueue();

      expect(
        covered.iter(),
        containsAll(['c1', 'c2']),
        reason: 'the incomplete reconnect must skip eviction entirely',
      );

      await mockConnection.connect();
      await pumpEventQueue();
      mockConnection.simulateIncoming(
        _createSubscribeApplied(
          requestId: 0,
          querySetId: 1,
          rowsByTable: {
            'covered': ['c1'],
          },
        ),
      );
      mockConnection.simulateIncoming(
        _createSubscribeApplied(
          requestId: 0,
          querySetId: 2,
          rowsByTable: {
            'covered': ['c1'],
          },
        ),
      );
      await pumpEventQueue();

      expect(
        covered.iter(),
        isNot(contains('c2')),
        reason:
            'c2 was owned before the skipped reconnect; clearOwners() already '
            'stripped its owner, so the candidate must be carried forward or '
            'it becomes permanently unevictable',
      );
      expect(covered.iter(), contains('c1'));
      expect(
        uncovered.iter(),
        contains('m1'),
        reason:
            'the carry-forward must not sweep up rows that never had an owner',
      );
    });

    test(
      'rows a query set DID own are still evicted when not re-delivered',
      () async {
        final covered = subscriptionManager.cache.getTableByName('covered');
        if (covered == null) fail('tables not registered');

        await mockConnection.connect();
        final pending = subscriptionManager.subscribe([
          'SELECT * FROM covered',
        ]);
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

        expect(covered.iter(), contains('c1'));
        expect(
          covered.iter(),
          isNot(contains('c2')),
          reason:
              'c2 was owned by query set 1 and was not re-delivered, so it was '
              'deleted server-side while disconnected and must be evicted',
        );
      },
    );
  });
}
