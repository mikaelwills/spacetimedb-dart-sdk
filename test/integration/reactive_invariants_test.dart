library;

// ignore_for_file: avoid_print
import 'dart:async';
import 'package:test/test.dart';
import 'package:spacetimedb_dart_sdk/codegen.dart';
import '../generated/note.dart';
import 'package:spacetimedb_dart_sdk/src/utils/sdk_logger.dart';

import '../helpers/integration_test_helper.dart';
import '../helpers/test_env.dart';
import '../helpers/value_notifier_helpers.dart';

/// Guards the two reactive invariants every SDK client relies on:
///
/// 1. **Per-transaction atomicity.** A transaction touching N rows fires
///    `rows` exactly once and `lastBatch` exactly once — never N times.
/// 2. **Ordering.** `rows.value` reflects the post-transaction state before
///    `lastBatch` fires, so a `lastBatch` listener can safely read
///    `table.rows.value` / `table.find(id)` and see the new state.
///
/// These aren't unit tests of [TableCache] internals — they test the contract
/// consumers depend on, independent of how [emitBatch] is implemented.
void main() {
  setUpAll(() async {
    SdkLogger.level = SdkLogLevel.debug;
    await ensureTestEnvironment();
  });
  tearDownAll(cleanupTestEnvironment);

  Future<TestEnv> bootEnv({bool registerFolder = false}) async {
    final env = await createTestEnv(registerFolder: registerFolder);
    await env.connection.connect();
    await env.subManager.onIdentityToken.first;
    final tables = <String>['SELECT * FROM note'];
    if (registerFolder) tables.add('SELECT * FROM folder');
    env.subManager.subscribe(tables);
    await env.subManager.onInitialSubscription.first;

    if (env.noteTable.count() > 0) {
      await env.reducers.deleteAllNotes();
      await Future.delayed(const Duration(milliseconds: 300));
    }
    return env;
  }

  /// Wait until the recorder has observed at least [minFires] fires, or time
  /// out. Polls every 50ms because transaction delivery is WebSocket-paced and
  /// we can't block on a Future in the table cache code path.
  Future<void> waitForFires(
    NotifierFireRecorder recorder,
    int minFires, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (recorder.fireCount < minFires) {
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException(
          'Waited ${timeout.inMilliseconds}ms for $minFires fires, '
          'only saw ${recorder.fireCount}',
        );
      }
      await Future.delayed(const Duration(milliseconds: 50));
    }
    // Give any straggler fires a chance to arrive, so "exactly N" assertions
    // will catch over-firing regressions.
    await Future.delayed(const Duration(milliseconds: 300));
  }

  group('Single-row transactions', () {
    test(
      'create_note fires rows and lastBatch exactly once',
      () async {
        final env = await bootEnv();
        final rows = NotifierFireRecorder(env.noteTable.rows);
        final batch = NotifierFireRecorder(env.noteTable.lastBatch);

        await env.reducers.createNote(
          title: 'single-insert-${DateTime.now().microsecondsSinceEpoch}',
          content: 'x',
        );
        await waitForFires(batch, 1);

        expect(
          rows.fireCount,
          equals(1),
          reason: 'single-row insert must fire rows exactly once',
        );
        expect(
          batch.fireCount,
          equals(1),
          reason: 'single-row insert must fire lastBatch exactly once',
        );

        final observed = batch.lastValue as TransactionBatch<Note>;
        expect(observed.length, equals(1));
        expect(observed.inserts, hasLength(1));
        expect(observed.updates, isEmpty);
        expect(observed.deletes, isEmpty);

        rows.dispose();
        batch.dispose();
        env.subManager.dispose();
        await env.disconnect();
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
      'update_note fires rows and lastBatch exactly once',
      () async {
        final env = await bootEnv();
        await env.reducers.createNote(title: 'to-update', content: 'before');
        // Wait until the cache actually reflects the create before attaching
        // recorders — otherwise a slow-delivered TransactionUpdate for the
        // create could be counted against our update assertion.
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (env.noteTable.count() == 0) {
          if (DateTime.now().isAfter(deadline)) {
            fail('Setup createNote was never reflected in the cache');
          }
          await Future.delayed(const Duration(milliseconds: 50));
        }
        await Future.delayed(const Duration(milliseconds: 300));

        final rows = NotifierFireRecorder(env.noteTable.rows);
        final batch = NotifierFireRecorder(env.noteTable.lastBatch);

        final target = env.noteTable.iter().first;
        await env.reducers.updateNote(
          noteId: target.id,
          title: target.title,
          content: 'after',
        );
        await waitForFires(batch, 1);

        expect(rows.fireCount, equals(1));
        expect(batch.fireCount, equals(1));

        final observed = batch.lastValue as TransactionBatch<Note>;
        expect(
          observed.length,
          equals(1),
          reason:
              'single-row update must produce a batch of length 1. '
              'Events observed: ${observed.events}',
        );
        expect(observed.updates, hasLength(1));
        final update = observed.updates.first;
        expect(update.oldRow.content, equals('before'));
        expect(update.newRow.content, equals('after'));

        rows.dispose();
        batch.dispose();
        env.subManager.dispose();
        await env.disconnect();
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
      'delete_note fires rows and lastBatch exactly once',
      () async {
        final env = await bootEnv();
        await env.reducers.createNote(title: 'to-delete', content: 'x');
        await Future.delayed(const Duration(milliseconds: 300));

        final rows = NotifierFireRecorder(env.noteTable.rows);
        final batch = NotifierFireRecorder(env.noteTable.lastBatch);

        final target = env.noteTable.iter().first;
        await env.reducers.deleteNote(noteId: target.id);
        await waitForFires(batch, 1);

        expect(rows.fireCount, equals(1));
        expect(batch.fireCount, equals(1));

        final observed = batch.lastValue as TransactionBatch<Note>;
        expect(observed.length, equals(1));
        expect(observed.deletes, hasLength(1));

        rows.dispose();
        batch.dispose();
        env.subManager.dispose();
        await env.disconnect();
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  });

  test(
    'DIAG: zero-arg bulk insert reducer reaches the server',
    () async {
      final env = await bootEnv();
      final batch = NotifierFireRecorder(env.noteTable.lastBatch);

      await env.reducers.diagInsertFive();
      await waitForFires(batch, 1);

      expect(batch.fireCount, equals(1));
      expect((batch.lastValue as TransactionBatch<Note>).length, equals(5));

      batch.dispose();
      env.subManager.dispose();
      await env.disconnect();
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  group('Bulk transactions', () {
    test(
      'create_notes_bulk(10) fires once with 10 inserts',
      () async {
        final env = await bootEnv();
        final rows = NotifierFireRecorder(env.noteTable.rows);
        final batch = NotifierFireRecorder(env.noteTable.lastBatch);

        await env.reducers.createNotesBulk(count: 10, titlePrefix: 'bulk');
        await waitForFires(batch, 1);

        expect(
          rows.fireCount,
          equals(1),
          reason: '10-row insert must fire rows exactly once',
        );
        expect(
          batch.fireCount,
          equals(1),
          reason: '10-row insert must fire lastBatch exactly once',
        );

        final observed = batch.lastValue as TransactionBatch<Note>;
        expect(observed.length, equals(10));
        expect(observed.inserts, hasLength(10));
        expect(observed.updates, isEmpty);
        expect(observed.deletes, isEmpty);

        rows.dispose();
        batch.dispose();
        env.subManager.dispose();
        await env.disconnect();
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
      'update_all_notes(10 existing) fires once with 10 updates',
      () async {
        final env = await bootEnv();
        await env.reducers.createNotesBulk(
          count: 10,
          titlePrefix: 'pre-update',
        );
        await Future.delayed(const Duration(milliseconds: 500));

        final rows = NotifierFireRecorder(env.noteTable.rows);
        final batch = NotifierFireRecorder(env.noteTable.lastBatch);

        await env.reducers.updateAllNotes(newContent: 'bulk-new-content');
        await waitForFires(batch, 1);

        expect(rows.fireCount, equals(1));
        expect(batch.fireCount, equals(1));

        final observed = batch.lastValue as TransactionBatch<Note>;
        expect(observed.length, equals(10));
        expect(observed.updates, hasLength(10));
        expect(observed.inserts, isEmpty);
        expect(observed.deletes, isEmpty);

        rows.dispose();
        batch.dispose();
        env.subManager.dispose();
        await env.disconnect();
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
      'delete_all_notes(10 existing) fires once with 10 deletes',
      () async {
        final env = await bootEnv();
        await env.reducers.createNotesBulk(
          count: 10,
          titlePrefix: 'pre-delete',
        );
        await Future.delayed(const Duration(milliseconds: 500));

        final rows = NotifierFireRecorder(env.noteTable.rows);
        final batch = NotifierFireRecorder(env.noteTable.lastBatch);

        await env.reducers.deleteAllNotes();
        await waitForFires(batch, 1);

        expect(rows.fireCount, equals(1));
        expect(batch.fireCount, equals(1));

        final observed = batch.lastValue as TransactionBatch<Note>;
        expect(observed.length, equals(10));
        expect(observed.deletes, hasLength(10));

        rows.dispose();
        batch.dispose();
        env.subManager.dispose();
        await env.disconnect();
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  });

  test(
    'mixed_note_batch fires once with inserts + updates + deletes bundled',
    () async {
      final env = await bootEnv();
      await env.reducers.createNotesBulk(count: 8, titlePrefix: 'pre-mixed');
      await Future.delayed(const Duration(milliseconds: 500));

      final rows = NotifierFireRecorder(env.noteTable.rows);
      final batch = NotifierFireRecorder(env.noteTable.lastBatch);

      // 3 inserts, 3 updates, 2 deletes in one transaction.
      await env.reducers.mixedNoteBatch(
        inserts: 3,
        updates: 3,
        deletes: 2,
        marker: 'mix',
      );
      await waitForFires(batch, 1);

      expect(
        rows.fireCount,
        equals(1),
        reason: 'mixed transaction must fire rows exactly once',
      );
      expect(
        batch.fireCount,
        equals(1),
        reason: 'mixed transaction must fire lastBatch exactly once',
      );

      final observed = batch.lastValue as TransactionBatch<Note>;
      expect(observed.length, equals(8));
      expect(observed.inserts, hasLength(3));
      expect(observed.updates, hasLength(3));
      expect(observed.deletes, hasLength(2));

      rows.dispose();
      batch.dispose();
      env.subManager.dispose();
      await env.disconnect();
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'note transaction does not fire folder notifiers',
    () async {
      final env = await bootEnv(registerFolder: true);

      // Clear folders too, to start from a known state.
      if (env.folderTable.count() > 0) {
        await env.reducers.deleteAllFolders();
        await Future.delayed(const Duration(milliseconds: 300));
      }

      final folderRows = NotifierFireRecorder(env.folderTable.rows);
      final folderBatch = NotifierFireRecorder(env.folderTable.lastBatch);
      final noteBatch = NotifierFireRecorder(env.noteTable.lastBatch);

      await env.reducers.createNotesBulk(count: 5, titlePrefix: 'isolation');
      await waitForFires(noteBatch, 1);

      expect(
        folderRows.fireCount,
        equals(0),
        reason: 'touching note must not fire folder.rows',
      );
      expect(
        folderBatch.fireCount,
        equals(0),
        reason: 'touching note must not fire folder.lastBatch',
      );

      folderRows.dispose();
      folderBatch.dispose();
      noteBatch.dispose();
      env.subManager.dispose();
      await env.disconnect();
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'rows reflects post-transaction state before lastBatch fires',
    () async {
      final env = await bootEnv();
      final table = env.noteTable;

      final snapshots = <int>[];
      final completer = Completer<void>();
      void listener() {
        final b = table.lastBatch.value;
        if (b == null) return;
        // Read rows from inside the lastBatch listener. Must already reflect
        // the post-transaction state or the ordering contract is broken.
        snapshots.add(table.rows.value.length);
        if (!completer.isCompleted) completer.complete();
      }

      table.lastBatch.addListener(listener);

      await env.reducers.createNotesBulk(count: 4, titlePrefix: 'ordering');
      await completer.future.timeout(const Duration(seconds: 5));
      await Future.delayed(const Duration(milliseconds: 200));
      table.lastBatch.removeListener(listener);

      expect(
        snapshots,
        isNotEmpty,
        reason: 'lastBatch listener was never invoked',
      );
      expect(
        snapshots.first,
        equals(4),
        reason:
            'When lastBatch fires, rows.value must already reflect the '
            'post-transaction state. Observed rows.length=${snapshots.first}, '
            'expected 4.',
      );

      env.subManager.dispose();
      await env.disconnect();
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'no_op reducer does not fire lastBatch',
    () async {
      final env = await bootEnv();
      final rows = NotifierFireRecorder(env.noteTable.rows);
      final batch = NotifierFireRecorder(env.noteTable.lastBatch);

      await env.reducers.noOp();
      // Give any spurious fires a chance to arrive.
      await Future.delayed(const Duration(milliseconds: 800));

      expect(
        batch.fireCount,
        equals(0),
        reason: 'empty transaction must not fire lastBatch',
      );
      // rows.fireCount is allowed to be 0 or more — the guarantee is about
      // lastBatch, since rows fires whenever _refreshRowsNotifier is called
      // and we don't want to over-specify here.

      rows.dispose();
      batch.dispose();
      env.subManager.dispose();
      await env.disconnect();
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
