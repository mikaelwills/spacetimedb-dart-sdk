import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:spacetimedb_sdk/codegen.dart';

import '../../generated/folder.dart';
import '../../mocks/mock_connection.dart';

const _timeout = Duration(seconds: 2);

void _writeFolderRowList(BsatnEncoder encoder, List<Folder> folders) {
  final encodedRows =
      folders.map((folder) {
        final rowEncoder = BsatnEncoder();
        folder.encodeBsatn(rowEncoder);
        return rowEncoder.toBytes();
      }).toList();

  final offsets = <int>[];
  var currentOffset = 0;
  for (final row in encodedRows) {
    offsets.add(currentOffset);
    currentOffset += row.length;
  }

  encoder.writeU8(1);
  encoder.writeU32(offsets.length);
  for (final offset in offsets) {
    encoder.writeU64(Int64(offset));
  }

  final combined = Uint8List(currentOffset);
  var writeOffset = 0;
  for (final row in encodedRows) {
    combined.setRange(writeOffset, writeOffset + row.length, row);
    writeOffset += row.length;
  }
  encoder.writeU32(combined.length);
  encoder.writeBytes(combined);
}

Uint8List _createSubscribeApplied({
  required int requestId,
  required int querySetId,
  Map<String, List<Folder>> rowsByTable = const {},
}) {
  final encoder = BsatnEncoder();
  encoder.writeU8(0);
  encoder.writeU8(1);
  encoder.writeU32(requestId);
  encoder.writeU32(querySetId);

  encoder.writeU32(rowsByTable.length);
  for (final entry in rowsByTable.entries) {
    encoder.writeString(entry.key);
    _writeFolderRowList(encoder, entry.value);
  }

  return encoder.toBytes();
}

Uint8List _createSubscribeAppliedWithSlices({
  required int requestId,
  required int querySetId,
  required List<MapEntry<String, List<Folder>>> slices,
}) {
  final encoder = BsatnEncoder();
  encoder.writeU8(0);
  encoder.writeU8(1);
  encoder.writeU32(requestId);
  encoder.writeU32(querySetId);

  encoder.writeU32(slices.length);
  for (final slice in slices) {
    encoder.writeString(slice.key);
    _writeFolderRowList(encoder, slice.value);
  }

  return encoder.toBytes();
}

Uint8List _createReducerResultCommitted({
  required int requestId,
  required int querySetId,
  required String tableName,
  List<Folder> inserts = const [],
  List<Folder> deletes = const [],
}) {
  final encoder = BsatnEncoder();
  encoder.writeU8(0);
  encoder.writeU8(6);

  encoder.writeU32(requestId);
  encoder.writeU64(Int64(0));

  encoder.writeU8(0);
  encoder.writeU32(0);

  encoder.writeU32(1);
  encoder.writeU32(querySetId);

  encoder.writeU32(1);
  encoder.writeString(tableName);

  encoder.writeU32(1);
  encoder.writeU8(0);
  _writeFolderRowList(encoder, inserts);
  _writeFolderRowList(encoder, deletes);

  return encoder.toBytes();
}

Uint8List _createReducerResultFailed({
  required int requestId,
  required String message,
}) {
  final encoder = BsatnEncoder();
  encoder.writeU8(0);
  encoder.writeU8(6);

  encoder.writeU32(requestId);
  encoder.writeU64(Int64(0));

  encoder.writeU8(2);
  final messageBytes = Uint8List.fromList(message.codeUnits);
  encoder.writeU32(messageBytes.length);
  encoder.writeBytes(messageBytes);

  return encoder.toBytes();
}

Uint8List _createTransactionUpdate({
  required int querySetId,
  required String tableName,
  List<Folder> inserts = const [],
  List<Folder> deletes = const [],
}) {
  final encoder = BsatnEncoder();
  encoder.writeU8(0);
  encoder.writeU8(4);

  encoder.writeU32(1);
  encoder.writeU32(querySetId);

  encoder.writeU32(1);
  encoder.writeString(tableName);

  encoder.writeU32(1);
  encoder.writeU8(0);
  _writeFolderRowList(encoder, inserts);
  _writeFolderRowList(encoder, deletes);

  return encoder.toBytes();
}

Uint8List _createUnsubscribeApplied({
  required int requestId,
  required int querySetId,
  Map<String, List<Folder>>? droppedRowsByTable,
}) {
  final encoder = BsatnEncoder();
  encoder.writeU8(0);
  encoder.writeU8(2);
  encoder.writeU32(requestId);
  encoder.writeU32(querySetId);

  if (droppedRowsByTable == null) {
    encoder.writeU8(1);
  } else {
    encoder.writeU8(0);
    encoder.writeU32(droppedRowsByTable.length);
    for (final entry in droppedRowsByTable.entries) {
      encoder.writeString(entry.key);
      _writeFolderRowList(encoder, entry.value);
    }
  }

  return encoder.toBytes();
}

class _StringDecoder extends RowDecoder<String> {
  @override
  String decode(BsatnDecoder decoder) => decoder.readString();

  @override
  dynamic getPrimaryKey(String row) => row;
}

class _ThrowingDecoder extends RowDecoder<String> {
  @override
  String decode(BsatnDecoder decoder) => throw StateError('decode boom');

  @override
  dynamic getPrimaryKey(String row) => row;
}

Uint8List _encodeStrRowsData(List<String> rows) {
  final encoder = BsatnEncoder();
  for (final row in rows) {
    encoder.writeString(row);
  }
  return encoder.toBytes();
}

void _writeStrBsatnRowList(BsatnEncoder encoder, List<String> rows) {
  encoder.writeU8(0);
  final rowsData = _encodeStrRowsData(rows);
  final rowSize = rows.isEmpty ? 0 : rowsData.length ~/ rows.length;
  encoder.writeU16(rowSize);
  encoder.writeU32(rowsData.length);
  encoder.writeBytes(rowsData);
}

void _writeStrQueryRows(
  BsatnEncoder encoder,
  Map<String, List<String>> rowsByTable,
) {
  encoder.writeU32(rowsByTable.length);
  for (final entry in rowsByTable.entries) {
    encoder.writeString(entry.key);
    _writeStrBsatnRowList(encoder, entry.value);
  }
}

Uint8List _createStrSubscribeApplied({
  required int requestId,
  required int querySetId,
  Map<String, List<String>> rowsByTable = const {},
}) {
  final encoder = BsatnEncoder();
  encoder.writeU8(0);
  encoder.writeU8(1);
  encoder.writeU32(requestId);
  encoder.writeU32(querySetId);
  _writeStrQueryRows(encoder, rowsByTable);
  return encoder.toBytes();
}

Uint8List _createStrTransactionUpdate({
  required int querySetId,
  required String tableName,
  List<String> inserts = const [],
  List<String> deletes = const [],
}) {
  final encoder = BsatnEncoder();
  encoder.writeU8(0);
  encoder.writeU8(4);

  encoder.writeU32(1);
  encoder.writeU32(querySetId);

  encoder.writeU32(1);
  encoder.writeString(tableName);

  encoder.writeU32(1);
  encoder.writeU8(0);
  _writeStrBsatnRowList(encoder, inserts);
  _writeStrBsatnRowList(encoder, deletes);

  return encoder.toBytes();
}

void main() {
  group('optimistic-confirm with client-chosen pk', () {
    late MockConnection mockConnection;
    late SubscriptionManager subscriptionManager;

    setUp(() {
      mockConnection = MockConnection();
      subscriptionManager = SubscriptionManager(
        mockConnection,
        offlineStorage: InMemoryOfflineStorage(),
      );
      subscriptionManager.cache.registerDecoder<Folder>(
        'folder',
        FolderDecoder(),
      );
    });

    tearDown(() async {
      await subscriptionManager.dispose();
    });

    test(
      'an optimistic insert with a client-chosen pk is tagged on confirm '
      'and survives a later unrelated query-set apply on the same table',
      () async {
        mockConnection.mockState = const Connected();

        final subscribeA = subscriptionManager.subscribe([
          "SELECT * FROM folder WHERE path LIKE '/a/%'",
        ]);
        mockConnection.simulateIncoming(
          _createSubscribeApplied(requestId: 0, querySetId: 1),
        );
        await subscribeA.timeout(_timeout);

        final newFolder = Folder(
          path: '/a/new-folder',
          name: 'New Folder',
          createdAt: Int64(0),
        );

        unawaited(
          subscriptionManager.reducers.call(
            'create_folder',
            Uint8List(0),
            optimisticChanges: [
              OptimisticChange.insert('folder', newFolder.toJson()),
            ],
          ),
        );
        await pumpEventQueue();

        final table = subscriptionManager.cache.getTableByName('folder');
        if (table == null) fail('folder table was not registered');
        expect(table.iter().map((f) => f.path), contains('/a/new-folder'));

        final numericRequestId = mockConnection.getLastSentRequestId();

        mockConnection.simulateIncoming(
          _createReducerResultCommitted(
            requestId: numericRequestId,
            querySetId: 1,
            tableName: 'folder',
            inserts: [newFolder],
          ),
        );
        await pumpEventQueue();

        expect(table.iter().map((f) => f.path), contains('/a/new-folder'));

        final subscribeB = subscriptionManager.subscribe([
          "SELECT * FROM folder WHERE path LIKE '/b/%'",
        ]);
        mockConnection.simulateIncoming(
          _createSubscribeApplied(requestId: 0, querySetId: 2),
        );
        await subscribeB.timeout(_timeout);

        expect(table.iter().map((f) => f.path), contains('/a/new-folder'));
      },
    );
  });

  group('optimistic-delete confirm', () {
    late MockConnection mockConnection;
    late SubscriptionManager subscriptionManager;

    setUp(() {
      mockConnection = MockConnection();
      subscriptionManager = SubscriptionManager(
        mockConnection,
        offlineStorage: InMemoryOfflineStorage(),
      );
      subscriptionManager.cache.registerDecoder<Folder>(
        'folder',
        FolderDecoder(),
      );
    });

    tearDown(() async {
      await subscriptionManager.dispose();
    });

    test(
      'an optimistic delete confirmed via the short-circuit path removes '
      'its provenance entry instead of leaking it',
      () async {
        mockConnection.mockState = const Connected();

        final seedFolder = Folder(
          path: '/a/existing',
          name: 'Existing',
          createdAt: Int64(0),
        );

        final subscribeA = subscriptionManager.subscribe([
          "SELECT * FROM folder WHERE path LIKE '/a/%'",
        ]);
        mockConnection.simulateIncoming(
          _createSubscribeApplied(
            requestId: 0,
            querySetId: 1,
            rowsByTable: {
              'folder': [seedFolder],
            },
          ),
        );
        await subscribeA.timeout(_timeout);

        final table = subscriptionManager.cache.getTableByName('folder');
        if (table == null) fail('folder table was not registered');
        expect(table.iter().map((f) => f.path), contains('/a/existing'));

        final baselineCount = subscriptionManager.rowProvenanceCountForTable(
          'folder',
        );
        expect(baselineCount, greaterThan(0));

        unawaited(
          subscriptionManager.reducers.call(
            'delete_folder',
            Uint8List(0),
            optimisticChanges: [
              OptimisticChange.delete('folder', seedFolder.toJson()),
            ],
          ),
        );
        await pumpEventQueue();

        expect(
          table.iter().map((f) => f.path),
          isNot(contains('/a/existing')),
        );

        final numericRequestId = mockConnection.getLastSentRequestId();

        mockConnection.simulateIncoming(
          _createReducerResultCommitted(
            requestId: numericRequestId,
            querySetId: 1,
            tableName: 'folder',
            deletes: [seedFolder],
          ),
        );
        await pumpEventQueue();

        expect(
          subscriptionManager.rowProvenanceCountForTable('folder'),
          equals(baselineCount - 1),
        );
      },
    );
  });

  group('T1 — optimistic UPDATE pending across reconnect (R3F1)', () {
    late MockConnection mockConnection;
    late SubscriptionManager subscriptionManager;

    setUp(() {
      mockConnection = MockConnection();
      subscriptionManager = SubscriptionManager(
        mockConnection,
        offlineStorage: InMemoryOfflineStorage(),
      );
      subscriptionManager.cache.registerDecoder<Folder>(
        'folder',
        FolderDecoder(),
      );
    });

    tearDown(() async {
      await subscriptionManager.dispose();
    });

    test(
      'variant (a): optimistic update pending across reconnect, resubscribe '
      'snapshot contains X-old while protected, confirms via short-circuit; '
      'a later narrower subscribe on the same table must not evict',
      () async {
        mockConnection.mockState = const Connected();

        final oldFolder = Folder(
          path: '/a/target',
          name: 'Old Name',
          createdAt: Int64(0),
        );
        final newFolder = Folder(
          path: '/a/target',
          name: 'New Name',
          createdAt: Int64(0),
        );

        final subscribeA = subscriptionManager.subscribe([
          "SELECT * FROM folder WHERE path LIKE '/a/%'",
        ]);
        mockConnection.simulateIncoming(
          _createSubscribeApplied(
            requestId: 0,
            querySetId: 1,
            rowsByTable: {
              'folder': [oldFolder],
            },
          ),
        );
        await subscribeA.timeout(_timeout);

        unawaited(
          subscriptionManager.reducers.call(
            'rename_folder',
            Uint8List(0),
            optimisticChanges: [
              OptimisticChange.update(
                'folder',
                oldFolder.toJson(),
                newFolder.toJson(),
              ),
            ],
          ),
        );
        await pumpEventQueue();

        final table = subscriptionManager.cache.getTableByName('folder');
        if (table == null) fail('folder table was not registered');
        expect(table.iter().map((f) => f.name), contains('New Name'));

        mockConnection.mockState = const Disconnected();
        await pumpEventQueue();
        mockConnection.mockState = const Connected();
        await pumpEventQueue();

        expect(
          subscriptionManager.subscriptionsByQuerySetId.containsKey(2),
          isTrue,
        );

        mockConnection.simulateIncoming(
          _createSubscribeApplied(
            requestId: 0,
            querySetId: 2,
            rowsByTable: {
              'folder': [oldFolder],
            },
          ),
        );
        await pumpEventQueue();

        expect(table.iter().map((f) => f.name), contains('New Name'));

        final numericRequestId = mockConnection.getLastSentRequestId();
        mockConnection.simulateIncoming(
          _createReducerResultCommitted(
            requestId: numericRequestId,
            querySetId: 2,
            tableName: 'folder',
            inserts: [newFolder],
          ),
        );
        await pumpEventQueue();

        expect(table.iter().map((f) => f.name), contains('New Name'));

        final subscribeB = subscriptionManager.subscribe([
          "SELECT * FROM folder WHERE path = '/does/not/match'",
        ]);
        mockConnection.simulateIncoming(
          _createSubscribeApplied(requestId: 0, querySetId: 3),
        );
        await subscribeB.timeout(_timeout);

        expect(table.iter().map((f) => f.name), contains('New Name'));
      },
    );

    test(
      'variant (b): two query sets, confirm lands mid-reconnect — '
      '_evictReconnectDeletes must spare the confirmed row',
      () async {
        mockConnection.mockState = const Connected();

        final oldFolder = Folder(
          path: '/a/target',
          name: 'Old Name',
          createdAt: Int64(0),
        );
        final newFolder = Folder(
          path: '/a/target',
          name: 'New Name',
          createdAt: Int64(0),
        );

        final subscribeA = subscriptionManager.subscribe([
          "SELECT * FROM folder WHERE path LIKE '/a/%'",
        ]);
        mockConnection.simulateIncoming(
          _createSubscribeApplied(
            requestId: 0,
            querySetId: 1,
            rowsByTable: {
              'folder': [oldFolder],
            },
          ),
        );
        await subscribeA.timeout(_timeout);

        final subscribeB = subscriptionManager.subscribe([
          "SELECT * FROM folder WHERE path LIKE '/b/%'",
        ]);
        mockConnection.simulateIncoming(
          _createSubscribeApplied(requestId: 0, querySetId: 2),
        );
        await subscribeB.timeout(_timeout);

        unawaited(
          subscriptionManager.reducers.call(
            'rename_folder',
            Uint8List(0),
            optimisticChanges: [
              OptimisticChange.update(
                'folder',
                oldFolder.toJson(),
                newFolder.toJson(),
              ),
            ],
          ),
        );
        await pumpEventQueue();
        final numericRequestId = mockConnection.getLastSentRequestId();

        mockConnection.mockState = const Disconnected();
        await pumpEventQueue();
        mockConnection.mockState = const Connected();
        await pumpEventQueue();

        expect(
          subscriptionManager.subscriptionsByQuerySetId.containsKey(3),
          isTrue,
        );

        mockConnection.simulateIncoming(
          _createReducerResultCommitted(
            requestId: numericRequestId,
            querySetId: 3,
            tableName: 'folder',
            inserts: [newFolder],
          ),
        );
        await pumpEventQueue();

        final table = subscriptionManager.cache.getTableByName('folder');
        if (table == null) fail('folder table was not registered');
        expect(table.iter().map((f) => f.name), contains('New Name'));

        mockConnection.simulateIncoming(
          _createSubscribeApplied(requestId: 0, querySetId: 4),
        );
        await pumpEventQueue();

        expect(table.iter().map((f) => f.name), contains('New Name'));
      },
    );
  });

  group('T2 — mispredicted optimistic insert (R3F2)', () {
    late MockConnection mockConnection;
    late SubscriptionManager subscriptionManager;

    setUp(() {
      mockConnection = MockConnection();
      subscriptionManager = SubscriptionManager(
        mockConnection,
        offlineStorage: InMemoryOfflineStorage(),
      );
      subscriptionManager.cache.registerDecoder<Folder>(
        'folder',
        FolderDecoder(),
      );
    });

    tearDown(() async {
      await subscriptionManager.dispose();
    });

    test(
      'an optimistic insert whose commit delta net-deletes the pk leaves no '
      'owner entry afterwards, no leak, phantom cleanup still fires',
      () async {
        mockConnection.mockState = const Connected();

        final subscribeA = subscriptionManager.subscribe([
          "SELECT * FROM folder WHERE path LIKE '/a/%'",
        ]);
        mockConnection.simulateIncoming(
          _createSubscribeApplied(requestId: 0, querySetId: 1),
        );
        await subscribeA.timeout(_timeout);

        final baselineCount = subscriptionManager.rowProvenanceCountForTable(
          'folder',
        );

        final mispredicted = Folder(
          path: '/a/mispredicted',
          name: 'Will Not Land',
          createdAt: Int64(0),
        );

        unawaited(
          subscriptionManager.reducers.call(
            'create_folder',
            Uint8List(0),
            optimisticChanges: [
              OptimisticChange.insert('folder', mispredicted.toJson()),
            ],
          ),
        );
        await pumpEventQueue();

        final table = subscriptionManager.cache.getTableByName('folder');
        if (table == null) fail('folder table was not registered');
        expect(table.iter().map((f) => f.path), contains('/a/mispredicted'));

        final numericRequestId = mockConnection.getLastSentRequestId();

        mockConnection.simulateIncoming(
          _createReducerResultCommitted(
            requestId: numericRequestId,
            querySetId: 1,
            tableName: 'folder',
          ),
        );
        await pumpEventQueue();

        expect(
          table.iter().map((f) => f.path),
          isNot(contains('/a/mispredicted')),
        );

        expect(
          subscriptionManager.rowProvenanceCountForTable('folder'),
          equals(baselineCount),
        );
      },
    );
  });

  group('non-self ReducerResult must not clobber a pending optimistic overlay', () {
    late MockConnection mockConnection;
    late SubscriptionManager subscriptionManager;

    setUp(() {
      mockConnection = MockConnection();
      subscriptionManager = SubscriptionManager(
        mockConnection,
        offlineStorage: InMemoryOfflineStorage(),
      );
      subscriptionManager.cache.registerDecoder<Folder>(
        'folder',
        FolderDecoder(),
      );
    });

    tearDown(() async {
      await subscriptionManager.dispose();
    });

    test(
      "a committed ReducerResult from another request carrying a delta for a "
      "pk we hold optimistically must not overwrite our unsynced value",
      () async {
        mockConnection.mockState = const Connected();

        final seedFolder = Folder(
          path: '/a/target',
          name: 'Server Name',
          createdAt: Int64(0),
        );

        final subscribeA = subscriptionManager.subscribe([
          "SELECT * FROM folder WHERE path LIKE '/a/%'",
        ]);
        mockConnection.simulateIncoming(
          _createSubscribeApplied(
            requestId: 0,
            querySetId: 1,
            rowsByTable: {
              'folder': [seedFolder],
            },
          ),
        );
        await subscribeA.timeout(_timeout);

        final localEdit = Folder(
          path: '/a/target',
          name: 'My Unsynced Edit',
          createdAt: Int64(0),
        );
        unawaited(
          subscriptionManager.reducers.call(
            'rename_folder',
            Uint8List(0),
            optimisticChanges: [
              OptimisticChange.update(
                'folder',
                seedFolder.toJson(),
                localEdit.toJson(),
              ),
            ],
          ),
        );
        await pumpEventQueue();

        final table = subscriptionManager.cache.getTableByName('folder');
        if (table == null) fail('folder table was not registered');
        expect(table.iter().map((f) => f.name), contains('My Unsynced Edit'));

        final otherClientVersion = Folder(
          path: '/a/target',
          name: 'Other Client Wrote This',
          createdAt: Int64(0),
        );
        mockConnection.simulateIncoming(
          _createReducerResultCommitted(
            requestId: 999,
            querySetId: 1,
            tableName: 'folder',
            inserts: [otherClientVersion],
          ),
        );
        await pumpEventQueue();

        expect(
          table.iter().map((f) => f.name),
          contains('My Unsynced Edit'),
          reason:
              'a ReducerResult from a different request (not ours, no '
              'optimistic state) must respect protectedKeys and not clobber '
              'the pending optimistic overlay on the same pk',
        );
      },
    );
  });

  group('T3 — protected-delete ownership trace', () {
    late MockConnection mockConnection;
    late SubscriptionManager subscriptionManager;

    setUp(() {
      mockConnection = MockConnection();
      subscriptionManager = SubscriptionManager(
        mockConnection,
        offlineStorage: InMemoryOfflineStorage(),
      );
      subscriptionManager.cache.registerDecoder<Folder>(
        'folder',
        FolderDecoder(),
      );
    });

    tearDown(() async {
      await subscriptionManager.dispose();
    });

    test(
      'a remote labeled delete for pk P while an optimistic update pends on '
      'P removes ownership and pins the row; a failed update rolls back to '
      'the stashed server delete (row honored gone, not resurrected)',
      () async {
        mockConnection.mockState = const Connected();

        final seedFolder = Folder(
          path: '/a/target',
          name: 'Original',
          createdAt: Int64(0),
        );

        final subscribeA = subscriptionManager.subscribe([
          "SELECT * FROM folder WHERE path LIKE '/a/%'",
        ]);
        mockConnection.simulateIncoming(
          _createSubscribeApplied(
            requestId: 0,
            querySetId: 1,
            rowsByTable: {
              'folder': [seedFolder],
            },
          ),
        );
        await subscribeA.timeout(_timeout);

        final table = subscriptionManager.cache.getTableByName('folder');
        if (table == null) fail('folder table was not registered');
        expect(table.iter().map((f) => f.path), contains('/a/target'));
        expect(
          subscriptionManager.rowProvenanceCountForTable('folder'),
          equals(1),
        );

        final updatedFolder = Folder(
          path: '/a/target',
          name: 'Locally Renamed',
          createdAt: Int64(0),
        );
        unawaited(
          subscriptionManager.reducers.call(
            'rename_folder',
            Uint8List(0),
            optimisticChanges: [
              OptimisticChange.update(
                'folder',
                seedFolder.toJson(),
                updatedFolder.toJson(),
              ),
            ],
          ),
        );
        await pumpEventQueue();

        expect(table.iter().map((f) => f.name), contains('Locally Renamed'));

        mockConnection.simulateIncoming(
          _createTransactionUpdate(
            querySetId: 1,
            tableName: 'folder',
            deletes: [seedFolder],
          ),
        );
        await pumpEventQueue();

        expect(table.iter().map((f) => f.name), contains('Locally Renamed'));
        expect(
          subscriptionManager.rowProvenanceCountForTable('folder'),
          equals(0),
        );

        final numericRequestId = mockConnection.getLastSentRequestId();
        mockConnection.simulateIncoming(
          _createReducerResultFailed(
            requestId: numericRequestId,
            message: 'rename_folder failed: stale row',
          ),
        );
        await pumpEventQueue();

        expect(
          table.iter().map((f) => f.path),
          isNot(contains('/a/target')),
          reason:
              'the remote delete was stashed when protection skipped it; a '
              'failed optimistic update must roll back to that server truth '
              '(row gone), not resurrect the stale pre-optimistic row',
        );
        expect(
          subscriptionManager.rowProvenanceCountForTable('folder'),
          equals(0),
        );

        final subscribeAgain = subscriptionManager.subscribe([
          "SELECT * FROM folder WHERE path LIKE '/a/%'",
        ]);
        mockConnection.simulateIncoming(
          _createSubscribeApplied(requestId: 0, querySetId: 2),
        );
        await subscribeAgain.timeout(_timeout);

        expect(
          table.iter().map((f) => f.path),
          isNot(contains('/a/target')),
        );
      },
    );

    test(
      'a committed update after the remote delete re-owns pk P and keeps '
      'the row',
      () async {
        mockConnection.mockState = const Connected();

        final seedFolder = Folder(
          path: '/a/target',
          name: 'Original',
          createdAt: Int64(0),
        );

        final subscribeA = subscriptionManager.subscribe([
          "SELECT * FROM folder WHERE path LIKE '/a/%'",
        ]);
        mockConnection.simulateIncoming(
          _createSubscribeApplied(
            requestId: 0,
            querySetId: 1,
            rowsByTable: {
              'folder': [seedFolder],
            },
          ),
        );
        await subscribeA.timeout(_timeout);

        final updatedFolder = Folder(
          path: '/a/target',
          name: 'Committed Rename',
          createdAt: Int64(0),
        );
        unawaited(
          subscriptionManager.reducers.call(
            'rename_folder',
            Uint8List(0),
            optimisticChanges: [
              OptimisticChange.update(
                'folder',
                seedFolder.toJson(),
                updatedFolder.toJson(),
              ),
            ],
          ),
        );
        await pumpEventQueue();

        mockConnection.simulateIncoming(
          _createTransactionUpdate(
            querySetId: 1,
            tableName: 'folder',
            deletes: [seedFolder],
          ),
        );
        await pumpEventQueue();

        final table = subscriptionManager.cache.getTableByName('folder');
        if (table == null) fail('folder table was not registered');
        expect(
          subscriptionManager.rowProvenanceCountForTable('folder'),
          equals(0),
        );

        final numericRequestId = mockConnection.getLastSentRequestId();
        mockConnection.simulateIncoming(
          _createReducerResultCommitted(
            requestId: numericRequestId,
            querySetId: 1,
            tableName: 'folder',
            inserts: [updatedFolder],
          ),
        );
        await pumpEventQueue();

        expect(table.iter().map((f) => f.name), contains('Committed Rename'));
        expect(
          subscriptionManager.rowProvenanceCountForTable('folder'),
          equals(1),
        );
      },
    );
  });

  group('unknown-id straggler skip in ReducerResult branches', () {
    late MockConnection mockConnection;
    late SubscriptionManager subscriptionManager;

    setUp(() {
      mockConnection = MockConnection();
      subscriptionManager = SubscriptionManager(
        mockConnection,
        offlineStorage: InMemoryOfflineStorage(),
      );
      subscriptionManager.cache.registerDecoder<Folder>(
        'folder',
        FolderDecoder(),
      );
    });

    tearDown(() async {
      await subscriptionManager.dispose();
    });

    test(
      'normal branch: a late committed ReducerResult QuerySetUpdate for an '
      'already-unsubscribed id does not resurrect a row',
      () async {
        mockConnection.mockState = const Connected();

        final subscribeA = subscriptionManager.subscribe([
          'SELECT * FROM folder WHERE 1=1',
        ]);
        mockConnection.simulateIncoming(
          _createSubscribeApplied(requestId: 0, querySetId: 1),
        );
        await subscribeA.timeout(_timeout);

        subscriptionManager.unsubscribe(1);

        final table = subscriptionManager.cache.getTableByName('folder');
        if (table == null) fail('folder table was not registered');

        final straggler = Folder(
          path: '/straggler',
          name: 'Straggler',
          createdAt: Int64(0),
        );

        mockConnection.simulateIncoming(
          _createReducerResultCommitted(
            requestId: 999,
            querySetId: 1,
            tableName: 'folder',
            inserts: [straggler],
          ),
        );
        await pumpEventQueue();

        expect(
          table.iter().map((f) => f.path),
          isNot(contains('/straggler')),
        );
        expect(table.ownershipImbalanceCount, equals(0));
      },
    );

    test(
      'short-circuit branch: a late committed ReducerResult QuerySetUpdate '
      'for an already-unsubscribed id does not touch ownership for the dead '
      'id, and request completion still runs',
      () async {
        mockConnection.mockState = const Connected();

        final subscribeA = subscriptionManager.subscribe([
          "SELECT * FROM folder WHERE path LIKE '/a/%'",
        ]);
        mockConnection.simulateIncoming(
          _createSubscribeApplied(requestId: 0, querySetId: 1),
        );
        await subscribeA.timeout(_timeout);

        final mispredicted = Folder(
          path: '/a/straggler',
          name: 'Will Not Land Twice',
          createdAt: Int64(0),
        );

        final callFuture = subscriptionManager.reducers.call(
          'create_folder',
          Uint8List(0),
          optimisticChanges: [
            OptimisticChange.insert('folder', mispredicted.toJson()),
          ],
        );
        await pumpEventQueue();

        final numericRequestId = mockConnection.getLastSentRequestId();

        subscriptionManager.unsubscribe(1);

        final table = subscriptionManager.cache.getTableByName('folder');
        if (table == null) fail('folder table was not registered');
        expect(table.iter().map((f) => f.path), contains('/a/straggler'));

        mockConnection.simulateIncoming(
          _createReducerResultCommitted(
            requestId: numericRequestId,
            querySetId: 1,
            tableName: 'folder',
            inserts: [mispredicted],
          ),
        );
        await pumpEventQueue();

        expect(await callFuture.timeout(_timeout), isNotNull);
        expect(table.ownedKeys('/a/straggler'), isNot(contains(1)));
      },
    );
  });

  group('round 5 — phantom cleanup must survive a dead query-set skip', () {
    late MockConnection mockConnection;
    late SubscriptionManager subscriptionManager;

    setUp(() {
      mockConnection = MockConnection();
      subscriptionManager = SubscriptionManager(
        mockConnection,
        offlineStorage: InMemoryOfflineStorage(),
      );
      subscriptionManager.cache.registerDecoder<Folder>(
        'folder',
        FolderDecoder(),
      );
    });

    tearDown(() async {
      await subscriptionManager.dispose();
    });

    test(
      'optimistic insert with a client-guessed pk, unsubscribed before '
      'confirm, then confirmed under the now-dead query-set id with a '
      'different server-assigned pk — the guessed-pk row must not be left '
      'resident forever',
      () async {
        mockConnection.mockState = const Connected();

        final subscribeA = subscriptionManager.subscribe([
          "SELECT * FROM folder WHERE path LIKE '/a/%'",
        ]);
        mockConnection.simulateIncoming(
          _createSubscribeApplied(requestId: 0, querySetId: 1),
        );
        await subscribeA.timeout(_timeout);

        final guessed = Folder(
          path: '/a/guess',
          name: 'Guessed Pk',
          createdAt: Int64(0),
        );

        final callFuture = subscriptionManager.reducers.call(
          'create_folder',
          Uint8List(0),
          optimisticChanges: [
            OptimisticChange.insert('folder', guessed.toJson()),
          ],
        );
        await pumpEventQueue();

        final numericRequestId = mockConnection.getLastSentRequestId();

        final table = subscriptionManager.cache.getTableByName('folder');
        if (table == null) fail('folder table was not registered');
        expect(table.iter().map((f) => f.path), contains('/a/guess'));

        subscriptionManager.unsubscribe(1);

        final real = Folder(
          path: '/a/real',
          name: 'Server Assigned Pk',
          createdAt: Int64(0),
        );

        mockConnection.simulateIncoming(
          _createReducerResultCommitted(
            requestId: numericRequestId,
            querySetId: 1,
            tableName: 'folder',
            inserts: [real],
          ),
        );
        await pumpEventQueue();

        expect(await callFuture.timeout(_timeout), isNotNull);

        expect(
          table.iter().map((f) => f.path),
          isNot(contains('/a/guess')),
        );
      },
    );
  });

  group('round 5 — same-table SingleTableRows entries in one SubscribeApplied', () {
    late MockConnection mockConnection;
    late SubscriptionManager subscriptionManager;

    setUp(() {
      mockConnection = MockConnection();
      subscriptionManager = SubscriptionManager(
        mockConnection,
        offlineStorage: InMemoryOfflineStorage(),
      );
      subscriptionManager.cache.registerDecoder<Folder>(
        'folder',
        FolderDecoder(),
      );
    });

    tearDown(() async {
      await subscriptionManager.dispose();
    });

    test(
      'a query set with two WHERE slices on the same table gets both '
      'slices\' rows in cache, not just the last one',
      () async {
        mockConnection.mockState = const Connected();

        final slice1 = Folder(
          path: '/slice-1',
          name: 'Slice One',
          createdAt: Int64(0),
        );
        final slice2 = Folder(
          path: '/slice-2',
          name: 'Slice Two',
          createdAt: Int64(0),
        );

        final subscribeFuture = subscriptionManager.subscribe([
          "SELECT * FROM folder WHERE path = '/slice-1'",
          "SELECT * FROM folder WHERE path = '/slice-2'",
        ]);

        mockConnection.simulateIncoming(
          _createSubscribeAppliedWithSlices(
            requestId: 0,
            querySetId: 1,
            slices: [
              MapEntry('folder', [slice1]),
              MapEntry('folder', [slice2]),
            ],
          ),
        );
        await subscribeFuture.timeout(_timeout);

        final table = subscriptionManager.cache.getTableByName('folder');
        if (table == null) fail('folder table was not registered');

        expect(
          table.iter().map((f) => f.path).toSet(),
          containsAll(['/slice-1', '/slice-2']),
        );
      },
    );
  });

  group('dropped-rows UnsubscribeApplied path', () {
    late MockConnection mockConnection;
    late SubscriptionManager subscriptionManager;

    setUp(() {
      mockConnection = MockConnection();
      subscriptionManager = SubscriptionManager(
        mockConnection,
        offlineStorage: InMemoryOfflineStorage(),
      );
      subscriptionManager.cache.registerDecoder<Folder>(
        'folder',
        FolderDecoder(),
      );
    });

    tearDown(() async {
      await subscriptionManager.dispose();
    });

    test(
      'a routine unsubscribe(sendDroppedRows: true) does not fire the '
      'ownership-imbalance tripwire',
      () async {
        mockConnection.mockState = const Connected();

        final row = Folder(path: '/p2', name: 'P2', createdAt: Int64(0));

        final subscribeA = subscriptionManager.subscribe([
          'SELECT * FROM folder WHERE 1=1',
        ]);
        mockConnection.simulateIncoming(
          _createSubscribeApplied(requestId: 0, querySetId: 1),
        );
        await subscribeA.timeout(_timeout);

        mockConnection.simulateIncoming(
          _createTransactionUpdate(
            querySetId: 1,
            tableName: 'folder',
            inserts: [row],
          ),
        );
        await pumpEventQueue();

        final table = subscriptionManager.cache.getTableByName('folder');
        if (table == null) fail('folder table was not registered');
        expect(table.iter().map((f) => f.path), contains('/p2'));

        subscriptionManager.unsubscribe(1, sendDroppedRows: true);
        mockConnection.simulateIncoming(
          _createUnsubscribeApplied(
            requestId: 0,
            querySetId: 1,
            droppedRowsByTable: {
              'folder': [row],
            },
          ),
        );
        await pumpEventQueue();

        expect(table.iter().map((f) => f.path), isNot(contains('/p2')));
        expect(table.ownershipImbalanceCount, equals(0));
      },
    );

    test(
      'a pinned optimistic row survives the dropped-rows payload of an '
      'unsubscribe on the set that covered it',
      () async {
        mockConnection.mockState = const Connected();

        final seedFolder = Folder(
          path: '/pinned',
          name: 'Original',
          createdAt: Int64(0),
        );

        final subscribeA = subscriptionManager.subscribe([
          'SELECT * FROM folder WHERE 1=1',
        ]);
        mockConnection.simulateIncoming(
          _createSubscribeApplied(
            requestId: 0,
            querySetId: 1,
            rowsByTable: {
              'folder': [seedFolder],
            },
          ),
        );
        await subscribeA.timeout(_timeout);

        final updatedFolder = Folder(
          path: '/pinned',
          name: 'Locally Renamed',
          createdAt: Int64(0),
        );
        unawaited(
          subscriptionManager.reducers.call(
            'rename_folder',
            Uint8List(0),
            optimisticChanges: [
              OptimisticChange.update(
                'folder',
                seedFolder.toJson(),
                updatedFolder.toJson(),
              ),
            ],
          ),
        );
        await pumpEventQueue();

        final table = subscriptionManager.cache.getTableByName('folder');
        if (table == null) fail('folder table was not registered');
        expect(table.iter().map((f) => f.name), contains('Locally Renamed'));

        subscriptionManager.unsubscribe(1, sendDroppedRows: true);
        mockConnection.simulateIncoming(
          _createUnsubscribeApplied(
            requestId: 0,
            querySetId: 1,
            droppedRowsByTable: {
              'folder': [seedFolder],
            },
          ),
        );
        await pumpEventQueue();

        expect(table.iter().map((f) => f.path), contains('/pinned'));
      },
    );
  });

  group('provenance untagging for UnsubscribeApplied dropped rows', () {
    late MockConnection mockConnection;
    late SubscriptionManager subscriptionManager;

    setUp(() {
      mockConnection = MockConnection();
      subscriptionManager = SubscriptionManager(mockConnection);
      subscriptionManager.cache.registerDecoder<Folder>(
        'folder',
        FolderDecoder(),
      );
    });

    tearDown(() async {
      await subscriptionManager.dispose();
    });

    test(
      'a row over-tagged against two query sets has its provenance entry '
      'pruned (not leaked) when the dropped-rows delete arrives after '
      'unsubscribing one of them',
      () async {
        mockConnection.mockState = const Connected();

        final sharedFolder = Folder(
          path: '/shared/only-in-a',
          name: 'Shared',
          createdAt: Int64(0),
        );

        final subscribeA = subscriptionManager.subscribe([
          'SELECT * FROM folder WHERE 1=1',
        ]);
        mockConnection.simulateIncoming(
          _createSubscribeApplied(requestId: 0, querySetId: 1),
        );
        await subscribeA.timeout(_timeout);

        final subscribeB = subscriptionManager.subscribe([
          'SELECT * FROM folder WHERE 1=1',
        ]);
        mockConnection.simulateIncoming(
          _createSubscribeApplied(requestId: 0, querySetId: 2),
        );
        await subscribeB.timeout(_timeout);

        mockConnection.simulateIncoming(
          _createTransactionUpdate(
            querySetId: 1,
            tableName: 'folder',
            inserts: [sharedFolder],
          ),
        );
        await pumpEventQueue();

        final table = subscriptionManager.cache.getTableByName('folder');
        if (table == null) fail('folder table was not registered');
        expect(table.iter().map((f) => f.path), contains('/shared/only-in-a'));

        final baselineCount = subscriptionManager.rowProvenanceCountForTable(
          'folder',
        );
        expect(baselineCount, greaterThan(0));

        subscriptionManager.unsubscribe(1, sendDroppedRows: true);
        mockConnection.simulateIncoming(
          _createUnsubscribeApplied(
            requestId: 0,
            querySetId: 1,
            droppedRowsByTable: {
              'folder': [sharedFolder],
            },
          ),
        );
        await pumpEventQueue();

        expect(
          table.iter().map((f) => f.path),
          isNot(contains('/shared/only-in-a')),
        );

        expect(
          subscriptionManager.rowProvenanceCountForTable('folder'),
          equals(baselineCount - 1),
        );
      },
    );
  });

  group('SubscribeApplied handler failure must not hang subscribe()', () {
    late MockConnection mockConnection;
    late SubscriptionManager subscriptionManager;

    setUp(() {
      mockConnection = MockConnection();
      subscriptionManager = SubscriptionManager(mockConnection);
      subscriptionManager.cache.registerDecoder<String>(
        'live_table',
        _ThrowingDecoder(),
      );
    });

    tearDown(() async {
      await subscriptionManager.dispose();
    });

    test(
      'subscribe() completes even when _handleSubscribeApplied throws while '
      'decoding the snapshot rows',
      () async {
        mockConnection.mockState = const Connected();

        final subscribeFuture = subscriptionManager.subscribe([
          'SELECT * FROM live_table WHERE a',
        ]);
        mockConnection.simulateIncoming(
          _createStrSubscribeApplied(
            requestId: 0,
            querySetId: 1,
            rowsByTable: {
              'live_table': ['will-throw-on-decode'],
            },
          ),
        );

        await expectLater(
          subscribeFuture.timeout(_timeout),
          completes,
        );
      },
    );
  });

  group('disconnect mid-reconnect must not wipe the cache', () {
    late MockConnection mockConnection;
    late SubscriptionManager subscriptionManager;

    setUp(() {
      mockConnection = MockConnection();
      subscriptionManager = SubscriptionManager(mockConnection);
      subscriptionManager.cache.registerDecoder<String>(
        'live_table',
        _StringDecoder(),
      );
    });

    tearDown(() async {
      await subscriptionManager.dispose();
    });

    test(
      'a second disconnect before the resubscribes are answered retains '
      'cached rows instead of evicting them all',
      () async {
        mockConnection.mockState = const Connected();

        final subscribeA = subscriptionManager.subscribe([
          'SELECT * FROM live_table WHERE a',
        ]);
        mockConnection.simulateIncoming(
          _createStrSubscribeApplied(
            requestId: 0,
            querySetId: 1,
            rowsByTable: {
              'live_table': ['seed-a', 'seed-b'],
            },
          ),
        );
        await subscribeA.timeout(_timeout);

        final table = subscriptionManager.cache.getTableByName('live_table');
        if (table == null) fail('live_table was not registered');
        expect(table.iter(), containsAll(['seed-a', 'seed-b']));

        mockConnection.mockState = const Disconnected();
        await pumpEventQueue();
        mockConnection.mockState = const Connected();
        await pumpEventQueue();

        mockConnection.mockState = const Disconnected();
        await pumpEventQueue();

        expect(
          table.iter(),
          containsAll(['seed-a', 'seed-b']),
          reason:
              'the resubscribe never got a SubscribeApplied because the '
              'connection dropped again mid-reconnect; the eviction sweep '
              'must be skipped so the offline-first cache retains its rows '
              'rather than blanking them',
        );
      },
    );
  });

  group('provenance tagging across a reconnect window', () {
    late MockConnection mockConnection;
    late SubscriptionManager subscriptionManager;

    setUp(() {
      mockConnection = MockConnection();
      subscriptionManager = SubscriptionManager(mockConnection);
      subscriptionManager.cache.registerDecoder<String>(
        'live_table',
        _StringDecoder(),
      );
    });

    tearDown(() async {
      await subscriptionManager.dispose();
    });

    test(
      'a live TransactionUpdate insert arriving between two query sets\' '
      'resubscribes mid-reconnect is tagged against the already-resubscribed '
      'set and survives once reconnect completes',
      () async {
        mockConnection.mockState = const Connected();

        final subscribeA = subscriptionManager.subscribe([
          'SELECT * FROM live_table WHERE a',
        ]);
        mockConnection.simulateIncoming(
          _createStrSubscribeApplied(
            requestId: 0,
            querySetId: 1,
            rowsByTable: {
              'live_table': ['seed-a'],
            },
          ),
        );
        await subscribeA.timeout(_timeout);

        final subscribeB = subscriptionManager.subscribe([
          'SELECT * FROM live_table WHERE b',
        ]);
        mockConnection.simulateIncoming(
          _createStrSubscribeApplied(
            requestId: 0,
            querySetId: 2,
            rowsByTable: {
              'live_table': ['seed-b'],
            },
          ),
        );
        await subscribeB.timeout(_timeout);

        final table = subscriptionManager.cache.getTableByName('live_table');
        if (table == null) fail('live_table was not registered');
        expect(table.iter(), containsAll(['seed-a', 'seed-b']));

        mockConnection.mockState = const Disconnected();
        await pumpEventQueue();

        mockConnection.mockState = const Connected();
        await pumpEventQueue();

        expect(
          subscriptionManager.subscriptionsByQuerySetId.containsKey(3),
          isTrue,
        );

        mockConnection.simulateIncoming(
          _createStrSubscribeApplied(
            requestId: 0,
            querySetId: 3,
            rowsByTable: {
              'live_table': ['seed-a'],
            },
          ),
        );
        await pumpEventQueue();

        expect(
          subscriptionManager.subscriptionsByQuerySetId.containsKey(4),
          isTrue,
        );

        mockConnection.simulateIncoming(
          _createStrTransactionUpdate(
            querySetId: 3,
            tableName: 'live_table',
            inserts: ['mid-reconnect-insert'],
          ),
        );
        await pumpEventQueue();

        expect(table.iter(), contains('mid-reconnect-insert'));

        mockConnection.simulateIncoming(
          _createStrSubscribeApplied(
            requestId: 0,
            querySetId: 4,
            rowsByTable: {
              'live_table': ['seed-b'],
            },
          ),
        );
        await pumpEventQueue();

        expect(table.iter(), contains('mid-reconnect-insert'));

        final laterSubscribe = subscriptionManager.subscribe([
          'SELECT * FROM live_table WHERE 1=0',
        ]);
        mockConnection.simulateIncoming(
          _createStrSubscribeApplied(
            requestId: 0,
            querySetId: 5,
            rowsByTable: const {'live_table': []},
          ),
        );
        await laterSubscribe.timeout(_timeout);

        expect(table.iter(), contains('mid-reconnect-insert'));
      },
    );
  });
}
