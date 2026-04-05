import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:spacetimedb_dart_sdk/spacetimedb_dart_sdk.dart';

import '../generated/note.dart';
import '../generated/note_status.dart';
import '../mocks/mock_connection.dart';

void main() {
  group('Integration Tests - Real Components', () {
    late Directory tempDir;
    late JsonFileStorage storage;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('integration_test_');
      storage = JsonFileStorage(basePath: tempDir.path);
      await storage.initialize();
    });

    tearDown(() async {
      await storage.dispose();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    Note createNote(int id, String title) => Note(
      id: id,
      title: title,
      content: 'Test content',
      timestamp: Int64(DateTime.now().millisecondsSinceEpoch),
      status: const NoteStatusDraft(),
    );

    group('Persistence - Real File System', () {
      test('Table snapshot persists to real JSON file', () async {
        final note = createNote(1, 'Persisted Note');

        await storage.saveTableSnapshot('note', [note.toJson()]);

        final file = File('${tempDir.path}/table_note.json');
        expect(await file.exists(), isTrue, reason: 'Snapshot file must exist');

        final content = await file.readAsString();
        expect(content.contains('"id":1'), isTrue);
        expect(content.contains('Persisted Note'), isTrue);
      });

      test('Mutation queue persists to real file', () async {
        final encoder = BsatnEncoder();
        encoder.writeU32(1);
        encoder.writeString('Test');

        final mutation = PendingMutation(
          requestId: 'test-req-1',
          reducerName: 'create_note',
          encodedArgs: encoder.toBytes(),
          createdAt: DateTime.now(),
        );

        await storage.enqueueMutation(mutation);

        final file = File('${tempDir.path}/pending_mutations.json');
        expect(
          await file.exists(),
          isTrue,
          reason: 'Mutations file must exist',
        );

        final content = await file.readAsString();
        expect(content.contains('test-req-1'), isTrue);
        expect(content.contains('create_note'), isTrue);
      });

      test('Data survives storage restart', () async {
        final note = createNote(42, 'Survivor');
        await storage.saveTableSnapshot('note', [note.toJson()]);

        await storage.dispose();

        final storage2 = JsonFileStorage(basePath: tempDir.path);
        await storage2.initialize();

        final loaded = await storage2.loadTableSnapshot('note');
        expect(loaded, isNotNull);
        expect(loaded!.length, equals(1));
        expect(loaded[0]['id'], equals(42));
        expect(loaded[0]['title'], equals('Survivor'));

        await storage2.dispose();
      });
    });

    group('Network Error - Real Sabotage', () {
      test('Connection to dead port preserves mutation queue', () async {
        final encoder = BsatnEncoder();
        encoder.writeU32(1);
        encoder.writeString('Offline Note');

        final mutation = PendingMutation(
          requestId: 'offline-req-1',
          reducerName: 'create_note',
          encodedArgs: encoder.toBytes(),
          createdAt: DateTime.now(),
        );
        await storage.enqueueMutation(mutation);

        var pending = await storage.getPendingMutations();
        expect(pending.length, equals(1), reason: 'Setup: mutation queued');

        final deadConnection = SpacetimeDbConnection(
          host: 'localhost:9999',
          database: 'notesdb',
        );
        final manager = SubscriptionManager(
          deadConnection,
          offlineStorage: storage,
        );
        manager.cache.registerDecoder<Note>('note', NoteDecoder());

        await manager.syncPendingMutations();

        pending = await storage.getPendingMutations();
        expect(
          pending.length,
          equals(1),
          reason: 'Network error must PAUSE queue, not discard',
        );

        await manager.dispose();
        await deadConnection.dispose();
      });
    });

    group('Cache State Transitions', () {
      test('Offline cache load populates table correctly', () async {
        final notes = [
          createNote(1, 'Note One'),
          createNote(2, 'Note Two'),
          createNote(3, 'Note Three'),
        ];

        await storage.saveTableSnapshot(
          'note',
          notes.map((n) => n.toJson()).toList(),
        );

        final deadConnection = SpacetimeDbConnection(
          host: 'localhost:9999',
          database: 'notesdb',
        );
        final manager = SubscriptionManager(
          deadConnection,
          offlineStorage: storage,
        );
        manager.cache.registerDecoder<Note>('note', NoteDecoder());

        await manager.loadFromOfflineCache();

        final table = manager.cache.getTableByName('note')! as TableCache<Note>;
        expect(table.count(), equals(3));
        expect(table.find(1)?.title, equals('Note One'));
        expect(table.find(2)?.title, equals('Note Two'));
        expect(table.find(3)?.title, equals('Note Three'));

        await manager.dispose();
        await deadConnection.dispose();
      });

      test('Optimistic changes survive cache reload', () async {
        final existingNote = createNote(1, 'Existing');
        await storage.saveTableSnapshot('note', [existingNote.toJson()]);

        final optimisticNote = createNote(99, 'Optimistic');
        final mutation = PendingMutation(
          requestId: 'opt-req-1',
          reducerName: 'create_note',
          encodedArgs: Uint8List(0),
          createdAt: DateTime.now(),
          optimisticChanges: [
            OptimisticChange.insert('note', optimisticNote.toJson()),
          ],
        );
        await storage.enqueueMutation(mutation);

        final deadConnection = SpacetimeDbConnection(
          host: 'localhost:9999',
          database: 'notesdb',
        );
        final manager = SubscriptionManager(
          deadConnection,
          offlineStorage: storage,
        );
        manager.cache.registerDecoder<Note>('note', NoteDecoder());

        await manager.loadFromOfflineCache();

        final table = manager.cache.getTableByName('note')! as TableCache<Note>;
        expect(table.find(1), isNotNull, reason: 'Existing note loaded');
        expect(
          table.find(99),
          isNotNull,
          reason: 'Optimistic insert must be applied from pending mutation',
        );
        expect(table.find(99)?.title, equals('Optimistic'));

        await manager.dispose();
        await deadConnection.dispose();
      });
    });

    group('Stream Events - Real Listeners', () {
      test('Optimistic changes emit to streams', () async {
        final deadConnection = SpacetimeDbConnection(
          host: 'localhost:9999',
          database: 'notesdb',
        );
        final manager = SubscriptionManager(
          deadConnection,
          offlineStorage: storage,
        );
        manager.cache.registerDecoder<Note>('note', NoteDecoder());

        final table = manager.cache.getTableByName('note')! as TableCache<Note>;
        final optimistic = OptimisticStateManager(manager.cache);

        final insertEvents = <Note>[];
        final deleteEvents = <Note>[];
        final sub1 = table.insertStream.listen(insertEvents.add);
        final sub2 = table.deleteStream.listen(deleteEvents.add);

        final note = createNote(1, 'Stream Test');
        optimistic.applyOptimisticChanges('req-1', [
          OptimisticChange.insert('note', note.toJson()),
        ]);

        await Future.delayed(const Duration(milliseconds: 10));
        expect(insertEvents.length, equals(1));
        expect(insertEvents.first.title, equals('Stream Test'));

        optimistic.applyOptimisticChanges('req-2', [
          OptimisticChange.delete('note', note.toJson()),
        ]);

        await Future.delayed(const Duration(milliseconds: 10));
        expect(deleteEvents.length, equals(1));

        await sub1.cancel();
        await sub2.cancel();
        await manager.dispose();
        await deadConnection.dispose();
      });
    });

    group('Sync Error Handling - Full Integration', () {
      test('Full Loop: Server Logic Rejection triggers Rollback', () async {
        final failingConnection = FailingMockConnection();
        final manager = SubscriptionManager(
          failingConnection,
          offlineStorage: storage,
        );
        manager.cache.registerDecoder<Note>('note', NoteDecoder());

        const noteId = 999;
        final note = createNote(noteId, 'Bad Note');
        final mutation = PendingMutation(
          requestId: 'fail-req-1',
          reducerName: 'create_note',
          encodedArgs: Uint8List(0),
          createdAt: DateTime.now(),
          optimisticChanges: [OptimisticChange.insert('note', note.toJson())],
        );

        await storage.enqueueMutation(mutation);
        await manager.loadFromOfflineCache();

        await failingConnection.connect();
        failingConnection.setStatusSilently(ConnectionStatus.connected);

        final table = manager.cache.getTableByName('note')! as TableCache<Note>;

        expect(
          table.find(noteId),
          isNotNull,
          reason: 'Optimistic row should exist before sync',
        );

        await manager.syncPendingMutations();

        expect(
          table.find(noteId),
          isNull,
          reason:
              'CRITICAL: SubscriptionManager must automate the rollback on failure',
        );

        final pending = await storage.getPendingMutations();
        expect(
          pending.isEmpty,
          isTrue,
          reason: 'Logic error should discard mutation from disk',
        );

        await manager.dispose();
        await failingConnection.dispose();
      });

      test(
        'Offline-first: Optimistic changes survive network issues',
        () async {
          final silentConnection = SilentMockConnection();
          final manager = SubscriptionManager(
            silentConnection,
            offlineStorage: storage,
          );
          manager.cache.registerDecoder<Note>('note', NoteDecoder());

          await silentConnection.connect();
          silentConnection.setStatusSilently(ConnectionStatus.connected);

          const noteId = 888;
          final note = createNote(noteId, 'Timeout Note');
          final table =
              manager.cache.getTableByName('note')! as TableCache<Note>;

          final result = await manager.reducers.callWith(
            'create_note',
            (enc) => enc.writeU32(noteId),
            optimisticChanges: [OptimisticChange.insert('note', note.toJson())],
          );

          expect(
            result.isPending,
            isTrue,
            reason: 'Offline-first always returns pending immediately',
          );

          expect(
            table.find(noteId),
            isNotNull,
            reason: 'Optimistic insert should be applied immediately',
          );

          await Future.delayed(const Duration(milliseconds: 100));

          expect(
            table.find(noteId),
            isNotNull,
            reason: 'CRITICAL: Optimistic changes must survive network delays',
          );

          final pending = await storage.getPendingMutations();
          expect(
            pending.length,
            equals(1),
            reason: 'Mutation should be queued for later sync',
          );

          await manager.dispose();
          await silentConnection.dispose();
        },
      );
    });
  });
}

class SilentMockConnection extends MockConnection {}

class FailingMockConnection extends MockConnection {
  @override
  void send(Uint8List data) {
    super.send(data);

    final requestId = _extractRequestId(data);
    if (requestId != null) {
      Future.microtask(() {
        final failedResponse = _createFailedTransactionUpdate(
          requestId: requestId,
          errorMessage: 'Simulated Logic Error: Permission Denied',
        );
        simulateIncoming(failedResponse);
      });
    }
  }

  int? _extractRequestId(Uint8List data) {
    try {
      final decoder = BsatnDecoder(data);
      decoder.readU8();
      decoder.readString();
      final argsLen = decoder.readU32();
      decoder.readBytes(argsLen);
      return decoder.readU32();
    } catch (_) {
      return null;
    }
  }

  Uint8List _createFailedTransactionUpdate({
    required int requestId,
    required String errorMessage,
  }) {
    final encoder = BsatnEncoder();

    encoder.writeU8(0);
    encoder.writeU8(1);
    encoder.writeU8(1);
    encoder.writeString(errorMessage);
    encoder.writeU64(
      Int64(DateTime.now().microsecondsSinceEpoch) * Int64(1000),
    );
    encoder.writeBytes(Uint8List(32));
    encoder.writeBytes(Uint8List(16));
    encoder.writeString('create_note');
    encoder.writeU32(0);
    encoder.writeU32(0);
    encoder.writeU32(requestId);
    encoder.writeBytes(Uint8List(16));
    encoder.writeU64(Int64(0));

    return encoder.toBytes();
  }
}
