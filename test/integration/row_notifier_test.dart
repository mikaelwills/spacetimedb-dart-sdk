library;

// ignore_for_file: avoid_print
import 'dart:async';
import 'package:test/test.dart';
import '../helpers/integration_test_helper.dart';
import '../helpers/test_env.dart';

Future<void> _pumpMicrotasks() => Future<void>.delayed(Duration.zero);

void main() {
  setUpAll(ensureTestEnvironment);
  tearDownAll(cleanupTestEnvironment);

  test(
    'rowNotifier fires on insert/update/delete from reducer',
    () async {
      final env = await createTestEnv();
      await env.connection.connect();
      env.subManager.subscribe(['SELECT * FROM note']);
      await env.subManager.onInitialSubscription.first;

      final noteTable = env.noteTable;
      final uniqueTitle =
          'row-notifier-${DateTime.now().millisecondsSinceEpoch}';

      await env.reducers.createNote(title: uniqueTitle, content: 'v1');

      int createdId = -1;
      for (var i = 0; i < 50 && createdId == -1; i++) {
        await _pumpMicrotasks();
        final match =
            noteTable.iter().where((n) => n.title == uniqueTitle).firstOrNull;
        if (match != null) createdId = match.id;
      }
      expect(createdId, isNot(-1), reason: 'Note should appear in cache');

      final n = noteTable.rowNotifier(createdId);
      final fires = <String?>[];
      n.addListener(() => fires.add(n.value?.title));

      await env.reducers.updateNote(
        noteId: createdId,
        title: 'UPDATED $uniqueTitle',
        content: 'v2',
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(fires.last, contains('UPDATED'));

      await env.reducers.deleteNote(noteId: createdId);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(fires.last, isNull);
      expect(n.value, isNull);

      env.subManager.dispose();
      await env.disconnect();
    },
    timeout: const Timeout(Duration(seconds: 15)),
  );

  test(
    'rowNotifier does NOT fire for transactions touching other rows',
    () async {
      final env = await createTestEnv();
      await env.connection.connect();
      env.subManager.subscribe(['SELECT * FROM note']);
      await env.subManager.onInitialSubscription.first;

      final noteTable = env.noteTable;
      final titleA = 'row-a-${DateTime.now().millisecondsSinceEpoch}';
      final titleB = 'row-b-${DateTime.now().millisecondsSinceEpoch}';

      await env.reducers.createNote(title: titleA, content: 'A');
      await env.reducers.createNote(title: titleB, content: 'B');

      int idA = -1;
      int idB = -1;
      for (var i = 0; i < 50 && (idA == -1 || idB == -1); i++) {
        await _pumpMicrotasks();
        for (final n in noteTable.iter()) {
          if (n.title == titleA) idA = n.id;
          if (n.title == titleB) idB = n.id;
        }
      }
      expect(idA, isNot(-1));
      expect(idB, isNot(-1));

      final notifierA = noteTable.rowNotifier(idA);
      var firesA = 0;
      notifierA.addListener(() => firesA++);

      await env.reducers.updateNote(
        noteId: idB,
        title: 'UPDATED $titleB',
        content: 'B2',
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));

      expect(
        firesA,
        equals(0),
        reason: 'Notifier A should not fire for row B updates',
      );

      env.subManager.dispose();
      await env.disconnect();
    },
    timeout: const Timeout(Duration(seconds: 15)),
  );

  test(
    'rowNotifier auto-disposes after last listener detaches',
    () async {
      final env = await createTestEnv();
      await env.connection.connect();
      env.subManager.subscribe(['SELECT * FROM note']);
      await env.subManager.onInitialSubscription.first;

      final noteTable = env.noteTable;
      final title = 'auto-${DateTime.now().millisecondsSinceEpoch}';
      await env.reducers.createNote(title: title, content: 'x');

      int id = -1;
      for (var i = 0; i < 50 && id == -1; i++) {
        await _pumpMicrotasks();
        final match =
            noteTable.iter().where((n) => n.title == title).firstOrNull;
        if (match != null) id = match.id;
      }
      expect(id, isNot(-1));

      final first = noteTable.rowNotifier(id);
      void listener() {}
      first.addListener(listener);
      first.removeListener(listener);

      await _pumpMicrotasks();

      final second = noteTable.rowNotifier(id);
      expect(
        identical(first, second),
        isFalse,
        reason: 'A fresh notifier should be created after auto-disposal',
      );

      env.subManager.dispose();
      await env.disconnect();
    },
    timeout: const Timeout(Duration(seconds: 15)),
  );
}
