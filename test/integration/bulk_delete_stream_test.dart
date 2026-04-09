library;

// ignore_for_file: avoid_print
import 'dart:async';
import 'package:test/test.dart';
import 'package:spacetimedb_dart_sdk/spacetimedb_dart_sdk.dart';
import '../generated/note.dart';
import '../helpers/integration_test_helper.dart';
import '../helpers/test_env.dart';
import '../helpers/value_notifier_helpers.dart';

void main() {
  setUpAll(ensureTestEnvironment);
  tearDownAll(cleanupTestEnvironment);

  test(
    'Multi-delete in single transaction emits multiple delete events',
    () async {
      final env = await createTestEnv();

      print('📡 Connecting...');
      await env.connection.connect();

      await env.subManager.onIdentityToken.first;

      env.subManager.subscribe(['SELECT * FROM note']);
      await env.subManager.onInitialSubscription.first;

      final noteTable = env.noteTable;
      final initialCount = noteTable.count();
      print('✅ Connected & Subscribed. Initial count: $initialCount');

      if (initialCount > 0) {
        print('🧹 Cleaning up $initialCount existing notes...');
        await env.reducers.deleteAllNotes();
        await Future.delayed(const Duration(milliseconds: 500));
        print('   ✅ Clean slate established. Count: ${noteTable.count()}');
      }

      const notesToCreate = 5;
      final createdNotes = <Note>[];

      for (var i = 0; i < notesToCreate; i++) {
        final uniqueTitle =
            'MultiDeleteTest-${DateTime.now().millisecondsSinceEpoch}-$i';

        final insertFuture = waitForNextInsert(noteTable);

        await env.reducers.createNote(
          title: uniqueTitle,
          content: 'Content $i',
        );

        final note = await insertFuture.timeout(const Duration(seconds: 5));
        createdNotes.add(note);
        print('   Created note ${note.id}: ${note.title}');
      }

      final countAfterInserts = noteTable.count();
      print('📝 Created $notesToCreate notes. Total count: $countAfterInserts');
      expect(createdNotes.length, equals(notesToCreate));

      final deletedNotes = <Note>[];
      final deleteCompleter = Completer<void>();

      final collector = EventCollector(
        noteTable,
        filter: (e) {
          if (e is TableDeleteEvent<Note>) {
            deletedNotes.add(e.row);
            print(
              '   📡 Delete event received for note ${e.row.id}: ${e.row.title}',
            );
            if (deletedNotes.length >= notesToCreate &&
                !deleteCompleter.isCompleted) {
              deleteCompleter.complete();
            }
            return true;
          }
          return false;
        },
      );

      print('🗑️  Action: Delete All Notes');
      await env.reducers.deleteAllNotes();

      await deleteCompleter.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          print(
            '⏱️  Timeout! Only received ${deletedNotes.length}/$notesToCreate delete events',
          );
        },
      );

      collector.dispose();

      print('');
      print('📊 Results:');
      print('   Notes created: $notesToCreate');
      print('   Delete events received: ${deletedNotes.length}');
      print('   Notes in cache after delete: ${noteTable.count()}');

      expect(deletedNotes.length, equals(notesToCreate));

      expect(noteTable.count(), equals(0));

      env.subManager.dispose();
      await env.disconnect();

      print(
        '✅ Test passed! All ${deletedNotes.length} delete events were received.',
      );
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
