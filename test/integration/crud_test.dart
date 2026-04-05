library;

// ignore_for_file: avoid_print
import 'dart:async';
import 'package:test/test.dart';
import 'package:spacetimedb_dart_sdk/src/connection/spacetimedb_connection.dart';
import 'package:spacetimedb_dart_sdk/src/subscription/subscription_manager.dart';
import '../generated/note.dart';
import '../generated/reducer_args.dart';
import '../helpers/integration_test_helper.dart';

void main() {
  setUpAll(ensureTestEnvironment);
  tearDownAll(cleanupTestEnvironment);
  // Increase timeout for integration tests involving network
  test(
    'CRUD operations (Create, Read, Update, Delete)',
    () async {
      final connection = SpacetimeDbConnection(
        host: 'localhost:3000',
        database: 'notesdb',
      );

      final subManager = SubscriptionManager(connection);

      // 1. Register Table Decoder
      subManager.cache.registerDecoder<Note>('note', NoteDecoder());

      // 2. Register Reducer Argument Decoders
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

      print('📡 Connecting...');
      await connection.connect();

      // 2. Subscribe and Wait for the "Synced" state
      subManager.subscribe(['SELECT * FROM note']);
      await subManager.onInitialSubscription.first;

      final noteTable = subManager.cache.getTableByTypedName<Note>('note');
      print('✅ Connected & Subscribed. Current count: ${noteTable.count()}');

      // Helper to wait for a specific update on the stream
      Future<T> waitFor<T>(Stream<T> stream, bool Function(T) condition) {
        return stream.firstWhere(condition).timeout(const Duration(seconds: 5));
      }

      // =========================================================================
      // TEST 1: CREATE
      // =========================================================================
      final uniqueTitle = 'Note-${DateTime.now().millisecondsSinceEpoch}';

      // Start listening BEFORE calling the reducer to ensure we don't miss the event
      final insertFuture = waitFor<Note>(
        noteTable.insertStream,
        (note) => note.title == uniqueTitle,
      );

      print('📝 Action: Create Note');
      await subManager.reducers.callWith('create_note', (encoder) {
        encoder.writeString(uniqueTitle);
        encoder.writeString('Content');
      });

      // Wait for the SERVER to tell us it happened
      final createdNote = await insertFuture;

      expect(createdNote.title, equals(uniqueTitle));
      expect(createdNote.id, isNotNull);
      print('   ✅ Verified Insert via Stream: ID ${createdNote.id}');

      // =========================================================================
      // TEST 2: UPDATE
      // =========================================================================
      final updateFuture = waitFor(
        noteTable.updateStream,
        (change) => change.newRow.id == createdNote.id,
      );

      print('🔄 Action: Update Note');
      await subManager.reducers.callWith('update_note', (encoder) {
        encoder.writeU32(createdNote.id);
        encoder.writeString('UPDATED $uniqueTitle');
        encoder.writeString('New Content');
      });

      final change = await updateFuture;

      expect(change.oldRow.title, equals(uniqueTitle));
      expect(change.newRow.title, contains('UPDATED'));

      // Verify Cache State matches
      final cachedNote = noteTable.find(createdNote.id);
      expect(cachedNote?.title, contains('UPDATED'));
      print('   ✅ Verified Update via Stream');

      // =========================================================================
      // TEST 3: DELETE
      // =========================================================================
      final deleteFuture = waitFor(
        noteTable.deleteStream,
        (note) => note.id == createdNote.id,
      );

      print('🗑️  Action: Delete Note');
      await subManager.reducers.callWith('delete_note', (encoder) {
        encoder.writeU32(createdNote.id);
      });

      final deletedNote = await deleteFuture;
      expect(deletedNote.id, equals(createdNote.id));

      // Verify Cache State is clean
      expect(noteTable.find(createdNote.id), isNull);
      print('   ✅ Verified Delete via Stream');

      // Cleanup
      subManager.dispose();
      await connection.disconnect();
    },
    timeout: const Timeout(Duration(seconds: 10)),
  ); // Test fails if > 10s
}
