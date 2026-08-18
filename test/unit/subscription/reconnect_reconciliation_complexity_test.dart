import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:spacetimedb_sdk/codegen.dart';

import '../../mocks/mock_connection.dart';

const _timeout = Duration(seconds: 30);

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

class _CountingDecoder extends RowDecoder<String> {
  int primaryKeyReads = 0;

  @override
  String decode(BsatnDecoder decoder) => decoder.readString();

  @override
  dynamic getPrimaryKey(String row) {
    primaryKeyReads++;
    return row;
  }

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

String _pk(String prefix, int i) => '$prefix${i.toString().padLeft(9, '0')}';

void main() {
  group('reconnect reconciliation is independent of rows held', () {
    late MockConnection mockConnection;
    late SubscriptionManager subscriptionManager;
    late _CountingDecoder liveDecoder;
    late _CountingDecoder bulkDecoder;

    tearDown(() async {
      await subscriptionManager.dispose();
    });

    Future<({int liveOps, int bulkOps, int micros})> measureReconnect({
      required int bulkHeld,
      required int liveRows,
      required int deletedOnServer,
    }) async {
      mockConnection = MockConnection();
      subscriptionManager = SubscriptionManager(mockConnection);
      liveDecoder = _CountingDecoder();
      bulkDecoder = _CountingDecoder();
      subscriptionManager.cache.registerDecoder<String>('live', liveDecoder);
      subscriptionManager.cache.registerDecoder<String>('bulk', bulkDecoder);
      final live = subscriptionManager.cache.getTableByName('live');
      final bulk = subscriptionManager.cache.getTableByName('bulk');
      if (live == null || bulk == null) fail('tables not registered');

      final liveKeys = [for (var i = 0; i < liveRows; i++) _pk('live', i)];
      final bulkKeys = [for (var i = 0; i < bulkHeld; i++) _pk('bulk', i)];

      await mockConnection.connect();
      final pendingLive = subscriptionManager.subscribe(['SELECT * FROM live']);
      mockConnection.simulateIncoming(
        _createSubscribeApplied(
          requestId: 0,
          querySetId: 1,
          rowsByTable: {'live': liveKeys},
        ),
      );
      await pendingLive.timeout(_timeout);

      final pendingBulk = subscriptionManager.subscribe(['SELECT * FROM bulk']);
      mockConnection.simulateIncoming(
        _createSubscribeApplied(
          requestId: 0,
          querySetId: 2,
          rowsByTable: {'bulk': bulkKeys},
        ),
      );
      await pendingBulk.timeout(_timeout);

      expect(live.count(), liveRows);
      expect(bulk.count(), bulkHeld);

      await mockConnection.disconnect();
      await mockConnection.connect();
      await pumpEventQueue();

      liveDecoder.primaryKeyReads = 0;
      bulkDecoder.primaryKeyReads = 0;

      final sw = Stopwatch()..start();
      mockConnection.simulateIncoming(
        _createSubscribeApplied(
          requestId: 0,
          querySetId: 1,
          rowsByTable: {'live': liveKeys.sublist(deletedOnServer)},
        ),
      );
      await pumpEventQueue();
      mockConnection.simulateIncoming(
        _createSubscribeApplied(
          requestId: 0,
          querySetId: 2,
          rowsByTable: {'bulk': bulkKeys},
        ),
      );
      await pumpEventQueue();
      sw.stop();

      expect(
        live.count(),
        liveRows - deletedOnServer,
        reason: 'rows the server stopped reporting are still reclaimed',
      );
      expect(
        bulk.count(),
        bulkHeld,
        reason: 'fully re-delivered rows all survive',
      );

      return (
        liveOps: liveDecoder.primaryKeyReads,
        bulkOps: bulkDecoder.primaryKeyReads,
        micros: sw.elapsedMicroseconds,
      );
    }

    Future<({int liveOps, int idleOps, int micros})> measureIdleSibling({
      required int idleHeld,
    }) async {
      mockConnection = MockConnection();
      subscriptionManager = SubscriptionManager(mockConnection);
      liveDecoder = _CountingDecoder();
      bulkDecoder = _CountingDecoder();
      subscriptionManager.cache.registerDecoder<String>('live', liveDecoder);
      subscriptionManager.cache.registerDecoder<String>('bulk', bulkDecoder);
      final live = subscriptionManager.cache.getTableByName('live');
      final idle = subscriptionManager.cache.getTableByName('bulk');
      if (live == null || idle == null) fail('tables not registered');

      final liveKeys = [for (var i = 0; i < 500; i++) _pk('live', i)];

      await mockConnection.connect();
      final pendingLive = subscriptionManager.subscribe(['SELECT * FROM live']);
      mockConnection.simulateIncoming(
        _createSubscribeApplied(
          requestId: 0,
          querySetId: 1,
          rowsByTable: {'live': liveKeys},
        ),
      );
      await pendingLive.timeout(_timeout);

      final pendingIdle = subscriptionManager.subscribe(['SELECT * FROM bulk']);
      mockConnection.simulateIncoming(
        _createSubscribeApplied(
          requestId: 0,
          querySetId: 2,
          rowsByTable: {
            'bulk': [for (var i = 0; i < idleHeld; i++) _pk('idle', i)],
          },
        ),
      );
      await pendingIdle.timeout(_timeout);
      expect(idle.count(), idleHeld);
      subscriptionManager.forgetQuerySet(2);

      await mockConnection.disconnect();

      liveDecoder.primaryKeyReads = 0;
      bulkDecoder.primaryKeyReads = 0;

      final sw = Stopwatch()..start();
      await mockConnection.connect();
      await pumpEventQueue();
      mockConnection.simulateIncoming(
        _createSubscribeApplied(
          requestId: 0,
          querySetId: 1,
          rowsByTable: {'live': liveKeys.sublist(50)},
        ),
      );
      await pumpEventQueue();
      sw.stop();

      expect(
        idle.count(),
        idleHeld,
        reason:
            'the idle table\'s query set was forgotten, so no live set can '
            'speak for its rows. Their absence from the re-delivered data '
            'carries no information and every one of them must survive.',
      );
      expect(
        live.count(),
        450,
        reason: 'the live table still reconciles normally',
      );

      return (
        liveOps: liveDecoder.primaryKeyReads,
        idleOps: bulkDecoder.primaryKeyReads,
        micros: sw.elapsedMicroseconds,
      );
    }

    test(
      'the reconciliation cost of a table is set by what the server '
      'reported and what was evicted, never by how many rows it holds',
      () async {
        final small = await measureReconnect(
          bulkHeld: 5000,
          liveRows: 500,
          deletedOnServer: 50,
        );
        await subscriptionManager.dispose();
        final large = await measureReconnect(
          bulkHeld: 200000,
          liveRows: 500,
          deletedOnServer: 50,
        );

        // ignore: avoid_print
        print(
          'RECONCILIATION OPS on the "live" table (500 rows held, 450 '
          'reported, 50 evicted), while a sibling table holds:\n'
          '  bulk=5000   -> live table cost ${small.liveOps} ops\n'
          '  bulk=200000 -> live table cost ${large.liveOps} ops\n'
          'sibling bulk table cost: ${small.bulkOps} vs ${large.bulkOps} ops '
          '(scales with what the server RE-REPORTED for it, by construction)',
        );

        expect(
          large.liveOps,
          equals(small.liveOps),
          reason:
              'the live table holds the same 500 rows in both runs. A 40x '
              'increase in rows held ELSEWHERE in the cache must not change its '
              'reconciliation cost by a single op. Under the old code the '
              'oldKeysByTable build read table.primaryKeys for EVERY table and '
              'the eviction ran removeRowsWhere over the full key space, so '
              'this number tracked total rows held.',
        );
      },
    );

    test('a table with no live query set is not visited at all, however many '
        'rows it holds', () async {
      final small = await measureIdleSibling(idleHeld: 5000);
      await subscriptionManager.dispose();
      final large = await measureIdleSibling(idleHeld: 500000);

      // ignore: avoid_print
      print(
        'FORGOTTEN-SET SIBLING (rows owned by a set that was forgotten):\n'
        '  holds 5000   -> ${small.idleOps} row decodes, '
        'reconnect took ${small.micros}us\n'
        '  holds 500000 -> ${large.idleOps} row decodes, '
        'reconnect took ${large.micros}us',
      );

      expect(
        small.idleOps,
        0,
        reason:
            'no reconnect work may decode rows of a table nothing '
            're-subscribed',
      );
      expect(
        large.idleOps,
        0,
        reason:
            'the old code read table.primaryKeys for every table and then ran '
            'removeRowsWhere over the full key space; both are gone from the '
            'reconnect path',
      );
    });

    test('opening a generation over disk-loaded rows is free regardless of how '
        'many there are', () async {
      mockConnection = MockConnection();
      subscriptionManager = SubscriptionManager(mockConnection);
      bulkDecoder = _CountingDecoder();
      subscriptionManager.cache.registerDecoder<String>('bulk', bulkDecoder);
      final bulk = subscriptionManager.cache.getTableByName('bulk');
      if (bulk == null) fail('table not registered');

      bulk.loadFromSerializable([
        for (var i = 0; i < 500000; i++) {'v': _pk('disk', i)},
      ]);
      expect(bulk.count(), 500000);

      final sw = Stopwatch()..start();
      bulk.beginReconnectGeneration();
      final beginMicros = sw.elapsedMicroseconds;
      sw.reset();
      final evicted = bulk.finalizeReconnectGeneration();
      final finalizeMicros = sw.elapsedMicroseconds;

      // ignore: avoid_print
      print(
        'GENERATION OVER 500000 DISK-LOADED ROWS: '
        'begin=${beginMicros}us finalize=${finalizeMicros}us '
        'evicted=$evicted',
      );

      expect(evicted, 0);
      expect(bulk.count(), 500000);
      expect(
        bulk.pendingOwnerEntryCount,
        0,
        reason:
            'disk-loaded rows are unowned, so opening a generation copies '
            'nothing and the whole cycle is O(1) in rows held. This is the '
            'SpaceNotes shape: a large offline cache with no live query set.',
      );
    });
  });
}
