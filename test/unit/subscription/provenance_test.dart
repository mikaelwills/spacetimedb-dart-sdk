import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:spacetimedb_sdk/codegen.dart';
import 'package:spacetimedb_sdk/protocol.dart';

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

Uint8List _createReducerResultCommittedMultiQuerySet({
  required int requestId,
  required List<MapEntry<int, MapEntry<String, List<Folder>>>> querySets,
}) {
  final encoder = BsatnEncoder();
  encoder.writeU8(0);
  encoder.writeU8(6);

  encoder.writeU32(requestId);
  encoder.writeU64(Int64(0));

  encoder.writeU8(0);
  encoder.writeU32(0);

  encoder.writeU32(querySets.length);
  for (final querySet in querySets) {
    encoder.writeU32(querySet.key);

    encoder.writeU32(1);
    encoder.writeString(querySet.value.key);

    encoder.writeU32(1);
    encoder.writeU8(0);
    _writeFolderRowList(encoder, querySet.value.value);
    _writeFolderRowList(encoder, const []);
  }

  return encoder.toBytes();
}

Uint8List _createReducerResultOkEmpty({required int requestId}) {
  final encoder = BsatnEncoder();
  encoder.writeU8(0);
  encoder.writeU8(6);

  encoder.writeU32(requestId);
  encoder.writeU64(Int64(0));

  encoder.writeU8(1);

  return encoder.toBytes();
}

Uint8List _createReducerResultCommittedNoQuerySets({required int requestId}) {
  final encoder = BsatnEncoder();
  encoder.writeU8(0);
  encoder.writeU8(6);

  encoder.writeU32(requestId);
  encoder.writeU64(Int64(0));

  encoder.writeU8(0);
  encoder.writeU32(0);

  encoder.writeU32(0);

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

    test('an optimistic delete confirmed via the short-circuit path removes '
        'its provenance entry instead of leaking it', () async {
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

      expect(table.iter().map((f) => f.path), isNot(contains('/a/existing')));

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
    });
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
          subscriptionManager.subscriptionsByQuerySetId.containsKey(1),
          isTrue,
        );

        mockConnection.simulateIncoming(
          _createSubscribeApplied(
            requestId: 0,
            querySetId: 1,
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
            querySetId: 1,
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
          _createSubscribeApplied(requestId: 0, querySetId: 2),
        );
        await subscribeB.timeout(_timeout);

        expect(table.iter().map((f) => f.name), contains('New Name'));
      },
    );

    test('variant (b): two query sets, confirm lands mid-reconnect — '
        '_evictReconnectDeletes must spare the confirmed row', () async {
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
        subscriptionManager.subscriptionsByQuerySetId.containsKey(1),
        isTrue,
      );

      mockConnection.simulateIncoming(
        _createReducerResultCommitted(
          requestId: numericRequestId,
          querySetId: 1,
          tableName: 'folder',
          inserts: [newFolder],
        ),
      );
      await pumpEventQueue();

      final table = subscriptionManager.cache.getTableByName('folder');
      if (table == null) fail('folder table was not registered');
      expect(table.iter().map((f) => f.name), contains('New Name'));

      mockConnection.simulateIncoming(
        _createSubscribeApplied(requestId: 0, querySetId: 2),
      );
      await pumpEventQueue();

      expect(table.iter().map((f) => f.name), contains('New Name'));
    });
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

  group(
    'non-self ReducerResult must not clobber a pending optimistic overlay',
    () {
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
    },
  );

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

        expect(table.iter().map((f) => f.path), isNot(contains('/a/target')));
      },
    );

    test('a committed update after the remote delete re-owns pk P and keeps '
        'the row', () async {
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
    });
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

    test('normal branch: a late committed ReducerResult QuerySetUpdate for an '
        'already-unsubscribed id does not resurrect a row', () async {
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

      expect(table.iter().map((f) => f.path), isNot(contains('/straggler')));
      expect(table.ownershipImbalanceCount, equals(0));
    });

    test('short-circuit branch: a late committed ReducerResult QuerySetUpdate '
        'for an already-unsubscribed id does not touch ownership for the dead '
        'id, and request completion still runs', () async {
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
    });
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

    test('optimistic insert with a client-guessed pk, unsubscribed before '
        'confirm, then confirmed under the now-dead query-set id with a '
        'different server-assigned pk — the guessed-pk row must not be left '
        'resident forever', () async {
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

      expect(table.iter().map((f) => f.path), isNot(contains('/a/guess')));
    });
  });

  group(
    'round 5 — same-table SingleTableRows entries in one SubscribeApplied',
    () {
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

      test('a query set with two WHERE slices on the same table gets both '
          'slices\' rows in cache, not just the last one', () async {
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
      });
    },
  );

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

    test('a routine unsubscribe(sendDroppedRows: true) does not fire the '
        'ownership-imbalance tripwire', () async {
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
    });

    test('a pinned optimistic row survives the dropped-rows payload of an '
        'unsubscribe on the set that covered it', () async {
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
    });
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

    test('a row over-tagged against two query sets has its provenance entry '
        'pruned (not leaked) when the dropped-rows delete arrives after '
        'unsubscribing one of them', () async {
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
    });
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

    test('subscribe() completes even when _handleSubscribeApplied throws while '
        'decoding the snapshot rows', () async {
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

      await expectLater(subscribeFuture.timeout(_timeout), completes);
    });
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

    test('a second disconnect before the resubscribes are answered retains '
        'cached rows instead of evicting them all', () async {
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
    });
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

    test('a live TransactionUpdate insert arriving between two query sets\' '
        'resubscribes mid-reconnect is tagged against the already-resubscribed '
        'set and survives once reconnect completes', () async {
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
        subscriptionManager.subscriptionsByQuerySetId.containsKey(1),
        isTrue,
      );

      mockConnection.simulateIncoming(
        _createStrSubscribeApplied(
          requestId: 0,
          querySetId: 1,
          rowsByTable: {
            'live_table': ['seed-a'],
          },
        ),
      );
      await pumpEventQueue();

      expect(
        subscriptionManager.subscriptionsByQuerySetId.containsKey(2),
        isTrue,
      );

      mockConnection.simulateIncoming(
        _createStrTransactionUpdate(
          querySetId: 1,
          tableName: 'live_table',
          inserts: ['mid-reconnect-insert'],
        ),
      );
      await pumpEventQueue();

      expect(table.iter(), contains('mid-reconnect-insert'));

      mockConnection.simulateIncoming(
        _createStrSubscribeApplied(
          requestId: 0,
          querySetId: 2,
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
          querySetId: 3,
          rowsByTable: const {'live_table': []},
        ),
      );
      await laterSubscribe.timeout(_timeout);

      expect(table.iter(), contains('mid-reconnect-insert'));
    });
  });

  group('self-commit labelled with an unregistered query-set id', () {
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

    Future<int> subscribeAndInsertOptimistically(Folder row) async {
      mockConnection.mockState = const Connected();

      final subscribeA = subscriptionManager.subscribe([
        "SELECT * FROM folder WHERE path LIKE '/a/%'",
      ]);
      mockConnection.simulateIncoming(
        _createSubscribeApplied(requestId: 0, querySetId: 1),
      );
      await subscribeA.timeout(_timeout);

      unawaited(
        subscriptionManager.reducers.call(
          'create_folder',
          Uint8List(0),
          optimisticChanges: [OptimisticChange.insert('folder', row.toJson())],
        ),
      );
      await pumpEventQueue();

      return mockConnection.getLastSentRequestId();
    }

    test('still subscribed, commit carries a never-registered id and the same '
        'pk — the row must survive', () async {
      final committed = Folder(
        path: '/a/msg',
        name: 'Guitar Frequencies',
        createdAt: Int64(0),
      );
      final numericRequestId = await subscribeAndInsertOptimistically(
        committed,
      );

      final table = subscriptionManager.cache.getTableByName('folder');
      if (table == null) fail('folder table was not registered');
      expect(table.iter().map((f) => f.path), contains('/a/msg'));

      mockConnection.simulateIncoming(
        _createReducerResultCommitted(
          requestId: numericRequestId,
          querySetId: 99,
          tableName: 'folder',
          inserts: [committed],
        ),
      );
      await pumpEventQueue();

      expect(table.iter().map((f) => f.path), contains('/a/msg'));
    });

    test('registered query set, committed self-commit with the same pk — the '
        'row is present exactly once and the count is flat', () async {
      final committed = Folder(
        path: '/a/msg',
        name: 'Guitar Frequencies',
        createdAt: Int64(0),
      );
      final numericRequestId = await subscribeAndInsertOptimistically(
        committed,
      );

      final table = subscriptionManager.cache.getTableByName('folder');
      if (table == null) fail('folder table was not registered');
      final before = table.iter().length;

      mockConnection.simulateIncoming(
        _createReducerResultCommitted(
          requestId: numericRequestId,
          querySetId: 1,
          tableName: 'folder',
          inserts: [committed],
        ),
      );
      await pumpEventQueue();

      expect(table.iter().length, equals(before));
      expect(table.iter().where((f) => f.path == '/a/msg').length, equals(1));
    });

    test('explicitly unsubscribed, commit carries the dead id and the same pk '
        '— the row must still be reaped', () async {
      final committed = Folder(
        path: '/a/msg',
        name: 'Guitar Frequencies',
        createdAt: Int64(0),
      );
      final numericRequestId = await subscribeAndInsertOptimistically(
        committed,
      );

      final table = subscriptionManager.cache.getTableByName('folder');
      if (table == null) fail('folder table was not registered');
      expect(table.iter().map((f) => f.path), contains('/a/msg'));

      subscriptionManager.unsubscribe(1);

      mockConnection.simulateIncoming(
        _createReducerResultCommitted(
          requestId: numericRequestId,
          querySetId: 1,
          tableName: 'folder',
          inserts: [committed],
        ),
      );
      await pumpEventQueue();

      expect(table.iter().map((f) => f.path), isNot(contains('/a/msg')));
    });

    test('a retained row plus a later authoritative SubscribeApplied carrying '
        'the same pk converges to exactly one row', () async {
      final committed = Folder(
        path: '/a/msg',
        name: 'Guitar Frequencies',
        createdAt: Int64(0),
      );
      final numericRequestId = await subscribeAndInsertOptimistically(
        committed,
      );

      final table = subscriptionManager.cache.getTableByName('folder');
      if (table == null) fail('folder table was not registered');

      mockConnection.simulateIncoming(
        _createReducerResultCommitted(
          requestId: numericRequestId,
          querySetId: 99,
          tableName: 'folder',
          inserts: [committed],
        ),
      );
      await pumpEventQueue();

      final laterSubscribe = subscriptionManager.subscribe([
        "SELECT * FROM folder WHERE path LIKE '/a/%'",
      ]);
      mockConnection.simulateIncoming(
        _createSubscribeApplied(
          requestId: 0,
          querySetId: 2,
          rowsByTable: {
            'folder': [committed],
          },
        ),
      );
      await laterSubscribe.timeout(_timeout);

      expect(table.iter().where((f) => f.path == '/a/msg').length, equals(1));
    });

    test('multi-query-set commit: the registered set carries the real '
        'server-assigned pk and an unrelated set is unregistered — the '
        'guessed-pk phantom must still be reaped', () async {
      final guessed = Folder(
        path: '/a/guess',
        name: 'Guessed Pk',
        createdAt: Int64(0),
      );
      final numericRequestId = await subscribeAndInsertOptimistically(guessed);

      final table = subscriptionManager.cache.getTableByName('folder');
      if (table == null) fail('folder table was not registered');
      expect(table.iter().map((f) => f.path), contains('/a/guess'));

      final real = Folder(
        path: '/a/real',
        name: 'Server Assigned Pk',
        createdAt: Int64(0),
      );

      mockConnection.simulateIncoming(
        _createReducerResultCommittedMultiQuerySet(
          requestId: numericRequestId,
          querySets: [
            MapEntry(1, MapEntry('folder', [real])),
            const MapEntry(99, MapEntry('folder', <Folder>[])),
          ],
        ),
      );
      await pumpEventQueue();

      expect(table.iter().map((f) => f.path), contains('/a/real'));
      expect(table.iter().map((f) => f.path), isNot(contains('/a/guess')));
    });
  });

  group('duplicate commit after the row arrived by subscription', () {
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

    test('a registered rowless commit for a pk the server already delivered '
        'must not delete the server-owned row', () async {
      mockConnection.mockState = const Connected();

      final subscribeA = subscriptionManager.subscribe([
        "SELECT * FROM folder WHERE path LIKE '/a/%'",
      ]);
      mockConnection.simulateIncoming(
        _createSubscribeApplied(requestId: 0, querySetId: 1),
      );
      await subscribeA.timeout(_timeout);

      final queued = Folder(
        path: '/a/msg',
        name: 'Guitar Frequencies',
        createdAt: Int64(0),
      );

      unawaited(
        subscriptionManager.reducers.call(
          'create_folder',
          Uint8List(0),
          optimisticChanges: [
            OptimisticChange.insert('folder', queued.toJson()),
          ],
        ),
      );
      await pumpEventQueue();

      final numericRequestId = mockConnection.getLastSentRequestId();

      final table = subscriptionManager.cache.getTableByName('folder');
      if (table == null) fail('folder table was not registered');
      expect(table.iter().map((f) => f.path), contains('/a/msg'));

      mockConnection.simulateIncoming(
        _createSubscribeApplied(
          requestId: 1,
          querySetId: 1,
          rowsByTable: {
            'folder': [queued],
          },
        ),
      );
      await pumpEventQueue();

      expect(
        table.ownedKeys('/a/msg'),
        isNotEmpty,
        reason: 'SubscribeApplied must grant ownership for the pk',
      );

      final ownedCount = subscriptionManager.rowProvenanceCountForTable(
        'folder',
      );
      final rowCount = table.iter().length;

      mockConnection.simulateIncoming(
        _createReducerResultCommitted(
          requestId: numericRequestId,
          querySetId: 1,
          tableName: 'folder',
        ),
      );
      await pumpEventQueue();

      expect(table.iter().map((f) => f.path), contains('/a/msg'));
      expect(table.iter().length, equals(rowCount));
      expect(
        subscriptionManager.rowProvenanceCountForTable('folder'),
        equals(ownedCount),
      );
    });

    test('a genuine Failed result still rolls back its unowned optimistic '
        'insert', () async {
      mockConnection.mockState = const Connected();

      final subscribeA = subscriptionManager.subscribe([
        "SELECT * FROM folder WHERE path LIKE '/a/%'",
      ]);
      mockConnection.simulateIncoming(
        _createSubscribeApplied(requestId: 0, querySetId: 1),
      );
      await subscribeA.timeout(_timeout);

      final rejected = Folder(
        path: '/a/rejected',
        name: 'Server Says No',
        createdAt: Int64(0),
      );

      unawaited(
        subscriptionManager.reducers.call(
          'create_folder',
          Uint8List(0),
          optimisticChanges: [
            OptimisticChange.insert('folder', rejected.toJson()),
          ],
        ),
      );
      await pumpEventQueue();

      final table = subscriptionManager.cache.getTableByName('folder');
      if (table == null) fail('folder table was not registered');
      expect(table.iter().map((f) => f.path), contains('/a/rejected'));
      expect(table.ownedKeys('/a/rejected'), isEmpty);

      mockConnection.simulateIncoming(
        _createReducerResultFailed(
          requestId: mockConnection.getLastSentRequestId(),
          message: 'create_folder failed: permission denied',
        ),
      );
      await pumpEventQueue();

      expect(table.iter().map((f) => f.path), isNot(contains('/a/rejected')));
      expect(
        subscriptionManager.rowProvenanceCountForTable('folder'),
        equals(0),
      );
    });
  });

  group('committed self-commit carrying zero query sets', () {
    late MockConnection mockConnection;
    late SubscriptionManager subscriptionManager;
    late List<String> logLines;
    late SdkLogLevel savedLevel;
    late SdkLogCallback? savedOnLog;

    setUp(() {
      logLines = [];
      savedLevel = SdkLogger.level;
      savedOnLog = SdkLogger.onLog;
      SdkLogger.level = SdkLogLevel.debug;
      SdkLogger.onLog = (tag, msg) => logLines.add(msg);

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
      SdkLogger.onLog = savedOnLog;
      SdkLogger.level = savedLevel;
    });

    Future<int> subscribeAndInsertOptimistically(Folder row) async {
      mockConnection.mockState = const Connected();

      final subscribeA = subscriptionManager.subscribe([
        "SELECT * FROM folder WHERE path LIKE '/a/%'",
      ]);
      mockConnection.simulateIncoming(
        _createSubscribeApplied(requestId: 0, querySetId: 1),
      );
      await subscribeA.timeout(_timeout);

      unawaited(
        subscriptionManager.reducers.call(
          'create_folder',
          Uint8List(0),
          optimisticChanges: [OptimisticChange.insert('folder', row.toJson())],
        ),
      );
      await pumpEventQueue();

      return mockConnection.getLastSentRequestId();
    }

    void expectRoutedToSelfCommit() {
      expect(
        logLines,
        contains(
          allOf(
            contains('REDUCER_RESULT:'),
            contains('querySets=0'),
            contains('isOurs=true'),
            contains('hasOptimistic=true'),
          ),
        ),
      );
      expect(
        logLines,
        isNot(contains(contains('confirmOrRollbackWithTouchedKeys'))),
      );
    }

    test('outcome tag 1 (OkEmpty), still subscribed — the committed row the '
        'caller inserted optimistically must survive', () async {
      final committed = Folder(
        path: '/a/msg',
        name: 'Guitar Frequencies',
        createdAt: Int64(0),
      );
      final numericRequestId = await subscribeAndInsertOptimistically(
        committed,
      );

      final table = subscriptionManager.cache.getTableByName('folder');
      if (table == null) fail('folder table was not registered');
      expect(table.iter().map((f) => f.path), contains('/a/msg'));

      mockConnection.simulateIncoming(
        _createReducerResultOkEmpty(requestId: numericRequestId),
      );
      await pumpEventQueue();

      expectRoutedToSelfCommit();
      expect(table.iter().map((f) => f.path), contains('/a/msg'));
    });

    test('outcome tag 0 (Ok) with an empty decoded query-set list, still '
        'subscribed — the committed row the caller inserted optimistically '
        'must survive', () async {
      final committed = Folder(
        path: '/a/msg',
        name: 'Guitar Frequencies',
        createdAt: Int64(0),
      );
      final numericRequestId = await subscribeAndInsertOptimistically(
        committed,
      );

      final table = subscriptionManager.cache.getTableByName('folder');
      if (table == null) fail('folder table was not registered');
      expect(table.iter().map((f) => f.path), contains('/a/msg'));

      mockConnection.simulateIncoming(
        _createReducerResultCommittedNoQuerySets(requestId: numericRequestId),
      );
      await pumpEventQueue();

      expectRoutedToSelfCommit();
      expect(table.iter().map((f) => f.path), contains('/a/msg'));
    });
  });
  group('zero-query-set retention must not become durable state', () {
    late MockConnection mockConnection;
    late InMemoryOfflineStorage storage;
    late SubscriptionManager subscriptionManager;

    setUp(() {
      storage = InMemoryOfflineStorage();
      mockConnection = MockConnection();
      subscriptionManager = SubscriptionManager(
        mockConnection,
        offlineStorage: storage,
      );
      subscriptionManager.cache.registerDecoder<Folder>(
        'folder',
        FolderDecoder(),
      );
    });

    tearDown(() async {
      await subscriptionManager.dispose();
    });

    Future<int> subscribeAndInsertOptimistically(Folder row) async {
      mockConnection.mockState = const Connected();

      final subscribeA = subscriptionManager.subscribe([
        "SELECT * FROM folder WHERE path LIKE '/a/%'",
      ]);
      mockConnection.simulateIncoming(
        _createSubscribeApplied(requestId: 0, querySetId: 1),
      );
      await subscribeA.timeout(_timeout);

      unawaited(
        subscriptionManager.reducers.call(
          'create_folder',
          Uint8List(0),
          optimisticChanges: [OptimisticChange.insert('folder', row.toJson())],
        ),
      );
      await pumpEventQueue();

      return mockConnection.getLastSentRequestId();
    }

    test(
      'a client-guessed pk retained by a zero-query-set commit is evicted '
      'by the next authoritative snapshot, leaving exactly the server row',
      () async {
        final guessed = Folder(
          path: '/a/guess',
          name: 'Guessed Pk',
          createdAt: Int64(0),
        );
        final numericRequestId = await subscribeAndInsertOptimistically(
          guessed,
        );

        final table = subscriptionManager.cache.getTableByName('folder');
        if (table == null) fail('folder table was not registered');

        mockConnection.simulateIncoming(
          _createReducerResultCommittedNoQuerySets(requestId: numericRequestId),
        );
        await pumpEventQueue();

        expect(table.iter().map((f) => f.path), contains('/a/guess'));

        final real = Folder(
          path: '/a/real',
          name: 'Server Assigned Pk',
          createdAt: Int64(0),
        );
        mockConnection.simulateIncoming(
          _createSubscribeApplied(
            requestId: 0,
            querySetId: 1,
            rowsByTable: {
              'folder': [real],
            },
          ),
        );
        await pumpEventQueue();

        expect(table.iter().map((f) => f.path), equals(['/a/real']));
      },
    );

    test('a client-guessed pk retained by a zero-query-set commit is not '
        'written to offline storage by a later unrelated transaction on the '
        'same table', () async {
      final guessed = Folder(
        path: '/a/guess',
        name: 'Guessed Pk',
        createdAt: Int64(0),
      );
      final numericRequestId = await subscribeAndInsertOptimistically(guessed);

      final table = subscriptionManager.cache.getTableByName('folder');
      if (table == null) fail('folder table was not registered');

      mockConnection.simulateIncoming(
        _createReducerResultCommittedNoQuerySets(requestId: numericRequestId),
      );
      await pumpEventQueue();

      expect(table.iter().map((f) => f.path), contains('/a/guess'));
      expect(table.ownedKeys('/a/guess'), isEmpty);

      final other = Folder(
        path: '/a/other',
        name: 'Foreign Row',
        createdAt: Int64(0),
      );
      mockConnection.simulateIncoming(
        _createReducerResultCommitted(
          requestId: 4242,
          querySetId: 1,
          tableName: 'folder',
          inserts: [other],
        ),
      );
      await pumpEventQueue();
      await pumpEventQueue();

      final snapshot = await storage.loadTableSnapshot('folder') ?? [];
      expect(snapshot.map((r) => r['path']), contains('/a/other'));
      expect(snapshot.map((r) => r['path']), isNot(contains('/a/guess')));
    });

    test('once the server takes ownership of the retained pk, the row is '
        'persisted normally', () async {
      final committed = Folder(
        path: '/a/msg',
        name: 'Guitar Frequencies',
        createdAt: Int64(0),
      );
      final numericRequestId = await subscribeAndInsertOptimistically(
        committed,
      );

      final table = subscriptionManager.cache.getTableByName('folder');
      if (table == null) fail('folder table was not registered');

      mockConnection.simulateIncoming(
        _createReducerResultCommittedNoQuerySets(requestId: numericRequestId),
      );
      await pumpEventQueue();

      mockConnection.simulateIncoming(
        _createReducerResultCommitted(
          requestId: 4242,
          querySetId: 1,
          tableName: 'folder',
          inserts: [committed],
        ),
      );
      await pumpEventQueue();
      await pumpEventQueue();

      expect(table.ownedKeys('/a/msg'), isNotEmpty);

      final snapshot = await storage.loadTableSnapshot('folder') ?? [];
      expect(snapshot.map((r) => r['path']), contains('/a/msg'));
    });
  });

  group('dropIfOffline self-commit carrying optimistic changes', () {
    late MockConnection mockConnection;
    late SubscriptionManager subscriptionManager;
    late InMemoryOfflineStorage offlineStorage;
    late List<String> logLines;
    late SdkLogLevel savedLevel;
    late SdkLogCallback? savedOnLog;

    setUp(() {
      logLines = [];
      savedLevel = SdkLogger.level;
      savedOnLog = SdkLogger.onLog;
      SdkLogger.level = SdkLogLevel.debug;
      SdkLogger.onLog = (tag, msg) => logLines.add(msg);

      mockConnection = MockConnection();
      offlineStorage = InMemoryOfflineStorage();
      subscriptionManager = SubscriptionManager(
        mockConnection,
        offlineStorage: offlineStorage,
      );
      subscriptionManager.cache.registerDecoder<Folder>(
        'folder',
        FolderDecoder(),
      );
    });

    tearDown(() async {
      await subscriptionManager.dispose();
      SdkLogger.onLog = savedOnLog;
      SdkLogger.level = savedLevel;
    });

    Future<int> subscribeAndSendDirectlyWithOptimistic(Folder row) async {
      mockConnection.mockState = const Connected();

      final subscribeA = subscriptionManager.subscribe([
        "SELECT * FROM folder WHERE path LIKE '/a/%'",
      ]);
      mockConnection.simulateIncoming(
        _createSubscribeApplied(requestId: 0, querySetId: 1),
      );
      await subscribeA.timeout(_timeout);

      unawaited(
        subscriptionManager.reducers
            .call(
              'create_folder',
              Uint8List(0),
              dropIfOffline: true,
              optimisticChanges: [
                OptimisticChange.insert('folder', row.toJson()),
              ],
            )
            .catchError((_) => TransactionResult.dropped(reducerName: 'x')),
      );
      await pumpEventQueue();

      return mockConnection.getLastSentRequestId();
    }

    test('committed on a REGISTERED query set carrying the inserted row — the '
        'row must survive', () async {
      final committed = Folder(
        path: '/a/msg',
        name: 'Guitar Frequencies',
        createdAt: Int64(0),
      );
      final numericRequestId = await subscribeAndSendDirectlyWithOptimistic(
        committed,
      );

      final table = subscriptionManager.cache.getTableByName('folder');
      if (table == null) fail('folder table was not registered');
      expect(table.iter().map((f) => f.path), contains('/a/msg'));

      mockConnection.simulateIncoming(
        _createReducerResultCommitted(
          requestId: numericRequestId,
          querySetId: 1,
          tableName: 'folder',
          inserts: [committed],
        ),
      );
      await pumpEventQueue();

      expect(
        logLines,
        contains(
          allOf(
            contains('REDUCER_RESULT:'),
            contains('isOurs=true'),
            contains('hasOptimistic=true'),
          ),
        ),
      );
      expect(table.iter().map((f) => f.path), contains('/a/msg'));
    });

    test('committed on an UNREGISTERED query set — the optimistically '
        'inserted row must survive', () async {
      final committed = Folder(
        path: '/a/msg',
        name: 'Guitar Frequencies',
        createdAt: Int64(0),
      );
      final numericRequestId = await subscribeAndSendDirectlyWithOptimistic(
        committed,
      );

      final table = subscriptionManager.cache.getTableByName('folder');
      if (table == null) fail('folder table was not registered');
      expect(table.iter().map((f) => f.path), contains('/a/msg'));

      mockConnection.simulateIncoming(
        _createReducerResultCommitted(
          requestId: numericRequestId,
          querySetId: 99,
          tableName: 'folder',
          inserts: const [],
        ),
      );
      await pumpEventQueue();

      expect(table.iter().map((f) => f.path), contains('/a/msg'));
    });

    test('committed OkEmpty (no query sets) — the optimistically inserted row '
        'must survive', () async {
      final committed = Folder(
        path: '/a/msg',
        name: 'Guitar Frequencies',
        createdAt: Int64(0),
      );
      final numericRequestId = await subscribeAndSendDirectlyWithOptimistic(
        committed,
      );

      final table = subscriptionManager.cache.getTableByName('folder');
      if (table == null) fail('folder table was not registered');
      expect(table.iter().map((f) => f.path), contains('/a/msg'));

      mockConnection.simulateIncoming(
        _createReducerResultOkEmpty(requestId: numericRequestId),
      );
      await pumpEventQueue();

      expect(table.iter().map((f) => f.path), contains('/a/msg'));
    });

    test(
      'committed OkEmpty — the surviving row must also be durably '
      'persisted, since a dropIfOffline call is never queued to disk',
      () async {
        final committed = Folder(
          path: '/a/msg',
          name: 'Guitar Frequencies',
          createdAt: Int64(0),
        );
        final numericRequestId = await subscribeAndSendDirectlyWithOptimistic(
          committed,
        );

        final table = subscriptionManager.cache.getTableByName('folder');
        if (table == null) fail('folder table was not registered');

        mockConnection.simulateIncoming(
          _createReducerResultOkEmpty(requestId: numericRequestId),
        );
        await pumpEventQueue();

        expect(table.iter().map((f) => f.path), contains('/a/msg'));

        expect(
          await offlineStorage.getPendingMutations(),
          isEmpty,
          reason:
              'dropIfOffline bypasses the queue, so the snapshot is the only '
              'durable copy of this row',
        );

        final snapshot = await offlineStorage.loadTableSnapshot('folder');
        expect(
          snapshot?.map((r) => r['path']),
          contains('/a/msg'),
          reason:
              'the server committed this row and it survives in the live cache, '
              'but it is excluded from every persisted snapshot, so it is lost '
              'on restart with no queued mutation to replay it',
        );
      },
    );
  });
}
