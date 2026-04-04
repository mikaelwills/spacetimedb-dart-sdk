import 'dart:async';
import 'package:test/test.dart';
import 'package:spacetimedb_dart_sdk/spacetimedb_dart_sdk.dart';
import '../generated/note.dart';
import '../generated/reducer_args.dart';
import '../helpers/integration_test_helper.dart';

/// Test calling reducers to create and update notes

void main() {
  setUpAll(ensureTestEnvironment);
  late SpacetimeDbConnection connection;
  late SubscriptionManager subManager;
  late TableCache<Note> noteTable;

  setUp(() async {
    connection = SpacetimeDbConnection(
      host: 'localhost:3000',
      database: 'notesdb',
    );
    subManager = SubscriptionManager(connection);

    // PHASE 0: Register decoders
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
    await subManager.onIdentityToken.first.timeout(const Duration(seconds: 5));

    // Subscribe to notes table
    subManager.subscribe(['SELECT * FROM note']);
    await subManager.onInitialSubscription.first;

    noteTable = subManager.cache.getTableByTypedName<Note>('note');
  });

  tearDown(() async {
    subManager.dispose();
    await connection.disconnect();
  });

  group('Reducer Tests', () {
    test('create_note reducer creates a new note', () async {
      final noteCountBefore = noteTable.count();

      // A. PREPARE LISTENER - filter for the specific reducer we're calling
      final txUpdateFuture =
          subManager.onTransactionUpdate
              .where((tx) => tx.reducerCall.reducerName == 'create_note')
              .first;

      // B. ACTION
      await subManager.reducers.callWith('create_note', (encoder) {
        encoder.writeString('Dart SDK Test');
        encoder.writeString('Created via Dart SDK reducer call!');
      });

      // C. WAIT
      final txUpdate = await txUpdateFuture.timeout(const Duration(seconds: 2));

      // D. ASSERT
      expect(
        txUpdate.status,
        isA<Committed>(),
        reason: 'Transaction should be committed',
      );
      expect(
        txUpdate.reducerCall.reducerName,
        equals('create_note'),
        reason: 'Reducer name should match',
      );

      final noteCountAfter = noteTable.count();
      expect(
        noteCountAfter,
        equals(noteCountBefore + 1),
        reason: 'Note count should increase by 1',
      );

      // Verify the note was created with correct data
      bool foundNote = false;
      for (final note in noteTable.iter()) {
        if (note.title == 'Dart SDK Test' &&
            note.content == 'Created via Dart SDK reducer call!') {
          foundNote = true;
          break;
        }
      }
      expect(
        foundNote,
        isTrue,
        reason: 'Should find the created note in the table',
      );
    });

    test('update_note reducer updates an existing note', () async {
      // First, create a note to update
      final createTxFuture =
          subManager.onTransactionUpdate
              .where((tx) => tx.reducerCall.reducerName == 'create_note')
              .first;
      await subManager.reducers.callWith('create_note', (encoder) {
        encoder.writeString('Original Title');
        encoder.writeString('Original Content');
      });
      await createTxFuture.timeout(const Duration(seconds: 2));

      // Find the note ID
      int? noteId;
      for (final note in noteTable.iter()) {
        if (note.title == 'Original Title') {
          noteId = note.id;
          break;
        }
      }
      expect(noteId, isNotNull, reason: 'Should have created a note');

      // A. PREPARE LISTENER - filter for update_note
      final txUpdateFuture =
          subManager.onTransactionUpdate
              .where((tx) => tx.reducerCall.reducerName == 'update_note')
              .first;

      // B. ACTION - update the note
      await subManager.reducers.callWith('update_note', (encoder) {
        encoder.writeU32(noteId!);
        encoder.writeString('Updated Title');
        encoder.writeString('Updated Content');
      });

      // C. WAIT
      final txUpdate = await txUpdateFuture.timeout(const Duration(seconds: 2));

      // D. ASSERT
      expect(
        txUpdate.status,
        isA<Committed>(),
        reason: 'Transaction should be committed',
      );
      expect(
        txUpdate.reducerCall.reducerName,
        equals('update_note'),
        reason: 'Reducer name should match',
      );

      // Verify the note was updated
      bool foundUpdated = false;
      for (final note in noteTable.iter()) {
        if (note.id == noteId &&
            note.title == 'Updated Title' &&
            note.content == 'Updated Content') {
          foundUpdated = true;
          break;
        }
      }
      expect(
        foundUpdated,
        isTrue,
        reason: 'Should find the updated note with new values',
      );
    });

    test('delete_note reducer deletes a note', () async {
      // First, create a note to delete
      final createTxFuture =
          subManager.onTransactionUpdate
              .where((tx) => tx.reducerCall.reducerName == 'create_note')
              .first;
      await subManager.reducers.callWith('create_note', (encoder) {
        encoder.writeString('To Delete');
        encoder.writeString('This will be deleted');
      });
      await createTxFuture.timeout(const Duration(seconds: 2));

      // Find the note ID
      int? noteId;
      for (final note in noteTable.iter()) {
        if (note.title == 'To Delete') {
          noteId = note.id;
          break;
        }
      }
      expect(noteId, isNotNull, reason: 'Should have created a note');

      final noteCountBefore = noteTable.count();

      // A. PREPARE LISTENER - filter for delete_note
      final txUpdateFuture =
          subManager.onTransactionUpdate
              .where((tx) => tx.reducerCall.reducerName == 'delete_note')
              .first;

      // B. ACTION - delete the note
      await subManager.reducers.callWith('delete_note', (encoder) {
        encoder.writeU32(noteId!);
      });

      // C. WAIT
      final txUpdate = await txUpdateFuture.timeout(const Duration(seconds: 2));

      // D. ASSERT
      expect(
        txUpdate.status,
        isA<Committed>(),
        reason: 'Transaction should be committed',
      );
      expect(
        txUpdate.reducerCall.reducerName,
        equals('delete_note'),
        reason: 'Reducer name should match',
      );

      final noteCountAfter = noteTable.count();
      expect(
        noteCountAfter,
        equals(noteCountBefore - 1),
        reason: 'Note count should decrease by 1',
      );

      // Verify the note was deleted
      bool foundDeleted = false;
      for (final note in noteTable.iter()) {
        if (note.id == noteId) {
          foundDeleted = true;
          break;
        }
      }
      expect(foundDeleted, isFalse, reason: 'Should not find the deleted note');
    });

    test('Table insert stream emits new notes', () async {
      // A. PREPARE LISTENER - listen for insert events
      final insertCompleter = Completer<Note>();
      final subscription = noteTable.insertStream.listen((note) {
        if (note.title == 'Stream Test' && !insertCompleter.isCompleted) {
          insertCompleter.complete(note);
        }
      });

      // B. ACTION
      await subManager.reducers.callWith('create_note', (encoder) {
        encoder.writeString('Stream Test');
        encoder.writeString('Testing insert stream');
      });

      // C. WAIT
      final insertedNote = await insertCompleter.future.timeout(
        const Duration(seconds: 2),
      );

      // D. ASSERT
      expect(
        insertedNote.title,
        equals('Stream Test'),
        reason: 'Insert stream should emit the new note',
      );
      expect(
        insertedNote.content,
        equals('Testing insert stream'),
        reason: 'Note content should match',
      );

      // Clean up
      await subscription.cancel();
    });

    test('Table update stream emits updated notes', () async {
      // Use unique title to avoid conflicts with other tests
      final uniqueTitle =
          'Update Stream Test ${DateTime.now().microsecondsSinceEpoch}';

      // 1. Setup trap for INSERT (to capture the ID securely)
      final insertFuture = noteTable.insertStream
          .firstWhere((note) => note.title == uniqueTitle)
          .timeout(const Duration(seconds: 2));

      // 2. Create note
      subManager.reducers.callWith('create_note', (encoder) {
        encoder.writeString(uniqueTitle);
        encoder.writeString('Original Content');
      });

      // 3. Wait for the ID to be confirmed by the server/cache
      final createdNote = await insertFuture;
      final correctId = createdNote.id; // ✅ We are now 100% sure this ID exists

      // 4. Setup trap for UPDATE
      final updateFuture = noteTable.updateStream
          .firstWhere((e) => e.newRow.id == correctId)
          .timeout(const Duration(seconds: 2));

      // 5. Update using the CONFIRMED ID
      subManager.reducers.callWith('update_note', (encoder) {
        encoder.writeU32(correctId);
        encoder.writeString('Updated Title');
        encoder.writeString('Updated Content');
      });

      // 6. Wait and assert
      final updateEvent = await updateFuture;

      expect(
        updateEvent.oldRow.title,
        equals(uniqueTitle),
        reason: 'Old row should have original title',
      );
      expect(
        updateEvent.oldRow.content,
        equals('Original Content'),
        reason: 'Old row should have original content',
      );
      expect(
        updateEvent.newRow.title,
        equals('Updated Title'),
        reason: 'New row should have updated title',
      );
      expect(
        updateEvent.newRow.content,
        equals('Updated Content'),
        reason: 'New row should have updated content',
      );
    });

    test('Table delete stream emits deleted notes', () async {
      // First, create a note
      final createTxFuture =
          subManager.onTransactionUpdate
              .where((tx) => tx.reducerCall.reducerName == 'create_note')
              .first;
      await subManager.reducers.callWith('create_note', (encoder) {
        encoder.writeString('Delete Stream Test');
        encoder.writeString('Will be deleted');
      });
      await createTxFuture.timeout(const Duration(seconds: 2));

      // Find the note ID
      int? noteId;
      for (final note in noteTable.iter()) {
        if (note.title == 'Delete Stream Test') {
          noteId = note.id;
          break;
        }
      }
      expect(noteId, isNotNull);

      // A. PREPARE LISTENER - listen for delete events
      final deleteCompleter = Completer<Note>();
      final subscription = noteTable.deleteStream.listen((note) {
        if (note.id == noteId && !deleteCompleter.isCompleted) {
          deleteCompleter.complete(note);
        }
      });

      // B. ACTION
      await subManager.reducers.callWith('delete_note', (encoder) {
        encoder.writeU32(noteId!);
      });

      // C. WAIT
      final deletedNote = await deleteCompleter.future.timeout(
        const Duration(seconds: 2),
      );

      // D. ASSERT
      expect(
        deletedNote.id,
        equals(noteId),
        reason: 'Delete stream should emit the deleted note',
      );
      expect(
        deletedNote.title,
        equals('Delete Stream Test'),
        reason: 'Deleted note should have correct title',
      );

      // Clean up
      await subscription.cancel();
    });
  });
}
