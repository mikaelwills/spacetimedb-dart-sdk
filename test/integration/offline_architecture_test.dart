// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:spacetimedb_sdk/codegen.dart';
import '../generated/note.dart';
import '../generated/folder.dart';
import '../generated/reducer_args.dart';
import '../helpers/integration_test_helper.dart';
import '../helpers/value_notifier_helpers.dart';

const _timeout = Duration(seconds: 10);

void main() {
  setUpAll(ensureTestEnvironment);
  tearDownAll(cleanupTestEnvironment);

  group('Phase 1: Zombie Slayer Tests', () {
    late Directory tempDir;
    late JsonFileStorage storage;
    late SpacetimeDbConnection connection;
    late SubscriptionManager subManager;
    late TableCache<Note> noteTable;

    Future<void> createStorageWithCachedNote(int noteId, String title) async {
      tempDir = await Directory.systemTemp.createTemp('zombie_test_');
      storage = JsonFileStorage(basePath: tempDir.path);
      await storage.initialize();

      await storage.saveTableSnapshot('note', [
        {
          'id': noteId,
          'title': title,
          'content': 'Cached content',
          'timestamp': DateTime.now().microsecondsSinceEpoch,
          'status': {'type': 'draft'},
        },
      ]);
      await storage.setLastSyncTime('note', DateTime.now());
    }

    Future<void> cleanup() async {
      await subManager.dispose();
      await connection.disconnect();
      try {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      } catch (_) {}
    }

    test(
      'Stale Data Purge: cached data not on server is removed on InitialSubscription',
      () async {
        final staleNoteId = DateTime.now().microsecondsSinceEpoch;
        await createStorageWithCachedNote(staleNoteId, 'Stale Note A');

        addTearDown(cleanup);

        connection = SpacetimeDbConnection(
          host: 'localhost:3000',
          database: 'notesdb',
        );
        subManager = SubscriptionManager(connection, offlineStorage: storage);
        subManager.cache.registerDecoder<Note>('note', NoteDecoder());
        subManager.reducerRegistry.register(createNoteDef);

        await subManager.loadFromOfflineCache();
        noteTable = subManager.cache.getTableByTypedName<Note>('note');
        final noteTableBefore = noteTable;

        expect(
          noteTable.getRow(staleNoteId),
          isNotNull,
          reason: 'Stale note should be loaded from cache before connect',
        );

        await connection.connect();
        await subManager.onInitialConnection.first.timeout(_timeout);
        subManager.subscribe(['SELECT * FROM note']);
        await subManager.onSubscribeApplied.first.timeout(_timeout);

        final noteTableAfter = subManager.cache.getTableByTypedName<Note>(
          'note',
        );
        expect(
          identical(noteTableBefore, noteTableAfter),
          isTrue,
          reason:
              'TableCache instance must remain the same so UI listeners are not detached',
        );

        expect(
          noteTable.getRow(staleNoteId),
          isNull,
          reason:
              'Stale note should be purged after InitialSubscription (server is authoritative)',
        );
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
      'Protected Pending Work: optimistic rows survive InitialSubscription purge until synced',
      () async {
        final staleNoteId = DateTime.now().microsecondsSinceEpoch;
        final optimisticNoteId = staleNoteId + 1;
        await createStorageWithCachedNote(staleNoteId, 'Stale Note');

        final optimisticTitle =
            'Optimistic-${DateTime.now().microsecondsSinceEpoch}';
        await storage.enqueueMutation(
          PendingMutation(
            requestId: 'pending-req-1',
            reducerName: 'create_note',
            encodedArgs: _encodeCreateNoteArgs(
              optimisticTitle,
              'Pending content',
            ),
            createdAt: DateTime.now(),
            optimisticChanges: [
              OptimisticChange.insert('note', {
                'id': optimisticNoteId,
                'title': optimisticTitle,
                'content': 'Pending content',
                'timestamp': DateTime.now().microsecondsSinceEpoch,
                'status': {'type': 'draft'},
              }),
            ],
          ),
        );

        addTearDown(cleanup);

        connection = SpacetimeDbConnection(
          host: 'localhost:3000',
          database: 'notesdb',
        );
        subManager = SubscriptionManager(connection, offlineStorage: storage);
        subManager.cache.registerDecoder<Note>('note', NoteDecoder());
        subManager.reducerRegistry.register(createNoteDef);

        await subManager.loadFromOfflineCache();
        noteTable = subManager.cache.getTableByTypedName<Note>('note');

        expect(
          noteTable.getRow(staleNoteId),
          isNotNull,
          reason: 'Stale note should be loaded',
        );
        expect(
          noteTable.getRow(optimisticNoteId),
          isNotNull,
          reason: 'Optimistic note should be loaded from pending mutation',
        );

        final syncCompleter = Completer<void>();
        final syncSub = subManager.onMutationSyncResult.listen((result) {
          if (!syncCompleter.isCompleted) {
            syncCompleter.complete();
          }
        });

        await connection.connect();
        await subManager.onInitialConnection.first.timeout(_timeout);
        subManager.subscribe(['SELECT * FROM note']);
        await subManager.onSubscribeApplied.first.timeout(_timeout);

        expect(
          noteTable.getRow(staleNoteId),
          isNull,
          reason: 'Stale note should be purged',
        );

        expect(
          noteTable.getRow(optimisticNoteId),
          isNotNull,
          reason:
              'CRITICAL: Optimistic row must NOT be purged by InitialSubscription. '
              'If this fails, the UI will blink/flash empty before sync completes.',
        );

        await syncCompleter.future.timeout(_timeout);
        await syncSub.cancel();

        expect(
          noteTable.getRow(optimisticNoteId),
          isNotNull,
          reason:
              'Row should still exist after sync (client-generated ID is preserved by server)',
        );

        final note = noteTable.getRow(optimisticNoteId)!;
        expect(
          note.title,
          equals(optimisticTitle),
          reason: 'Row should have correct title after sync',
        );
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
      'Delete Persistence: deleted rows stay deleted after app restart',
      () async {
        tempDir = await Directory.systemTemp.createTemp('delete_persist_test_');
        storage = JsonFileStorage(basePath: tempDir.path);

        addTearDown(() async {
          try {
            if (await tempDir.exists()) {
              await tempDir.delete(recursive: true);
            }
          } catch (_) {}
        });

        connection = SpacetimeDbConnection(
          host: 'localhost:3000',
          database: 'notesdb',
        );
        subManager = SubscriptionManager(connection, offlineStorage: storage);
        subManager.cache.registerDecoder<Note>('note', NoteDecoder());
        subManager.reducerRegistry.register(createNoteDef);
        subManager.reducerRegistry.register(deleteNoteDef);

        await connection.connect();
        await subManager.onInitialConnection.first.timeout(_timeout);
        subManager.subscribe(['SELECT * FROM note']);
        await subManager.onSubscribeApplied.first.timeout(_timeout);

        noteTable = subManager.cache.getTableByTypedName<Note>('note');

        final testTitle = 'DeleteTest-${DateTime.now().microsecondsSinceEpoch}';
        final insertFuture = waitForInsert(
          noteTable,
          (n) => n.title == testTitle,
          timeout: _timeout,
        );

        final encCreate = BsatnEncoder();
        encCreate.writeString(testTitle);
        encCreate.writeString('Content to delete');
        await subManager.reducers.call('create_note', encCreate.toBytes());

        final noteToDelete = await insertFuture;
        final noteId = noteToDelete.id;

        final deleteFuture = waitForDelete(
          noteTable,
          (n) => n.id == noteId,
          timeout: _timeout,
        );

        final encDel = BsatnEncoder();
        encDel.writeU32(noteId);
        await subManager.reducers.call('delete_note', encDel.toBytes());

        await deleteFuture;

        expect(
          noteTable.getRow(noteId),
          isNull,
          reason: 'Note should be deleted from cache',
        );

        await subManager.dispose();
        await connection.disconnect();

        final newStorage = JsonFileStorage(basePath: tempDir.path);
        final newConnection = SpacetimeDbConnection(
          host: 'localhost:3000',
          database: 'notesdb',
        );
        final newSubManager = SubscriptionManager(
          newConnection,
          offlineStorage: newStorage,
        );
        newSubManager.cache.registerDecoder<Note>('note', NoteDecoder());

        await newSubManager.loadFromOfflineCache();
        final newNoteTable = newSubManager.cache.getTableByTypedName<Note>(
          'note',
        );

        expect(
          newNoteTable.getRow(noteId),
          isNull,
          reason: 'Deleted note should not be in persisted cache after restart',
        );

        await newSubManager.dispose();
        await newConnection.disconnect();
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  });

  group('Phase 2: Identity & Stream Stability', () {
    late Directory tempDir;
    late JsonFileStorage storage;
    late SpacetimeDbConnection connection;
    late SubscriptionManager subManager;

    Future<void> cleanup() async {
      await subManager.dispose();
      await connection.disconnect();
      try {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      } catch (_) {}
    }

    test(
      'Table Instance Preservation: listeners survive first server snapshot',
      () async {
        tempDir = await Directory.systemTemp.createTemp('listener_test_');
        storage = JsonFileStorage(basePath: tempDir.path);
        await storage.initialize();

        final cachedNoteId = DateTime.now().microsecondsSinceEpoch;
        await storage.saveTableSnapshot('note', [
          {
            'id': cachedNoteId,
            'title': 'Cached Note',
            'content': 'From offline',
            'timestamp': DateTime.now().microsecondsSinceEpoch,
            'status': {'type': 'draft'},
          },
        ]);

        addTearDown(cleanup);

        connection = SpacetimeDbConnection(
          host: 'localhost:3000',
          database: 'notesdb',
        );
        subManager = SubscriptionManager(connection, offlineStorage: storage);
        subManager.cache.registerDecoder<Note>('note', NoteDecoder());
        subManager.reducerRegistry.register(createNoteDef);

        await subManager.loadFromOfflineCache();
        final noteTableBefore = subManager.cache.getTableByTypedName<Note>(
          'note',
        );
        final instanceBefore = identityHashCode(noteTableBefore);

        final collector = EventCollector(noteTableBefore);

        await connection.connect();
        await subManager.onInitialConnection.first.timeout(_timeout);
        subManager.subscribe(['SELECT * FROM note']);
        await subManager.onSubscribeApplied.first.timeout(_timeout);

        final noteTableAfter = subManager.cache.getTableByTypedName<Note>(
          'note',
        );
        final instanceAfter = identityHashCode(noteTableAfter);

        expect(
          instanceAfter,
          equals(instanceBefore),
          reason:
              'Table instance should be preserved after first server snapshot',
        );

        final createCompleter = Completer<void>();
        final createSub = subManager.reducerEmitter.on(createNoteDef).listen((
          _,
        ) {
          if (!createCompleter.isCompleted) {
            createCompleter.complete();
          }
        });

        final encInst = BsatnEncoder();
        encInst.writeString(
          'InstanceTest-${DateTime.now().microsecondsSinceEpoch}',
        );
        encInst.writeString('Testing instance preservation');
        await subManager.reducers.call('create_note', encInst.toBytes());

        await createCompleter.future.timeout(_timeout);
        await createSub.cancel();
        collector.dispose();

        expect(
          collector.events,
          isNotEmpty,
          reason:
              'Listener on pre-connect instance should still receive events after first server snapshot',
        );
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
      'Event Stream Propagation: optimistic changes emit to EventStream',
      () async {
        tempDir = await Directory.systemTemp.createTemp('event_stream_test_');
        storage = JsonFileStorage(basePath: tempDir.path);

        addTearDown(cleanup);

        connection = SpacetimeDbConnection(
          host: 'localhost:3000',
          database: 'notesdb',
        );
        subManager = SubscriptionManager(connection, offlineStorage: storage);
        subManager.cache.registerDecoder<Note>('note', NoteDecoder());
        subManager.reducerRegistry.register(createNoteDef);

        await connection.connect();
        await subManager.onInitialConnection.first.timeout(_timeout);
        subManager.subscribe(['SELECT * FROM note']);
        await subManager.onSubscribeApplied.first.timeout(_timeout);

        final noteTable = subManager.cache.getTableByTypedName<Note>('note');

        final disconnectFuture = connection.onStateChanged
            .firstWhere((s) => s is! Connected)
            .timeout(_timeout);
        await connection.disconnect();
        await disconnectFuture;

        final eventFuture = waitForEvent(noteTable, timeout: _timeout);

        final optimisticId = DateTime.now().microsecondsSinceEpoch;
        final encEvt = BsatnEncoder();
        encEvt.writeString('EventStream-Test');
        encEvt.writeString('Content');
        await subManager.reducers.call(
          'create_note',
          encEvt.toBytes(),
          optimisticChanges: [
            OptimisticChange.insert('note', {
              'id': optimisticId,
              'title': 'EventStream-Test',
              'content': 'Content',
              'timestamp': DateTime.now().microsecondsSinceEpoch,
              'status': {'type': 'draft'},
            }),
          ],
        );

        final event = await eventFuture;

        expect(
          event,
          isA<TableInsertEvent<Note>>(),
          reason: 'Optimistic insert should emit TableInsertEvent to lastBatch',
        );
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  });

  group('Phase 3: Online Optimistic Flow', () {
    late Directory tempDir;
    late JsonFileStorage storage;
    late SpacetimeDbConnection connection;
    late SubscriptionManager subManager;
    late TableCache<Note> noteTable;

    Future<void> setup() async {
      tempDir = await Directory.systemTemp.createTemp(
        'online_optimistic_test_',
      );
      storage = JsonFileStorage(basePath: tempDir.path);

      connection = SpacetimeDbConnection(
        host: 'localhost:3000',
        database: 'notesdb',
      );
      subManager = SubscriptionManager(connection, offlineStorage: storage);
      subManager.cache.registerDecoder<Note>('note', NoteDecoder());
      subManager.reducerRegistry.register(createNoteDef);
      subManager.reducerRegistry.register(deleteNoteDef);

      await connection.connect();
      await subManager.onInitialConnection.first.timeout(_timeout);
      subManager.subscribe(['SELECT * FROM note']);
      await subManager.onSubscribeApplied.first.timeout(_timeout);

      noteTable = subManager.cache.getTableByTypedName<Note>('note');
    }

    Future<void> cleanup() async {
      await subManager.dispose();
      await connection.disconnect();
      try {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      } catch (_) {}
    }

    test(
      'Immediate Online Feedback: optimistic row appears instantly, pendingCount stays 0',
      () async {
        await setup();
        addTearDown(cleanup);

        final initialCount = noteTable.count();
        final optimisticId = DateTime.now().microsecondsSinceEpoch;

        final encOnl = BsatnEncoder();
        encOnl.writeString('Online-Optimistic-Test');
        encOnl.writeString('Instant feedback');
        subManager.reducers.call(
          'create_note',
          encOnl.toBytes(),
          optimisticChanges: [
            OptimisticChange.insert('note', {
              'id': optimisticId,
              'title': 'Online-Optimistic-Test',
              'content': 'Instant feedback',
              'timestamp': DateTime.now().microsecondsSinceEpoch,
              'status': {'type': 'draft'},
            }),
          ],
        );

        expect(
          noteTable.count(),
          equals(initialCount + 1),
          reason: 'Row should appear immediately (synchronously)',
        );
        expect(
          noteTable.getRow(optimisticId),
          isNotNull,
          reason: 'Optimistic row should be findable',
        );
        expect(
          subManager.syncState.pendingCount,
          equals(0),
          reason: 'Online mutations should NOT increment pendingCount',
        );
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
      'Online Confirm: successful transaction removes optimistic placeholder',
      () async {
        await setup();
        addTearDown(cleanup);

        final initialCount = noteTable.count();
        final optimisticId = DateTime.now().microsecondsSinceEpoch;
        final optimisticTitle = 'Confirm-Test-$optimisticId';

        final syncCompleter = Completer<MutationSyncResult>();
        final syncSub = subManager.onMutationSyncResult.listen((result) {
          if (result.reducerName == 'create_note' &&
              !syncCompleter.isCompleted) {
            syncCompleter.complete(result);
          }
        });

        final encOpt = BsatnEncoder();
        encOpt.writeString(optimisticTitle);
        encOpt.writeString('Should be confirmed');
        final result = await subManager.reducers.call(
          'create_note',
          encOpt.toBytes(),
          optimisticChanges: [
            OptimisticChange.insert('note', {
              'id': optimisticId,
              'title': optimisticTitle,
              'content': 'Should be confirmed',
              'timestamp': DateTime.now().microsecondsSinceEpoch,
              'status': {'type': 'draft'},
            }),
          ],
        );

        expect(
          result.isPending,
          isTrue,
          reason: 'Offline-first returns pending immediately',
        );
        expect(
          noteTable.getRow(optimisticId),
          isNotNull,
          reason: 'Optimistic row should exist immediately',
        );

        final syncResult = await syncCompleter.future.timeout(_timeout);
        await syncSub.cancel();

        expect(syncResult.success, isTrue, reason: 'Sync should succeed');

        expect(
          noteTable.getRow(optimisticId),
          isNotNull,
          reason:
              'Row should still exist after server confirms (client-generated ID is preserved)',
        );

        expect(
          noteTable.count(),
          equals(initialCount + 1),
          reason: 'New row should exist with client-generated ID',
        );
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
      'Online Delete Integrity: Real server confirmation keeps row deleted (Zombie Killer)',
      () async {
        await setup();
        addTearDown(cleanup);

        final createSyncCompleter = Completer<void>();
        final createSub = subManager.onMutationSyncResult.listen((result) {
          if (result.reducerName == 'create_note' &&
              !createSyncCompleter.isCompleted) {
            createSyncCompleter.complete();
          }
        });

        final testTitle =
            'ZombieKiller-${DateTime.now().microsecondsSinceEpoch}';
        final encZombie = BsatnEncoder();
        encZombie.writeString(testTitle);
        encZombie.writeString('Will be deleted');
        await subManager.reducers.call('create_note', encZombie.toBytes());

        await createSyncCompleter.future.timeout(_timeout);
        await createSub.cancel();

        await Future.delayed(const Duration(milliseconds: 100));

        final noteToDelete = noteTable.iter().firstWhere(
          (n) => n.title == testTitle,
        );
        final noteId = noteToDelete.id;
        expect(
          noteTable.getRow(noteId),
          isNotNull,
          reason: 'Setup: note exists',
        );

        final deleteSyncCompleter = Completer<MutationSyncResult>();
        final deleteSub = subManager.onMutationSyncResult.listen((result) {
          if (result.reducerName == 'delete_note' &&
              !deleteSyncCompleter.isCompleted) {
            deleteSyncCompleter.complete(result);
          }
        });

        final encDelOpt = BsatnEncoder();
        encDelOpt.writeU32(noteId);
        final result = await subManager.reducers.call(
          'delete_note',
          encDelOpt.toBytes(),
          optimisticChanges: [
            OptimisticChange.delete('note', noteToDelete.toJson()),
          ],
        );

        expect(
          result.isPending,
          isTrue,
          reason: 'Offline-first returns pending immediately',
        );
        expect(
          noteTable.getRow(noteId),
          isNull,
          reason: 'Row should be removed immediately by optimistic delete',
        );

        final syncResult = await deleteSyncCompleter.future.timeout(_timeout);
        await deleteSub.cancel();
        expect(
          syncResult.success,
          isTrue,
          reason: 'Server must confirm delete',
        );

        await Future.delayed(const Duration(milliseconds: 50));

        expect(
          noteTable.getRow(noteId),
          isNull,
          reason:
              'CRITICAL: Row must NOT reappear after server confirmation. '
              'If this fails, the touched-keys wiring in SubscriptionManager is broken.',
        );
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  });

  group('Phase 4: Offline Queue Management', () {
    late Directory tempDir;
    late JsonFileStorage storage;
    late SpacetimeDbConnection connection;
    late SubscriptionManager subManager;

    Future<void> cleanup() async {
      await subManager.dispose();
      await connection.disconnect();
      try {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      } catch (_) {}
    }

    test(
      'Queue Count Accuracy: pendingCount tracks mutations correctly',
      () async {
        tempDir = await Directory.systemTemp.createTemp('queue_count_test_');
        storage = JsonFileStorage(basePath: tempDir.path);

        addTearDown(cleanup);

        connection = SpacetimeDbConnection(
          host: 'localhost:3000',
          database: 'notesdb',
        );
        subManager = SubscriptionManager(connection, offlineStorage: storage);
        subManager.cache.registerDecoder<Note>('note', NoteDecoder());
        subManager.reducerRegistry.register(createNoteDef);

        await connection.connect();
        await subManager.onInitialConnection.first.timeout(_timeout);
        subManager.subscribe(['SELECT * FROM note']);
        await subManager.onSubscribeApplied.first.timeout(_timeout);

        expect(
          subManager.syncState.pendingCount,
          equals(0),
          reason: 'Should start with 0 pending',
        );

        final disconnectFuture = connection.onStateChanged
            .firstWhere((s) => s is! Connected)
            .timeout(_timeout);
        await connection.disconnect();
        await disconnectFuture;

        for (var i = 0; i < 3; i++) {
          final enc = BsatnEncoder();
          enc.writeString('Queue-Test-$i');
          enc.writeString('Content $i');
          await subManager.reducers.call('create_note', enc.toBytes());
        }

        expect(
          subManager.syncState.pendingCount,
          equals(3),
          reason: 'Should have 3 pending mutations after offline calls',
        );

        final syncCompleter = Completer<void>();
        final syncResults = <MutationSyncResult>[];
        final syncSub = subManager.onMutationSyncResult.listen((result) {
          syncResults.add(result);
          if (syncResults.length == 3 && !syncCompleter.isCompleted) {
            syncCompleter.complete();
          }
        });

        await connection.connect();
        await subManager.onInitialConnection.first.timeout(_timeout);
        subManager.subscribe(['SELECT * FROM note']);
        await subManager.onSubscribeApplied.first.timeout(_timeout);

        await syncCompleter.future.timeout(_timeout);
        await syncSub.cancel();

        expect(
          subManager.syncState.pendingCount,
          equals(0),
          reason: 'Should have 0 pending after sync completes',
        );

        for (final result in syncResults) {
          expect(
            result.success,
            isTrue,
            reason:
                'All mutations must succeed - ${result.reducerName} failed: ${result.error}',
          );
        }
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
      'FIFO Ordering: Create → Update → Delete executes in order',
      () async {
        tempDir = await Directory.systemTemp.createTemp('fifo_test_');
        storage = JsonFileStorage(basePath: tempDir.path);

        addTearDown(cleanup);

        connection = SpacetimeDbConnection(
          host: 'localhost:3000',
          database: 'notesdb',
        );
        subManager = SubscriptionManager(connection, offlineStorage: storage);
        subManager.cache.registerDecoder<Note>('note', NoteDecoder());
        subManager.reducerRegistry.register(createNoteDef);
        subManager.reducerRegistry.register(updateNoteDef);
        subManager.reducerRegistry.register(deleteNoteDef);

        await connection.connect();
        await subManager.onInitialConnection.first.timeout(_timeout);
        subManager.subscribe(['SELECT * FROM note']);
        await subManager.onSubscribeApplied.first.timeout(_timeout);

        final disconnectFuture = connection.onStateChanged
            .firstWhere((s) => s is! Connected)
            .timeout(_timeout);
        await connection.disconnect();
        await disconnectFuture;

        final uniqueId = DateTime.now().millisecondsSinceEpoch % 0xFFFFFFFF;
        final expectedOrder = <String>[
          'create_note',
          'update_note',
          'delete_note',
        ];
        final requestIds = <String>[];

        final fifoEnc1 = BsatnEncoder();
        fifoEnc1.writeString('FIFO-Test-$uniqueId');
        fifoEnc1.writeString('Initial');
        final res1 = await subManager.reducers.call(
          'create_note',
          fifoEnc1.toBytes(),
        );
        requestIds.add(res1.pendingRequestId!);

        final fifoEnc2 = BsatnEncoder();
        fifoEnc2.writeU32(uniqueId);
        fifoEnc2.writeString('FIFO-Test-$uniqueId');
        fifoEnc2.writeString('Updated');
        final res2 = await subManager.reducers.call(
          'update_note',
          fifoEnc2.toBytes(),
        );
        requestIds.add(res2.pendingRequestId!);

        final fifoEnc3 = BsatnEncoder();
        fifoEnc3.writeU32(uniqueId);
        final res3 = await subManager.reducers.call(
          'delete_note',
          fifoEnc3.toBytes(),
        );
        requestIds.add(res3.pendingRequestId!);

        final syncResults = <MutationSyncResult>[];
        final syncCompleter = Completer<void>();
        final syncSub = subManager.onMutationSyncResult.listen((result) {
          syncResults.add(result);
          if (syncResults.length == 3 && !syncCompleter.isCompleted) {
            syncCompleter.complete();
          }
        });

        await connection.connect();
        await subManager.onInitialConnection.first.timeout(_timeout);
        subManager.subscribe(['SELECT * FROM note']);
        await subManager.onSubscribeApplied.first.timeout(_timeout);

        await syncCompleter.future.timeout(_timeout);
        await syncSub.cancel();

        expect(syncResults.length, equals(3));
        for (var i = 0; i < 3; i++) {
          expect(
            syncResults[i].requestId,
            equals(requestIds[i]),
            reason: 'Result $i should match request $i',
          );
          expect(
            syncResults[i].reducerName,
            equals(expectedOrder[i]),
            reason: 'Reducer $i should be ${expectedOrder[i]}',
          );
          expect(
            syncResults[i].success,
            isTrue,
            reason: 'All mutations should succeed',
          );
        }
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  });

  group('Phase 5: Offline Create → Online Delete Swap Bug', () {
    late Directory tempDir;
    late JsonFileStorage storage;
    late SpacetimeDbConnection connection;
    late SubscriptionManager subManager;
    late TableCache<Note> noteTable;

    Future<void> cleanup() async {
      await subManager.dispose();
      await connection.disconnect();
      try {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      } catch (_) {}
    }

    test(
      'Sequential deletes after offline creates: deleted rows must stay deleted',
      () async {
        tempDir = await Directory.systemTemp.createTemp('swap_bug_test_');
        storage = JsonFileStorage(basePath: tempDir.path);

        addTearDown(cleanup);

        connection = SpacetimeDbConnection(
          host: 'localhost:3000',
          database: 'notesdb',
        );
        subManager = SubscriptionManager(connection, offlineStorage: storage);
        subManager.cache.registerDecoder<Note>('note', NoteDecoder());
        subManager.reducerRegistry.register(createNoteDef);
        subManager.reducerRegistry.register(deleteNoteDef);

        await connection.connect();
        await subManager.onInitialConnection.first.timeout(_timeout);
        subManager.subscribe(['SELECT * FROM note']);
        await subManager.onSubscribeApplied.first.timeout(_timeout);

        noteTable = subManager.cache.getTableByTypedName<Note>('note');

        print('\n=== Step 1: Go offline ===');
        final disconnectFuture = connection.onStateChanged
            .firstWhere((s) => s is! Connected)
            .timeout(_timeout);
        await connection.disconnect();
        await disconnectFuture;

        print('\n=== Step 2: Create 2 notes while offline ===');
        final testPrefix = 'SwapBug-${DateTime.now().millisecondsSinceEpoch}';
        final optimisticId3 =
            DateTime.now().millisecondsSinceEpoch % 1000000000 + 900000;
        final optimisticId4 = optimisticId3 + 1;

        final encN3 = BsatnEncoder();
        encN3.writeString('$testPrefix-Note3');
        encN3.writeString('Content 3');
        await subManager.reducers.call(
          'create_note',
          encN3.toBytes(),
          optimisticChanges: [
            OptimisticChange.insert('note', {
              'id': optimisticId3,
              'title': '$testPrefix-Note3',
              'content': 'Content 3',
              'timestamp': DateTime.now().microsecondsSinceEpoch,
              'status': {'type': 'draft'},
            }),
          ],
        );

        final encN4 = BsatnEncoder();
        encN4.writeString('$testPrefix-Note4');
        encN4.writeString('Content 4');
        await subManager.reducers.call(
          'create_note',
          encN4.toBytes(),
          optimisticChanges: [
            OptimisticChange.insert('note', {
              'id': optimisticId4,
              'title': '$testPrefix-Note4',
              'content': 'Content 4',
              'timestamp': DateTime.now().microsecondsSinceEpoch,
              'status': {'type': 'draft'},
            }),
          ],
        );

        expect(
          subManager.syncState.pendingCount,
          equals(2),
          reason: 'Should have 2 pending mutations',
        );

        print('\n=== Step 3: Go online and sync ===');
        final syncCompleter = Completer<void>();
        final syncResults = <MutationSyncResult>[];
        final syncSub = subManager.onMutationSyncResult.listen((result) {
          syncResults.add(result);
          if (syncResults.length == 2 && !syncCompleter.isCompleted) {
            syncCompleter.complete();
          }
        });

        await connection.connect();
        await subManager.onInitialConnection.first.timeout(_timeout);
        subManager.subscribe(['SELECT * FROM note']);
        await subManager.onSubscribeApplied.first.timeout(_timeout);

        await syncCompleter.future.timeout(_timeout);
        await syncSub.cancel();

        expect(
          syncResults.length,
          equals(2),
          reason: 'Both creates should sync',
        );
        for (final result in syncResults) {
          expect(result.success, isTrue, reason: 'Create should succeed');
        }

        final note3 = noteTable.iter().firstWhere(
          (n) => n.title == '$testPrefix-Note3',
        );
        final note4 = noteTable.iter().firstWhere(
          (n) => n.title == '$testPrefix-Note4',
        );
        final realId3 = note3.id;
        final realId4 = note4.id;

        print('  Note 3: optimisticId=$optimisticId3, realId=$realId3');
        print('  Note 4: optimisticId=$optimisticId4, realId=$realId4');

        print('\n=== Step 4: Delete note 3 online ===');
        final delete3Completer = Completer<MutationSyncResult>();
        final delete3Sub = subManager.onMutationSyncResult.listen((result) {
          if (result.reducerName == 'delete_note' &&
              !delete3Completer.isCompleted) {
            delete3Completer.complete(result);
          }
        });

        final encDel3 = BsatnEncoder();
        encDel3.writeU32(realId3);
        final result3 = await subManager.reducers.call(
          'delete_note',
          encDel3.toBytes(),
          optimisticChanges: [OptimisticChange.delete('note', note3.toJson())],
        );

        expect(
          result3.isPending,
          isTrue,
          reason: 'Offline-first returns pending immediately',
        );
        expect(
          noteTable.getRow(realId3),
          isNull,
          reason: 'Note 3 should be optimistically deleted',
        );
        expect(
          noteTable.getRow(realId4),
          isNotNull,
          reason: 'Note 4 should still exist',
        );

        final syncResult3 = await delete3Completer.future.timeout(_timeout);
        await delete3Sub.cancel();
        expect(syncResult3.success, isTrue, reason: 'Delete 3 should succeed');

        await Future.delayed(const Duration(milliseconds: 50));

        print('  After delete 3 confirmed:');
        print(
          '    Note 3 (id=$realId3) exists: ${noteTable.getRow(realId3) != null}',
        );
        print(
          '    Note 4 (id=$realId4) exists: ${noteTable.getRow(realId4) != null}',
        );

        expect(
          noteTable.getRow(realId3),
          isNull,
          reason: 'Note 3 should stay deleted after confirmation',
        );
        expect(
          noteTable.getRow(realId4),
          isNotNull,
          reason: 'Note 4 should still exist after delete 3',
        );

        print(
          '\n=== Step 5: Delete note 4 online (BUG CHECK: note 3 should NOT come back) ===',
        );
        final freshNote4 = noteTable.getRow(realId4)!;

        final delete4Completer = Completer<MutationSyncResult>();
        final delete4Sub = subManager.onMutationSyncResult.listen((result) {
          if (result.reducerName == 'delete_note' &&
              !delete4Completer.isCompleted) {
            delete4Completer.complete(result);
          }
        });

        final encDel4 = BsatnEncoder();
        encDel4.writeU32(realId4);
        final result4 = await subManager.reducers.call(
          'delete_note',
          encDel4.toBytes(),
          optimisticChanges: [
            OptimisticChange.delete('note', freshNote4.toJson()),
          ],
        );

        expect(
          result4.isPending,
          isTrue,
          reason: 'Offline-first returns pending immediately',
        );
        expect(
          noteTable.getRow(realId4),
          isNull,
          reason: 'Note 4 should be optimistically deleted',
        );

        final syncResult4 = await delete4Completer.future.timeout(_timeout);
        await delete4Sub.cancel();
        expect(syncResult4.success, isTrue, reason: 'Delete 4 should succeed');

        await Future.delayed(const Duration(milliseconds: 50));

        print('  After delete 4 confirmed:');
        print(
          '    Note 3 (id=$realId3) exists: ${noteTable.getRow(realId3) != null}',
        );
        print(
          '    Note 4 (id=$realId4) exists: ${noteTable.getRow(realId4) != null}',
        );

        expect(
          noteTable.getRow(realId3),
          isNull,
          reason:
              'CRITICAL BUG: Note 3 must NOT come back when note 4 is deleted!',
        );
        expect(
          noteTable.getRow(realId4),
          isNull,
          reason: 'Note 4 should stay deleted',
        );

        final remainingWithPrefix =
            noteTable
                .iter()
                .where((n) => n.title.startsWith(testPrefix))
                .toList();
        expect(
          remainingWithPrefix,
          isEmpty,
          reason: 'No notes with test prefix should remain',
        );
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );
  });

  group('Connection Lifecycle & State Recovery', () {
    late Directory tempDir;
    late JsonFileStorage storage;
    late SpacetimeDbConnection connection;
    late SubscriptionManager subManager;

    Future<void> setup() async {
      tempDir = await Directory.systemTemp.createTemp('regression_test_');
      storage = JsonFileStorage(basePath: tempDir.path);
      await storage.initialize();

      connection = SpacetimeDbConnection(
        host: 'localhost:3000',
        database: 'notesdb',
      );
      subManager = SubscriptionManager(connection, offlineStorage: storage);

      subManager.cache.registerDecoder<Note>('note', NoteDecoder());
      subManager.cache.registerDecoder<Folder>('folder', FolderDecoder());
      subManager.reducerRegistry.register(createNoteDef);
    }

    Future<void> cleanup() async {
      await subManager.dispose();
      await connection.disconnect();
      try {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      } catch (_) {}
    }

    test(
      'Offline creation works before first server connection',
      () async {
        await setup();
        addTearDown(cleanup);

        final tableBeforeLoad = subManager.cache.getTableByName('note');
        expect(
          tableBeforeLoad,
          isNotNull,
          reason: 'Table should exist immediately after registerDecoder',
        );
        expect(
          (tableBeforeLoad! as TableCache<Note>).count(),
          equals(0),
          reason: 'Table should start empty before any data arrives',
        );

        await subManager.loadFromOfflineCache();

        final noteId = DateTime.now().microsecondsSinceEpoch;
        final encNew = BsatnEncoder();
        encNew.writeString('New User Note');
        await subManager.reducers.call(
          'create_note',
          encNew.toBytes(),
          optimisticChanges: [
            OptimisticChange.insert('note', {
              'id': noteId,
              'title': 'New User Note',
              'content': 'Content',
              'timestamp': DateTime.now().microsecondsSinceEpoch,
              'status': {'type': 'draft'},
            }),
          ],
        );

        final noteTable = subManager.cache.getTableByTypedName<Note>('note');
        expect(
          noteTable.getRow(noteId),
          isNotNull,
          reason: 'Optimistic row should be visible',
        );
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
      'Deduplication: Duplicate subscriptions are ignored',
      () async {
        await setup();
        addTearDown(cleanup);

        await connection.connect();
        await subManager.onInitialConnection.first.timeout(_timeout);

        await subManager.subscribe([
          'SELECT * FROM note',
          'SELECT * FROM note',
          'SELECT * FROM folder',
        ]);

        expect(
          subManager.activeSubscriptionQueries.length,
          equals(2),
          reason: 'Duplicate queries should be deduplicated',
        );
        expect(
          subManager.activeSubscriptionQueries,
          containsAll(['SELECT * FROM note', 'SELECT * FROM folder']),
        );
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  });
}

Uint8List _encodeCreateNoteArgs(String title, String content) {
  final encoder = BsatnEncoder();
  encoder.writeString(title);
  encoder.writeString(content);
  return encoder.toBytes();
}
