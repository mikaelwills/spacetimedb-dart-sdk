library;

// ignore_for_file: avoid_print
import 'dart:async';
import 'package:test/test.dart';
import 'package:spacetimedb_dart_sdk/src/messages/server_messages.dart';
import 'package:spacetimedb_dart_sdk/src/subscription/subscription_manager.dart';
import '../generated/note.dart';
import '../helpers/integration_test_helper.dart';
import '../helpers/test_env.dart';
import '../helpers/value_notifier_helpers.dart';

void main() {
  setUpAll(ensureTestEnvironment);
  tearDownAll(cleanupTestEnvironment);

  Future<TestEnv> connectAndRegister() async {
    final env = await createTestEnv(registerViews: true);
    await env.connection.connect();
    await env.subManager.onIdentityToken.first;
    return env;
  }

  Future<void> subscribeOrFail(
    SubscriptionManager subManager,
    List<String> queries,
  ) async {
    final errors = <SubscriptionErrorMessage>[];
    final errorSub = subManager.onSubscriptionError.listen(errors.add);
    try {
      subManager.subscribe(queries);
      await subManager.onInitialSubscription.first.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          if (errors.isNotEmpty) {
            throw StateError(
              'Server rejected subscription(s): ${errors.map((e) => e.error).join("; ")}',
            );
          }
          throw TimeoutException(
            'Initial subscription for $queries did not arrive within 5s',
          );
        },
      );
      if (errors.isNotEmpty) {
        throw StateError(
          'Server rejected subscription(s): ${errors.map((e) => e.error).join("; ")}',
        );
      }
    } finally {
      await errorSub.cancel();
    }
  }

  Future<void> clearNotes(TestEnv env) async {
    final noteTable = env.subManager.cache.getTableByTypedName<Note>('note');
    if (noteTable.count() == 0) return;
    await env.reducers.deleteAllNotes();
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (noteTable.count() > 0) {
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException(
          'Notes table did not clear within 3s (count=${noteTable.count()})',
        );
      }
      await Future.delayed(const Duration(milliseconds: 50));
    }
  }

  Future<Note> createNote(TestEnv env, String title, String content) async {
    final noteTable = env.subManager.cache.getTableByTypedName<Note>('note');
    final insertFuture = waitForInsert(
      noteTable,
      (n) => n.title == title,
      timeout: const Duration(seconds: 5),
    );
    await env.reducers.createNote(title: title, content: content);
    return insertFuture;
  }

  group('Views Integration', () {
    group('Vec<Note> view: all_notes', () {
      test(
        'initial subscription populates with existing rows',
        () async {
          final env = await connectAndRegister();
          try {
            await subscribeOrFail(env.subManager, ['SELECT * FROM note']);
            await clearNotes(env);

            await createNote(env, 'AllNotes-A', 'content A');
            await createNote(env, 'AllNotes-B', 'content B');

            await subscribeOrFail(env.subManager, [
              'SELECT * FROM note',
              'SELECT * FROM all_notes',
            ]);

            final allNotes = env.subManager.cache.getTableByTypedName<Note>(
              'all_notes',
            );

            final deadline = DateTime.now().add(const Duration(seconds: 3));
            while (allNotes.count() < 2 && DateTime.now().isBefore(deadline)) {
              await Future.delayed(const Duration(milliseconds: 50));
            }

            expect(allNotes.count(), equals(2));
            final titles = allNotes.iter().map((n) => n.title).toSet();
            expect(titles, containsAll(['AllNotes-A', 'AllNotes-B']));
          } finally {
            env.subManager.dispose();
            await env.disconnect();
          }
        },
        timeout: const Timeout(Duration(seconds: 20)),
      );

      test(
        'insert on note table propagates to all_notes view',
        () async {
          final env = await connectAndRegister();
          try {
            await subscribeOrFail(env.subManager, [
              'SELECT * FROM note',
              'SELECT * FROM all_notes',
            ]);
            await clearNotes(env);

            final allNotes = env.subManager.cache.getTableByTypedName<Note>(
              'all_notes',
            );
            expect(allNotes.count(), equals(0));

            final title =
                'InsertPropagate-${DateTime.now().millisecondsSinceEpoch}';
            final viewInsertFuture = waitForInsert(
              allNotes,
              (n) => n.title == title,
              timeout: const Duration(seconds: 5),
            );

            await createNote(env, title, 'body');
            final viewRow = await viewInsertFuture;

            expect(viewRow.title, equals(title));
            expect(allNotes.count(), equals(1));
            expect(allNotes.iter().single.title, equals(title));
          } finally {
            env.subManager.dispose();
            await env.disconnect();
          }
        },
        timeout: const Timeout(Duration(seconds: 20)),
      );

      test(
        'delete on note table propagates to all_notes view',
        () async {
          final env = await connectAndRegister();
          try {
            await subscribeOrFail(env.subManager, [
              'SELECT * FROM note',
              'SELECT * FROM all_notes',
            ]);
            await clearNotes(env);

            final note = await createNote(env, 'DeleteMe', 'x');
            final allNotes = env.subManager.cache.getTableByTypedName<Note>(
              'all_notes',
            );

            final deadline = DateTime.now().add(const Duration(seconds: 3));
            while (allNotes.count() < 1 && DateTime.now().isBefore(deadline)) {
              await Future.delayed(const Duration(milliseconds: 50));
            }
            expect(allNotes.count(), equals(1));

            final deleteFuture = waitForDelete(
              allNotes,
              (n) => n.id == note.id,
              timeout: const Duration(seconds: 5),
            );

            await env.reducers.deleteNote(noteId: note.id);

            await deleteFuture;
            expect(allNotes.find(note.id), isNull);
            expect(allNotes.count(), equals(0));
          } finally {
            env.subManager.dispose();
            await env.disconnect();
          }
        },
        timeout: const Timeout(Duration(seconds: 20)),
      );
    });

    group('Option<Note> view: first_note', () {
      test(
        'returns the row when id=1 is present',
        () async {
          final env = await connectAndRegister();
          try {
            await subscribeOrFail(env.subManager, ['SELECT * FROM note']);
            await clearNotes(env);
            final seeded = await createNote(env, 'SeedOne', 'seed');
            expect(seeded.id, equals(1));

            await subscribeOrFail(env.subManager, [
              'SELECT * FROM note',
              'SELECT * FROM first_note',
            ]);

            final firstNoteCache = env.subManager.cache
                .getTableByTypedName<Note>('first_note');

            final deadline = DateTime.now().add(const Duration(seconds: 3));
            while (firstNoteCache.count() < 1 &&
                DateTime.now().isBefore(deadline)) {
              await Future.delayed(const Duration(milliseconds: 50));
            }

            expect(firstNoteCache.count(), equals(1));
            final row = firstNoteCache.iter().first;
            expect(row.id, equals(1));
            expect(row.title, equals('SeedOne'));
          } finally {
            env.subManager.dispose();
            await env.disconnect();
          }
        },
        timeout: const Timeout(Duration(seconds: 20)),
      );

      test(
        'returns null when table is empty',
        () async {
          final env = await connectAndRegister();
          try {
            await subscribeOrFail(env.subManager, [
              'SELECT * FROM note',
              'SELECT * FROM first_note',
            ]);
            final firstNoteCache = env.subManager.cache
                .getTableByTypedName<Note>('first_note');

            if (firstNoteCache.count() > 0) {
              final deleteFuture = waitForNextDelete(
                firstNoteCache,
              ).timeout(const Duration(seconds: 5));
              await clearNotes(env);
              await deleteFuture;
            } else {
              await clearNotes(env);
            }

            expect(firstNoteCache.count(), equals(0));
            expect(firstNoteCache.iter().isEmpty, isTrue);
          } finally {
            env.subManager.dispose();
            await env.disconnect();
          }
        },
        timeout: const Timeout(Duration(seconds: 20)),
      );
    });

    group('Joint subscription', () {
      test(
        'note table and all_notes view populate independent caches',
        () async {
          final env = await connectAndRegister();
          try {
            await subscribeOrFail(env.subManager, ['SELECT * FROM note']);
            await clearNotes(env);

            await createNote(env, 'Joint-A', 'a');
            await createNote(env, 'Joint-B', 'b');

            await subscribeOrFail(env.subManager, [
              'SELECT * FROM note',
              'SELECT * FROM all_notes',
            ]);

            final noteTable = env.subManager.cache.getTableByTypedName<Note>(
              'note',
            );
            final allNotes = env.subManager.cache.getTableByTypedName<Note>(
              'all_notes',
            );

            final deadline = DateTime.now().add(const Duration(seconds: 3));
            while ((noteTable.count() < 2 || allNotes.count() < 2) &&
                DateTime.now().isBefore(deadline)) {
              await Future.delayed(const Duration(milliseconds: 50));
            }

            expect(noteTable.count(), equals(2));
            expect(allNotes.count(), equals(2));
            expect(identical(noteTable, allNotes), isFalse);

            final noteTitles = noteTable.iter().map((n) => n.title).toSet();
            final viewTitles = allNotes.iter().map((n) => n.title).toSet();
            expect(noteTitles, containsAll(['Joint-A', 'Joint-B']));
            expect(viewTitles, containsAll(['Joint-A', 'Joint-B']));
          } finally {
            env.subManager.dispose();
            await env.disconnect();
          }
        },
        timeout: const Timeout(Duration(seconds: 20)),
      );
    });
  });
}
