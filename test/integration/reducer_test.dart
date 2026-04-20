import 'package:test/test.dart';
import 'package:spacetimedb_sdk/codegen.dart';
import '../generated/note.dart';
import '../helpers/integration_test_helper.dart';
import '../helpers/test_env.dart';
import '../helpers/value_notifier_helpers.dart';

void main() {
  setUpAll(ensureTestEnvironment);
  tearDownAll(cleanupTestEnvironment);
  late TestEnv env;
  late TableCache<Note> noteTable;

  setUp(() async {
    env = await createTestEnv();

    await env.connection.connect();
    await env.subManager.onInitialConnection.first.timeout(
      const Duration(seconds: 5),
    );

    await env.subManager.subscribe(['SELECT * FROM note']);
    noteTable = env.noteTable;
  });

  tearDown(() async {
    env.subManager.dispose();
    await env.disconnect();
  });

  group('Reducer Tests (v2 caller-awaited)', () {
    test('create_note reducer creates a new note', () async {
      final noteCountBefore = noteTable.count();

      final result = await env.reducers
          .createNote(
            title: 'Dart SDK Test',
            content: 'Created via Dart SDK reducer call!',
          )
          .timeout(const Duration(seconds: 5));

      expect(result.status, isA<Committed>());
      expect(result.reducerName, equals('create_note'));

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
      await env.reducers
          .createNote(title: 'Original Title', content: 'Original Content')
          .timeout(const Duration(seconds: 5));

      int? noteId;
      for (final note in noteTable.iter()) {
        if (note.title == 'Original Title') {
          noteId = note.id;
          break;
        }
      }
      expect(noteId, isNotNull);

      final result = await env.reducers
          .updateNote(
            noteId: noteId!,
            title: 'Updated Title',
            content: 'Updated Content',
          )
          .timeout(const Duration(seconds: 5));

      expect(result.status, isA<Committed>());
      expect(result.reducerName, equals('update_note'));

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
      await env.reducers
          .createNote(title: 'To Delete', content: 'This will be deleted')
          .timeout(const Duration(seconds: 5));

      int? noteId;
      for (final note in noteTable.iter()) {
        if (note.title == 'To Delete') {
          noteId = note.id;
          break;
        }
      }
      expect(noteId, isNotNull);

      final noteCountBefore = noteTable.count();

      final result = await env.reducers
          .deleteNote(noteId: noteId!)
          .timeout(const Duration(seconds: 5));

      expect(result.status, isA<Committed>());
      expect(result.reducerName, equals('delete_note'));

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

    test('Table insert notifies on new notes', () async {
      final insertFuture = waitForInsert(
        noteTable,
        (note) => note.title == 'Stream Test',
        timeout: const Duration(seconds: 2),
      );

      await env.reducers.createNote(
        title: 'Stream Test',
        content: 'Testing insert notification',
      );

      final insertedNote = await insertFuture;

      expect(insertedNote.title, equals('Stream Test'));
      expect(insertedNote.content, equals('Testing insert notification'));
    });

    test('Table update notifies on updated notes', () async {
      final uniqueTitle =
          'Update Stream Test ${DateTime.now().microsecondsSinceEpoch}';

      final insertFuture = waitForInsert(
        noteTable,
        (note) => note.title == uniqueTitle,
        timeout: const Duration(seconds: 2),
      );

      env.reducers.createNote(title: uniqueTitle, content: 'Original Content');

      final createdNote = await insertFuture;
      final correctId = createdNote.id;

      final updateFuture = waitForUpdate(
        noteTable,
        (_, newRow) => newRow.id == correctId,
        timeout: const Duration(seconds: 2),
      );

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

    test('Table delete notifies on deleted notes', () async {
      await env.reducers.createNote(
        title: 'Delete Stream Test',
        content: 'Will be deleted',
      );

      int? noteId;
      for (final note in noteTable.iter()) {
        if (note.title == 'Delete Stream Test') {
          noteId = note.id;
          break;
        }
      }
      expect(noteId, isNotNull);

      final deleteFuture = waitForDelete(
        noteTable,
        (note) => note.id == noteId,
        timeout: const Duration(seconds: 2),
      );

      await env.reducers.deleteNote(noteId: noteId!);

      final deletedNote = await deleteFuture;

      expect(deletedNote.id, equals(noteId));
      expect(deletedNote.title, equals('Delete Stream Test'));
    });
  });
}
