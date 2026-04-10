import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:spacetimedb_dart_sdk/codegen.dart';
import '../generated/note.dart';
import '../generated/folder.dart';
import '../generated/reducer_args.dart';
import '../helpers/integration_test_helper.dart';

const _timeout = Duration(seconds: 30);

class _CountingStorage implements OfflineStorage {
  final OfflineStorage _inner;

  int saveTableSnapshotCalls = 0;
  int setLastSyncTimeCalls = 0;
  int totalRowsSerialized = 0;

  final Map<String, int> saveTableSnapshotCallsByTable = {};

  _CountingStorage(this._inner);

  void resetCounters() {
    saveTableSnapshotCalls = 0;
    setLastSyncTimeCalls = 0;
    totalRowsSerialized = 0;
    saveTableSnapshotCallsByTable.clear();
  }

  @override
  Future<void> initialize() => _inner.initialize();

  @override
  Future<void> dispose() => _inner.dispose();

  @override
  Future<void> saveTableSnapshot(
    String tableName,
    List<Map<String, dynamic>> rows,
  ) async {
    saveTableSnapshotCalls++;
    totalRowsSerialized += rows.length;
    saveTableSnapshotCallsByTable.update(
      tableName,
      (v) => v + 1,
      ifAbsent: () => 1,
    );
    await _inner.saveTableSnapshot(tableName, rows);
  }

  @override
  Future<List<Map<String, dynamic>>?> loadTableSnapshot(String tableName) =>
      _inner.loadTableSnapshot(tableName);

  @override
  Future<void> enqueueMutation(PendingMutation mutation) =>
      _inner.enqueueMutation(mutation);

  @override
  Future<List<PendingMutation>> getPendingMutations() =>
      _inner.getPendingMutations();

  @override
  Future<void> dequeueMutation(String requestId) =>
      _inner.dequeueMutation(requestId);

  @override
  Future<void> setLastSyncTime(String tableName, DateTime time) async {
    setLastSyncTimeCalls++;
    await _inner.setLastSyncTime(tableName, time);
  }

  @override
  Future<DateTime?> getLastSyncTime(String tableName) =>
      _inner.getLastSyncTime(tableName);

  @override
  Future<void> clearAll() => _inner.clearAll();

  @override
  Future<void> clearTableSnapshot(String tableName) =>
      _inner.clearTableSnapshot(tableName);

  @override
  Future<void> clearMutationQueue() => _inner.clearMutationQueue();
}

void main() {
  setUpAll(ensureTestEnvironment);
  tearDownAll(cleanupTestEnvironment);

  group('persistTableSnapshots benchmark', () {
    late Directory tempDir;
    late _CountingStorage storage;
    late SpacetimeDbConnection connection;
    late SubscriptionManager subManager;

    Future<void> setupClient({required int preloadRowCount}) async {
      tempDir = await Directory.systemTemp.createTemp(
        'persist_benchmark_test_',
      );
      storage = _CountingStorage(JsonFileStorage(basePath: tempDir.path));

      connection = SpacetimeDbConnection(
        host: 'localhost:3000',
        database: 'notesdb',
      );
      subManager = SubscriptionManager(connection, offlineStorage: storage);

      subManager.cache.registerDecoder<Note>('note', NoteDecoder());
      subManager.cache.registerDecoder<Folder>('folder', FolderDecoder());
      subManager.cache.registerDecoder<Note>('all_notes', NoteDecoder());
      subManager.cache.registerDecoder<Note>('first_note', NoteDecoder());
      subManager.cache.registerDecoder<Note>('notes_query_all', NoteDecoder());

      subManager.reducerRegistry.register(createNoteDef);
      subManager.reducerRegistry.register(updateNoteDef);
      subManager.reducerRegistry.register(deleteNoteDef);
      subManager.reducerRegistry.register(deleteAllNotesDef);

      await connection.connect();
      await subManager.onIdentityToken.first.timeout(_timeout);

      subManager.subscribe(['SELECT * FROM note', 'SELECT * FROM folder']);
      await subManager.onInitialSubscription.first.timeout(_timeout);

      final deleteEnc = BsatnEncoder();
      await subManager.reducers
          .call('delete_all_notes', deleteEnc.toBytes())
          .timeout(_timeout);

      for (var i = 0; i < preloadRowCount; i++) {
        final enc = BsatnEncoder();
        enc.writeString('Preload $i');
        enc.writeString('Content for row $i with some padding text');
        await subManager.reducers
            .call('create_note', enc.toBytes())
            .timeout(_timeout);
      }
    }

    Future<void> cleanup() async {
      await connection.disconnect();
      await subManager.dispose();
      try {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      } catch (_) {}
    }

    test(
      'single-row update cost with 500 preloaded rows across 5 caches',
      () async {
        const preloadRowCount = 500;
        const measuredUpdates = 20;

        await setupClient(preloadRowCount: preloadRowCount);

        try {
          storage.resetCounters();

          final stopwatch = Stopwatch()..start();

          for (var i = 0; i < measuredUpdates; i++) {
            final enc = BsatnEncoder();
            enc.writeString('Measured update $i');
            enc.writeString('updated content $i');
            await subManager.reducers
                .call('create_note', enc.toBytes())
                .timeout(_timeout);
          }

          stopwatch.stop();

          // ignore: avoid_print
          print('');
          // ignore: avoid_print
          print('=== persistTableSnapshots benchmark ===');
          // ignore: avoid_print
          print('Preloaded rows:          $preloadRowCount');
          // ignore: avoid_print
          print('Registered tables:       5');
          // ignore: avoid_print
          print('Measured reducer calls:  $measuredUpdates');
          // ignore: avoid_print
          print('Total wall time:         ${stopwatch.elapsedMilliseconds} ms');
          // ignore: avoid_print
          print(
            'Per-call average:        ${(stopwatch.elapsedMilliseconds / measuredUpdates).toStringAsFixed(2)} ms',
          );
          // ignore: avoid_print
          print('saveTableSnapshot calls: ${storage.saveTableSnapshotCalls}');
          // ignore: avoid_print
          print('setLastSyncTime calls:   ${storage.setLastSyncTimeCalls}');
          // ignore: avoid_print
          print('Total rows serialized:   ${storage.totalRowsSerialized}');
          // ignore: avoid_print
          print(
            'Per-call serialized:     ${(storage.totalRowsSerialized / measuredUpdates).toStringAsFixed(1)} rows',
          );
          // ignore: avoid_print
          print('saveTableSnapshot by table:');
          for (final entry in storage.saveTableSnapshotCallsByTable.entries) {
            // ignore: avoid_print
            print('  ${entry.key.padRight(20)} ${entry.value}');
          }
          // ignore: avoid_print
          print('');

          expect(storage.saveTableSnapshotCalls, greaterThan(0));
          expect(storage.setLastSyncTimeCalls, greaterThan(0));
        } finally {
          await cleanup();
        }
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  });
}
