import 'dart:async';
import 'package:test/test.dart';
import 'package:spacetimedb_dart_sdk/spacetimedb_dart_sdk.dart';
import '../generated/note.dart';
import '../helpers/integration_test_helper.dart';
import '../helpers/test_env.dart';

void main() {
  setUpAll(ensureTestEnvironment);
  tearDownAll(cleanupTestEnvironment);
  late TestEnv env;
  late TableCache<Note> noteTable;

  setUp(() async {
    env = await createTestEnv();

    await env.connection.connect();
    await env.subManager.onIdentityToken.first.timeout(
      const Duration(seconds: 5),
    );

    env.subManager.subscribe(['SELECT * FROM note']);
    await env.subManager.onInitialSubscription.first;

    noteTable = env.noteTable;
  });

  tearDown(() async {
    env.subManager.dispose();
    await env.disconnect();
  });

  group('Reducer Tests', () {
    test('create_note reducer creates a new note', () async {
      final noteCountBefore = noteTable.count();

      final txUpdateFuture =
          env.subManager.onTransactionUpdate
              .where((tx) => tx.reducerCall.reducerName == 'create_note')
              .first;

      await env.reducers.createNote(
        title: 'Dart SDK Test',
        content: 'Created via Dart SDK reducer call!',
      );

      final txUpdate = await txUpdateFuture.timeout(const Duration(seconds: 2));

      expect(txUpdate.status, isA<Committed>());
      expect(txUpdate.reducerCall.reducerName, equals('create_note'));

      final noteCountAfter = noteTable.count();
      expect(noteCountAfter, equals(noteCountBefore + 1));

      bool foundNote = false;
      for (final note in noteTable.iter()) {
        if (note.title == 'Dart SDK Test' &&
            note.content == 'Created via Dart SDK reducer call!') {
          foundNote = true;
          break;
        }
      }
      expect(foundNote, isTrue);
    });

    test('update_note reducer updates an existing note', () async {
      final createTxFuture =
          env.subManager.onTransactionUpdate
              .where((tx) => tx.reducerCall.reducerName == 'create_note')
              .first;
      await env.reducers.createNote(
        title: 'Original Title',
        content: 'Original Content',
      );
      await createTxFuture.timeout(const Duration(seconds: 2));

      int? noteId;
      for (final note in noteTable.iter()) {
        if (note.title == 'Original Title') {
          noteId = note.id;
          break;
        }
      }
      expect(noteId, isNotNull);

      final txUpdateFuture =
          env.subManager.onTransactionUpdate
              .where((tx) => tx.reducerCall.reducerName == 'update_note')
              .first;

      await env.reducers.updateNote(
        noteId: noteId!,
        title: 'Updated Title',
        content: 'Updated Content',
      );

      final txUpdate = await txUpdateFuture.timeout(const Duration(seconds: 2));

      expect(txUpdate.status, isA<Committed>());
      expect(txUpdate.reducerCall.reducerName, equals('update_note'));

      bool foundUpdated = false;
      for (final note in noteTable.iter()) {
        if (note.id == noteId &&
            note.title == 'Updated Title' &&
            note.content == 'Updated Content') {
          foundUpdated = true;
          break;
        }
      }
      expect(foundUpdated, isTrue);
    });

    test('delete_note reducer deletes a note', () async {
      final createTxFuture =
          env.subManager.onTransactionUpdate
              .where((tx) => tx.reducerCall.reducerName == 'create_note')
              .first;
      await env.reducers.createNote(
        title: 'To Delete',
        content: 'This will be deleted',
      );
      await createTxFuture.timeout(const Duration(seconds: 2));

      int? noteId;
      for (final note in noteTable.iter()) {
        if (note.title == 'To Delete') {
          noteId = note.id;
          break;
        }
      }
      expect(noteId, isNotNull);

      final noteCountBefore = noteTable.count();

      final txUpdateFuture =
          env.subManager.onTransactionUpdate
              .where((tx) => tx.reducerCall.reducerName == 'delete_note')
              .first;

      await env.reducers.deleteNote(noteId: noteId!);

      final txUpdate = await txUpdateFuture.timeout(const Duration(seconds: 2));

      expect(txUpdate.status, isA<Committed>());
      expect(txUpdate.reducerCall.reducerName, equals('delete_note'));

      final noteCountAfter = noteTable.count();
      expect(noteCountAfter, equals(noteCountBefore - 1));

      bool foundDeleted = false;
      for (final note in noteTable.iter()) {
        if (note.id == noteId) {
          foundDeleted = true;
          break;
        }
      }
      expect(foundDeleted, isFalse);
    });

    test('Table insert stream emits new notes', () async {
      final insertCompleter = Completer<Note>();
      final subscription = noteTable.insertStream.listen((note) {
        if (note.title == 'Stream Test' && !insertCompleter.isCompleted) {
          insertCompleter.complete(note);
        }
      });

      await env.reducers.createNote(
        title: 'Stream Test',
        content: 'Testing insert stream',
      );

      final insertedNote = await insertCompleter.future.timeout(
        const Duration(seconds: 2),
      );

      expect(insertedNote.title, equals('Stream Test'));
      expect(insertedNote.content, equals('Testing insert stream'));

      await subscription.cancel();
    });

    test('Table update stream emits updated notes', () async {
      final uniqueTitle =
          'Update Stream Test ${DateTime.now().microsecondsSinceEpoch}';

      final insertFuture = noteTable.insertStream
          .firstWhere((note) => note.title == uniqueTitle)
          .timeout(const Duration(seconds: 2));

      env.reducers.createNote(title: uniqueTitle, content: 'Original Content');

      final createdNote = await insertFuture;
      final correctId = createdNote.id;

      final updateFuture = noteTable.updateStream
          .firstWhere((e) => e.newRow.id == correctId)
          .timeout(const Duration(seconds: 2));

      env.reducers.updateNote(
        noteId: correctId,
        title: 'Updated Title',
        content: 'Updated Content',
      );

      final updateEvent = await updateFuture;

      expect(updateEvent.oldRow.title, equals(uniqueTitle));
      expect(updateEvent.oldRow.content, equals('Original Content'));
      expect(updateEvent.newRow.title, equals('Updated Title'));
      expect(updateEvent.newRow.content, equals('Updated Content'));
    });

    test('Table delete stream emits deleted notes', () async {
      final createTxFuture =
          env.subManager.onTransactionUpdate
              .where((tx) => tx.reducerCall.reducerName == 'create_note')
              .first;
      await env.reducers.createNote(
        title: 'Delete Stream Test',
        content: 'Will be deleted',
      );
      await createTxFuture.timeout(const Duration(seconds: 2));

      int? noteId;
      for (final note in noteTable.iter()) {
        if (note.title == 'Delete Stream Test') {
          noteId = note.id;
          break;
        }
      }
      expect(noteId, isNotNull);

      final deleteCompleter = Completer<Note>();
      final subscription = noteTable.deleteStream.listen((note) {
        if (note.id == noteId && !deleteCompleter.isCompleted) {
          deleteCompleter.complete(note);
        }
      });

      await env.reducers.deleteNote(noteId: noteId!);

      final deletedNote = await deleteCompleter.future.timeout(
        const Duration(seconds: 2),
      );

      expect(deletedNote.id, equals(noteId));
      expect(deletedNote.title, equals('Delete Stream Test'));

      await subscription.cancel();
    });
  });
}
