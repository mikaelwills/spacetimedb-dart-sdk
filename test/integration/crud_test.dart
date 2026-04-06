library;

// ignore_for_file: avoid_print
import 'dart:async';
import 'package:test/test.dart';
import '../generated/note.dart';
import '../helpers/integration_test_helper.dart';
import '../helpers/test_env.dart';

void main() {
  setUpAll(ensureTestEnvironment);
  tearDownAll(cleanupTestEnvironment);
  test(
    'CRUD operations (Create, Read, Update, Delete)',
    () async {
      final env = await createTestEnv();

      print('📡 Connecting...');
      await env.connection.connect();

      env.subManager.subscribe(['SELECT * FROM note']);
      await env.subManager.onInitialSubscription.first;

      final noteTable = env.noteTable;
      print('✅ Connected & Subscribed. Current count: ${noteTable.count()}');

      Future<T> waitFor<T>(Stream<T> stream, bool Function(T) condition) {
        return stream.firstWhere(condition).timeout(const Duration(seconds: 5));
      }

      final uniqueTitle = 'Note-${DateTime.now().millisecondsSinceEpoch}';

      final insertFuture = waitFor<Note>(
        noteTable.insertStream,
        (note) => note.title == uniqueTitle,
      );

      print('📝 Action: Create Note');
      await env.reducers.createNote(title: uniqueTitle, content: 'Content');

      final createdNote = await insertFuture;

      expect(createdNote.title, equals(uniqueTitle));
      expect(createdNote.id, isNotNull);
      print('   ✅ Verified Insert via Stream: ID ${createdNote.id}');

      final updateFuture = waitFor(
        noteTable.updateStream,
        (change) => change.newRow.id == createdNote.id,
      );

      print('🔄 Action: Update Note');
      await env.reducers.updateNote(
        noteId: createdNote.id,
        title: 'UPDATED $uniqueTitle',
        content: 'New Content',
      );

      final change = await updateFuture;

      expect(change.oldRow.title, equals(uniqueTitle));
      expect(change.newRow.title, contains('UPDATED'));

      final cachedNote = noteTable.find(createdNote.id);
      expect(cachedNote?.title, contains('UPDATED'));
      print('   ✅ Verified Update via Stream');

      final deleteFuture = waitFor(
        noteTable.deleteStream,
        (note) => note.id == createdNote.id,
      );

      print('🗑️  Action: Delete Note');
      await env.reducers.deleteNote(noteId: createdNote.id);

      final deletedNote = await deleteFuture;
      expect(deletedNote.id, equals(createdNote.id));

      expect(noteTable.find(createdNote.id), isNull);
      print('   ✅ Verified Delete via Stream');

      env.subManager.dispose();
      await env.disconnect();
    },
    timeout: const Timeout(Duration(seconds: 10)),
  );
}
