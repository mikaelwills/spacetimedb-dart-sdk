import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:spacetimedb_dart_sdk/spacetimedb_dart_sdk.dart';
import '../generated/note.dart';
import '../generated/reducer_args.dart';
import '../helpers/integration_test_helper.dart';

const _timeout = Duration(seconds: 10);

void main() {
  setUpAll(ensureTestEnvironment);
  tearDownAll(cleanupTestEnvironment);

  group('Offline Storage Integration Tests', () {
    late Directory tempDir;
    late JsonFileStorage storage;
    late SpacetimeDbConnection connection;
    late SubscriptionManager subManager;
    late TableCache<Note> noteTable;

    Future<void> setupWithStorage() async {
      tempDir = await Directory.systemTemp.createTemp(
        'offline_integration_test_',
      );
      storage = JsonFileStorage(basePath: tempDir.path);

      connection = SpacetimeDbConnection(
        host: 'localhost:3000',
        database: 'notesdb',
      );
      subManager = SubscriptionManager(connection, offlineStorage: storage);

      subManager.cache.registerDecoder<Note>('note', NoteDecoder());
      subManager.reducerRegistry.registerDecoder(
        'create_note',
        CreateNoteArgsDecoder(),
      );
      subManager.reducerRegistry.registerDecoder(
        'update_note',
        UpdateNoteArgsDecoder(),
      );
      subManager.reducerRegistry.registerDecoder(
        'delete_note',
        DeleteNoteArgsDecoder(),
      );

      await connection.connect();
      await subManager.onIdentityToken.first.timeout(_timeout);

      subManager.subscribe(['SELECT * FROM note']);
      await subManager.onInitialSubscription.first.timeout(_timeout);

      noteTable = subManager.cache.getTableByTypedName<Note>('note');
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

    group('Priority 1: Essential Tests', () {
      test(
        'Full Offline Round-Trip: queue mutation offline → reconnect → server confirms → cache confirms',
        () async {
          await setupWithStorage();

          try {
            final uniqueTitle =
                'Offline-${DateTime.now().millisecondsSinceEpoch}';

            final disconnectFuture = connection.connectionStatus
                .firstWhere((s) => s != ConnectionStatus.connected)
                .timeout(_timeout);
            await connection.disconnect();
            await disconnectFuture;

            final syncResultFuture = subManager.onMutationSyncResult.first;

            final result = await subManager.reducers
                .callWith(
                  'create_note',
                  (encoder) {
                    encoder.writeString(uniqueTitle);
                    encoder.writeString('Created while offline');
                  },
                  optimisticChanges: [
                    OptimisticChange.insert('note', {
                      'id': 999999,
                      'title': uniqueTitle,
                      'content': 'Created while offline',
                      'timestamp': DateTime.now().microsecondsSinceEpoch,
                      'status': {'type': 'draft'},
                    }),
                  ],
                )
                .timeout(_timeout);

            expect(
              result.isPending,
              isTrue,
              reason: 'Should return pending result when offline',
            );
            expect(result.pendingRequestId, isNotNull);

            final pending = await storage.getPendingMutations().timeout(
              _timeout,
            );
            expect(
              pending.length,
              equals(1),
              reason: 'Should have 1 pending mutation',
            );
            expect(pending.first.reducerName, equals('create_note'));

            await connection.connect();
            await subManager.onIdentityToken.first.timeout(_timeout);
            subManager.subscribe(['SELECT * FROM note']);
            await subManager.onInitialSubscription.first.timeout(_timeout);

            final syncResult = await syncResultFuture.timeout(_timeout);

            expect(syncResult.success, isTrue, reason: 'Sync should succeed');
            expect(syncResult.reducerName, equals('create_note'));

            final pendingAfterSync = await storage
                .getPendingMutations()
                .timeout(_timeout);
            expect(
              pendingAfterSync,
              isEmpty,
              reason: 'Pending queue should be empty after sync',
            );

            expect(subManager.syncState.pendingCount, equals(0));
          } finally {
            await cleanup();
          }
        },
        timeout: const Timeout(Duration(seconds: 30)),
      );

      test(
        'Crash Recovery: persist pending mutations → restart → load cache → sync succeeds',
        () async {
          tempDir = await Directory.systemTemp.createTemp(
            'crash_recovery_test_',
          );
          storage = JsonFileStorage(basePath: tempDir.path);
          await storage.initialize();

          final uniqueTitle =
              'CrashRecovery-${DateTime.now().millisecondsSinceEpoch}';

          await storage
              .enqueueMutation(
                PendingMutation(
                  requestId: 'crash-test-req-1',
                  reducerName: 'create_note',
                  encodedArgs: _encodeCreateNoteArgs(
                    uniqueTitle,
                    'Survived crash',
                  ),
                  createdAt: DateTime.now(),
                  optimisticChanges: [
                    OptimisticChange.insert('note', {
                      'id': 888888,
                      'title': uniqueTitle,
                      'content': 'Survived crash',
                      'timestamp': DateTime.now().microsecondsSinceEpoch,
                      'status': {'type': 'draft'},
                    }),
                  ],
                ),
              )
              .timeout(_timeout);

          await storage
              .saveTableSnapshot('note', [
                {
                  'id': 1,
                  'title': 'Cached Note',
                  'content': 'From before crash',
                  'timestamp': DateTime.now().microsecondsSinceEpoch,
                  'status': {'type': 'draft'},
                },
              ])
              .timeout(_timeout);

          await storage.dispose();

          final newStorage = JsonFileStorage(basePath: tempDir.path);

          connection = SpacetimeDbConnection(
            host: 'localhost:3000',
            database: 'notesdb',
          );
          subManager = SubscriptionManager(
            connection,
            offlineStorage: newStorage,
          );

          subManager.cache.registerDecoder<Note>('note', NoteDecoder());
          subManager.reducerRegistry.registerDecoder(
            'create_note',
            CreateNoteArgsDecoder(),
          );

          await subManager.loadFromOfflineCache();

          noteTable = subManager.cache.getTableByTypedName<Note>('note');
          expect(
            noteTable.count(),
            greaterThanOrEqualTo(1),
            reason: 'Should have loaded cached data',
          );

          expect(
            subManager.syncState.pendingCount,
            equals(1),
            reason: 'Should have 1 pending mutation from crash',
          );

          final syncResultFuture = subManager.onMutationSyncResult.first;

          await connection.connect();
          await subManager.onIdentityToken.first.timeout(_timeout);
          subManager.subscribe(['SELECT * FROM note']);
          await subManager.onInitialSubscription.first.timeout(_timeout);

          final syncResult = await syncResultFuture.timeout(_timeout);

          expect(
            syncResult.success,
            isTrue,
            reason: 'Pending mutation should sync successfully',
          );

          final pendingAfter = await newStorage.getPendingMutations().timeout(
            _timeout,
          );
          expect(pendingAfter, isEmpty);

          await subManager.dispose();
          await connection.disconnect();
          await newStorage.dispose();
          try {
            if (await tempDir.exists()) {
              await tempDir.delete(recursive: true);
            }
          } catch (_) {}
        },
        timeout: const Timeout(Duration(seconds: 30)),
      );
    });

    group('Priority 2: Important Tests', () {
      test(
        'Batch Sync: multiple offline mutations sync successfully on reconnect',
        () async {
          await setupWithStorage();

          try {
            final disconnectFuture = connection.connectionStatus
                .firstWhere((s) => s != ConnectionStatus.connected)
                .timeout(_timeout);
            await connection.disconnect();
            await disconnectFuture;

            final results = <TransactionResult>[];
            for (var i = 0; i < 3; i++) {
              final uniqueTitle =
                  'Multi-$i-${DateTime.now().millisecondsSinceEpoch}';
              final result = await subManager.reducers
                  .callWith('create_note', (encoder) {
                    encoder.writeString(uniqueTitle);
                    encoder.writeString('Content $i');
                  })
                  .timeout(_timeout);
              results.add(result);
            }

            expect(results.every((r) => r.isPending), isTrue);

            final pending = await storage.getPendingMutations().timeout(
              _timeout,
            );
            expect(pending.length, equals(3));

            final syncResultsCompleter = Completer<List<MutationSyncResult>>();
            final syncResults = <MutationSyncResult>[];
            final subscription = subManager.onMutationSyncResult.listen((
              result,
            ) {
              syncResults.add(result);
              if (syncResults.length == 3) {
                syncResultsCompleter.complete(syncResults);
              }
            });

            await connection.connect();
            await subManager.onIdentityToken.first.timeout(_timeout);
            subManager.subscribe(['SELECT * FROM note']);
            await subManager.onInitialSubscription.first.timeout(_timeout);

            await syncResultsCompleter.future.timeout(_timeout);
            await subscription.cancel();

            expect(
              syncResults.length,
              equals(3),
              reason: 'Should have 3 sync results',
            );
            expect(
              syncResults.every((r) => r.success),
              isTrue,
              reason: 'All should succeed',
            );

            final pendingAfter = await storage.getPendingMutations().timeout(
              _timeout,
            );
            expect(pendingAfter, isEmpty);
          } finally {
            await cleanup();
          }
        },
        timeout: const Timeout(Duration(seconds: 30)),
      );

      test(
        'SyncState stream updates correctly during offline/online transitions',
        () async {
          await setupWithStorage();

          try {
            final syncStates = <SyncState>[];
            final subscription = subManager.onSyncStateChanged.listen(
              syncStates.add,
            );

            final disconnectFuture = connection.connectionStatus
                .firstWhere((s) => s != ConnectionStatus.connected)
                .timeout(_timeout);
            await connection.disconnect();
            await disconnectFuture;

            await subManager.reducers
                .callWith('create_note', (encoder) {
                  encoder.writeString(
                    'SyncState-Test-${DateTime.now().millisecondsSinceEpoch}',
                  );
                  encoder.writeString('Testing sync state');
                })
                .timeout(_timeout);

            expect(subManager.syncState.pendingCount, equals(1));

            final idleCompleter = Completer<void>();
            final idleSubscription = subManager.onSyncStateChanged.listen((s) {
              if (s.isIdle &&
                  s.pendingCount == 0 &&
                  !idleCompleter.isCompleted) {
                idleCompleter.complete();
              }
            });

            await connection.connect();
            await subManager.onIdentityToken.first.timeout(_timeout);
            subManager.subscribe(['SELECT * FROM note']);
            await subManager.onInitialSubscription.first.timeout(_timeout);

            await idleCompleter.future.timeout(_timeout);
            await idleSubscription.cancel();
            await subscription.cancel();

            final syncingStates = syncStates.where((s) => s.isSyncing).toList();
            final finalState = syncStates.last;

            expect(
              syncingStates,
              isNotEmpty,
              reason: 'Should have syncing state',
            );
            expect(
              finalState.isIdle,
              isTrue,
              reason: 'Final state should be idle',
            );
            expect(
              finalState.pendingCount,
              equals(0),
              reason: 'Should have 0 pending',
            );
          } finally {
            await cleanup();
          }
        },
        timeout: const Timeout(Duration(seconds: 30)),
      );
    });

    group('Priority 3: Edge Cases', () {
      test(
        'Table snapshot is saved on InitialSubscription',
        () async {
          await setupWithStorage();

          try {
            final snapshot = await storage
                .loadTableSnapshot('note')
                .timeout(_timeout);
            expect(
              snapshot,
              isNotNull,
              reason: 'Snapshot should be saved after InitialSubscription',
            );
            expect(
              snapshot!.isNotEmpty,
              isTrue,
              reason: 'Snapshot should have data from server',
            );

            final syncTime = await storage
                .getLastSyncTime('note')
                .timeout(_timeout);
            expect(syncTime, isNotNull, reason: 'Sync time should be recorded');
          } finally {
            await cleanup();
          }
        },
        timeout: const Timeout(Duration(seconds: 30)),
      );

      test(
        'FIFO Ordering: mutations are synced and reported in strict submission order',
        () async {
          await setupWithStorage();

          try {
            final disconnectFuture = connection.connectionStatus
                .firstWhere((s) => s != ConnectionStatus.connected)
                .timeout(_timeout);
            await connection.disconnect();
            await disconnectFuture;

            final uniqueId = DateTime.now().millisecondsSinceEpoch % 0xFFFFFFFF;
            final mutations = <String>[
              'create_note',
              'update_note',
              'delete_note',
            ];
            final requestIds = <String>[];

            final res1 = await subManager.reducers
                .callWith('create_note', (encoder) {
                  encoder.writeString('OrderTest-$uniqueId');
                  encoder.writeString('Initial Content');
                })
                .timeout(_timeout);
            requestIds.add(res1.pendingRequestId!);

            final res2 = await subManager.reducers
                .callWith('update_note', (encoder) {
                  encoder.writeU32(uniqueId);
                  encoder.writeString('OrderTest-$uniqueId');
                  encoder.writeString('Updated Content');
                })
                .timeout(_timeout);
            requestIds.add(res2.pendingRequestId!);

            final res3 = await subManager.reducers
                .callWith('delete_note', (encoder) {
                  encoder.writeU32(uniqueId);
                })
                .timeout(_timeout);
            requestIds.add(res3.pendingRequestId!);

            expect(subManager.syncState.pendingCount, equals(3));

            final completedSyncs = <MutationSyncResult>[];
            final allDone = Completer<void>();

            final sub = subManager.onMutationSyncResult.listen((result) {
              completedSyncs.add(result);
              if (completedSyncs.length == 3) {
                allDone.complete();
              }
            });

            await connection.connect();
            await subManager.onIdentityToken.first.timeout(_timeout);
            subManager.subscribe(['SELECT * FROM note']);
            await subManager.onInitialSubscription.first.timeout(_timeout);

            await allDone.future.timeout(_timeout);
            await sub.cancel();

            expect(completedSyncs.length, equals(3));

            for (var i = 0; i < 3; i++) {
              expect(
                completedSyncs[i].requestId,
                equals(requestIds[i]),
                reason: 'Mutation at index $i should match request at index $i',
              );
              expect(completedSyncs[i].success, isTrue);
              expect(completedSyncs[i].reducerName, equals(mutations[i]));
            }

            expect(subManager.syncState.pendingCount, equals(0));
          } finally {
            await cleanup();
          }
        },
        timeout: const Timeout(Duration(seconds: 30)),
      );
    });
  });
}

Uint8List _encodeCreateNoteArgs(String title, String content) {
  final encoder = BsatnEncoder();
  encoder.writeString(title);
  encoder.writeString(content);
  return encoder.toBytes();
}
