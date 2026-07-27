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

Folder _folder(String path) =>
    Folder(path: path, name: path, createdAt: Int64(0));

void main() {
  late MockConnection connection;
  late SubscriptionManager manager;
  late InMemoryOfflineStorage storage;

  setUp(() {
    connection = MockConnection();
    storage = InMemoryOfflineStorage();
    manager = SubscriptionManager(connection, offlineStorage: storage);
    manager.cache.registerDecoder<Folder>('folder', FolderDecoder());
  });

  tearDown(() async {
    await manager.dispose();
  });

  Future<void> subscribeFolder() async {
    connection.mockState = const Connected();
    final subscribed = manager.subscribe(['SELECT * FROM folder']);
    connection.simulateIncoming(
      _createSubscribeApplied(requestId: 0, querySetId: 1),
    );
    await subscribed.timeout(_timeout);
    await pumpEventQueue();
  }

  Future<void> queueInsertsOffline(List<Folder> folders) async {
    connection.setStateSilently(const Disconnected());
    await manager.reducers.call(
      'create_folder',
      Uint8List(0),
      optimisticChanges: [
        for (final folder in folders)
          OptimisticChange.insert('folder', folder.toJson()),
      ],
    );
    connection.setStateSilently(const Connected());
  }

  Future<void> replayAndAbort() async {
    connection.clearSent();
    unawaited(manager.syncPendingMutations());
    await pumpEventQueue();
    expect(connection.sentMessages, hasLength(1));
    connection.simulateIncoming(
      _createReducerResultFailed(
        requestId: connection.getLastSentRequestId(),
        message: 'duplicate unique key',
      ),
    );
    await pumpEventQueue();
  }

  Future<void> respondFailedToLastSend() async {
    connection.simulateIncoming(
      _createReducerResultFailed(
        requestId: connection.getLastSentRequestId(),
        message: 'duplicate unique key',
      ),
    );
    await pumpEventQueue();
  }

  test('ownership gained via a TransactionUpdate delta wakes the '
      'abort-recheck pause without waiting out the retry backoff', () async {
    await subscribeFolder();
    final awaited = _folder('/race/x');
    await queueInsertsOffline([awaited]);
    await replayAndAbort();

    expect(await storage.getPendingMutations(), hasLength(1));
    expect(manager.syncState.status, equals(SyncStatus.waitingToRetry));
    expect(
      manager.optimisticKeysFor('folder'),
      isEmpty,
      reason:
          'the abort echo routed through _applyForeignOrRollback already '
          'rolled the overlay back, so the awaited PK is NOT protected '
          'at abort-recheck pause time',
    );

    connection.simulateIncoming(
      _createTransactionUpdate(
        querySetId: 1,
        tableName: 'folder',
        inserts: [awaited],
      ),
    );
    await pumpEventQueue();

    expect(
      connection.sentMessages,
      hasLength(2),
      reason:
          'the awaited PK gained an owner; the paused queue must replay '
          'immediately instead of stalling until the retry timer',
    );
    await respondFailedToLastSend();

    expect(await storage.getPendingMutations(), isEmpty);
    expect(manager.syncState.status, equals(SyncStatus.idle));
    expect(manager.syncState.nextRetryAt, isNull);
  });

  test('ownership gained for a still-protected PK (timeout pause, overlay '
      'intact) wakes the queue even though the delta is invisible to '
      'events and return values', () async {
    await subscribeFolder();
    final awaited = _folder('/race/t');
    await queueInsertsOffline([awaited]);

    manager.reducers.defaultTimeout = const Duration(milliseconds: 50);
    connection.clearSent();
    unawaited(manager.syncPendingMutations());
    await pumpEventQueue();
    expect(connection.sentMessages, hasLength(1));
    await Future<void>.delayed(const Duration(milliseconds: 120));
    await pumpEventQueue();

    expect(await storage.getPendingMutations(), hasLength(1));
    expect(manager.syncState.status, equals(SyncStatus.waitingToRetry));
    expect(
      manager.optimisticKeysFor('folder'),
      contains('/race/t'),
      reason: 'no echo arrived, so the overlay is intact and protected',
    );

    connection.simulateIncoming(
      _createTransactionUpdate(
        querySetId: 1,
        tableName: 'folder',
        inserts: [awaited],
      ),
    );
    await pumpEventQueue();

    expect(
      connection.sentMessages,
      hasLength(2),
      reason:
          'the protected awaited PK gained an owner; the queue must wake '
          'even though protected keys are filtered from touchedKeys and '
          'all table events',
    );
    await respondFailedToLastSend();

    expect(await storage.getPendingMutations(), isEmpty);
    expect(manager.syncState.status, equals(SyncStatus.idle));
  });

  test('a multi-insert mutation wakes only when the LAST awaited PK gains '
      'an owner', () async {
    await subscribeFolder();
    final first = _folder('/race/a');
    final second = _folder('/race/b');
    await queueInsertsOffline([first, second]);
    await replayAndAbort();
    expect(manager.syncState.status, equals(SyncStatus.waitingToRetry));

    connection.simulateIncoming(
      _createTransactionUpdate(
        querySetId: 1,
        tableName: 'folder',
        inserts: [first],
      ),
    );
    await pumpEventQueue();
    expect(
      connection.sentMessages,
      hasLength(1),
      reason:
          'a partial gain must not wake the queue; the replay would '
          'abort again and burn recheck budget',
    );

    connection.simulateIncoming(
      _createTransactionUpdate(
        querySetId: 1,
        tableName: 'folder',
        inserts: [second],
      ),
    );
    await pumpEventQueue();
    expect(
      connection.sentMessages,
      hasLength(2),
      reason: 'the last outstanding gain must wake the queue',
    );
    await respondFailedToLastSend();

    expect(await storage.getPendingMutations(), isEmpty);
    expect(manager.syncState.status, equals(SyncStatus.idle));
  });

  test('ownership gained via a ReducerResult echo of a direct call wakes '
      'the paused queue', () async {
    await subscribeFolder();
    final awaited = _folder('/race/r');
    await queueInsertsOffline([awaited]);
    await replayAndAbort();
    expect(manager.syncState.status, equals(SyncStatus.waitingToRetry));

    unawaited(
      manager.reducers.call('touch_folder', Uint8List(0), dropIfOffline: true),
    );
    await pumpEventQueue();
    expect(connection.sentMessages, hasLength(2));
    connection.simulateIncoming(
      _createReducerResultCommitted(
        requestId: connection.getLastSentRequestId(),
        querySetId: 1,
        tableName: 'folder',
        inserts: [awaited],
      ),
    );
    await pumpEventQueue();

    expect(
      connection.sentMessages,
      hasLength(3),
      reason:
          'the awaited PK gained an owner through _applyReducerTables; '
          'the paused queue must replay immediately',
    );
    await respondFailedToLastSend();

    expect(await storage.getPendingMutations(), isEmpty);
    expect(manager.syncState.status, equals(SyncStatus.idle));
  });

  test(
    'a burst of unrelated gains while paused triggers no cycles and '
    'burns no recheck budget; the awaited gain then confirms as success',
    () async {
      await subscribeFolder();
      final awaited = _folder('/race/z');
      await queueInsertsOffline([awaited]);
      await replayAndAbort();
      expect(manager.syncState.status, equals(SyncStatus.waitingToRetry));

      for (var i = 0; i < 4; i++) {
        connection.simulateIncoming(
          _createTransactionUpdate(
            querySetId: 1,
            tableName: 'folder',
            inserts: [_folder('/other/$i')],
          ),
        );
      }
      await pumpEventQueue();
      expect(
        connection.sentMessages,
        hasLength(1),
        reason:
            'unrelated fresh gains on the same busy table must not '
            'trigger spurious sync cycles',
      );

      final results = <MutationSyncResult>[];
      final sub = manager.onMutationSyncResult.listen(results.add);
      connection.simulateIncoming(
        _createTransactionUpdate(
          querySetId: 1,
          tableName: 'folder',
          inserts: [awaited],
        ),
      );
      await pumpEventQueue();
      expect(connection.sentMessages, hasLength(2));
      await respondFailedToLastSend();
      await sub.cancel();

      expect(await storage.getPendingMutations(), isEmpty);
      expect(results, hasLength(1));
      expect(
        results.single.success,
        isTrue,
        reason:
            'the event-driven replay confirms via the abort-confirm '
            'short-circuit; nothing was dropped as a failure',
      );
    },
  );
}
