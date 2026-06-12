// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:spacetimedb_sdk/codegen.dart';
import '../generated/note.dart';
import '../helpers/integration_test_helper.dart';
import '../helpers/test_env.dart';
import '../helpers/value_notifier_helpers.dart';

const _timeout = Duration(seconds: 10);

void main() {
  setUpAll(ensureTestEnvironment);
  tearDownAll(cleanupTestEnvironment);

  group('Sync rejection surfacing', () {
    late Directory tempDir;
    late TestEnv env;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('rejection_test_');
      env = await createTestEnv(
        offlineStorage: JsonFileStorage(basePath: tempDir.path),
      );
      await env.connection.connect();
      await env.subManager.onInitialConnection.first.timeout(_timeout);
      unawaited(env.subManager.subscribe(['SELECT * FROM note']));
      await env.subManager.onSubscribeApplied.first.timeout(_timeout);
    });

    tearDown(() async {
      await env.subManager.dispose();
      await env.connection.disconnect();
      try {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      } catch (_) {}
    });

    Future<Note> createAndSync(String title, String content) async {
      final synced = Completer<void>();
      final sub = env.subManager.onMutationSyncResult.listen((r) {
        if (r.reducerName == 'create_note' && !synced.isCompleted) {
          expect(r.success, isTrue);
          synced.complete();
        }
      });
      final insertFuture = waitForInsert(
        env.noteTable,
        (n) => n.title == title,
        timeout: _timeout,
      );
      await env.reducers.createNote(title: title, content: content);
      await synced.future.timeout(_timeout);
      await sub.cancel();
      return insertFuture;
    }

    Future<void> waitForSyncState(bool Function(SyncState) predicate) async {
      final deadline = DateTime.now().add(_timeout);
      while (!predicate(env.subManager.syncState)) {
        if (DateTime.now().isAfter(deadline)) {
          fail('syncState never satisfied predicate: '
              '${env.subManager.syncState}');
        }
        await Future.delayed(const Duration(milliseconds: 25));
      }
    }

    Note editedCopy(Note row, String content) {
      return Note(
        id: row.id,
        title: row.title,
        content: content,
        timestamp: row.timestamp,
        status: row.status,
      );
    }

    test('real server rejection is rolled back and surfaced', () async {
      final title = 'Locked-${DateTime.now().microsecondsSinceEpoch}';
      final note = await createAndSync(title, 'LOCKED original');

      final disconnected = env.connection.onStateChanged
          .firstWhere((s) => s is! Connected)
          .timeout(_timeout);
      await env.connection.disconnect();
      await disconnected;

      final oldRow = env.noteTable.getRow(note.id)!;
      await env.reducers.updateNoteGuarded(
        noteId: note.id,
        content: 'offline edit',
        optimisticChanges: [
          OptimisticChange.update(
            'note',
            oldRow.toJson(),
            editedCopy(oldRow, 'offline edit').toJson(),
          ),
        ],
      );
      expect(env.noteTable.getRow(note.id)!.content, equals('offline edit'));
      expect(env.subManager.syncState.pendingCount, equals(1));

      final failed = Completer<MutationSyncResult>();
      final sub = env.subManager.onMutationSyncResult.listen((r) {
        if (r.reducerName == 'update_note_guarded' && !failed.isCompleted) {
          failed.complete(r);
        }
      });

      await env.connection.connect();
      await env.subManager.onInitialConnection.first.timeout(_timeout);
      await env.subManager.onSubscribeApplied.first.timeout(_timeout);

      final result = await failed.future.timeout(_timeout);
      await sub.cancel();

      expect(result.success, isFalse, reason: 'server must reject the edit');
      await waitForSyncState((s) => s.isIdle && s.failedCount > 0);

      final state = env.subManager.syncState;
      expect(state.failedCount, equals(1));
      expect(state.hasError, isTrue);
      expect(state.recentFailures.single.reducerName,
          equals('update_note_guarded'));
      expect(
        state.recentFailures.single.optimisticChanges!.single
            .newRowJson!['content'],
        equals('offline edit'),
        reason: 'failure record must carry the lost edit for recovery',
      );

      expect(
        env.noteTable.getRow(note.id)!.content,
        equals('LOCKED original'),
        reason: 'rejected edit must be rolled back in the cache',
      );
      expect(
        await env.subManager.getPendingMutations(),
        isEmpty,
        reason: 'deterministic rejection must not retry forever',
      );
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('mixed batch: rejection does not poison the queue and reports partially',
        () async {
      final ts = DateTime.now().microsecondsSinceEpoch;
      final normal = await createAndSync('Normal-$ts', 'v1');
      final locked = await createAndSync('Locked-$ts', 'LOCKED original');

      final disconnected = env.connection.onStateChanged
          .firstWhere((s) => s is! Connected)
          .timeout(_timeout);
      await env.connection.disconnect();
      await disconnected;

      await env.reducers.updateNote(
        noteId: normal.id,
        title: normal.title,
        content: 'v2',
      );
      await env.reducers.updateNoteGuarded(
        noteId: locked.id,
        content: 'should be rejected',
      );
      await env.reducers.updateNote(
        noteId: normal.id,
        title: normal.title,
        content: 'v3',
      );
      expect(env.subManager.syncState.pendingCount, equals(3));

      final results = <MutationSyncResult>[];
      final allDone = Completer<void>();
      final sub = env.subManager.onMutationSyncResult.listen((r) {
        results.add(r);
        if (results.length == 3 && !allDone.isCompleted) {
          allDone.complete();
        }
      });

      await env.connection.connect();
      await env.subManager.onInitialConnection.first.timeout(_timeout);
      await env.subManager.onSubscribeApplied.first.timeout(_timeout);
      await allDone.future.timeout(_timeout);
      await sub.cancel();

      expect(results.where((r) => r.success), hasLength(2));
      expect(results.where((r) => !r.success), hasLength(1));
      await waitForSyncState((s) => s.isIdle && s.failedCount > 0);
      expect(env.subManager.syncState.failedCount, equals(1));
      expect(env.subManager.syncState.hasError, isTrue);

      final observer = await createTestEnv();
      addTearDown(() async {
        await observer.subManager.dispose();
        await observer.connection.disconnect();
      });
      await observer.connection.connect();
      await observer.subManager.onInitialConnection.first.timeout(_timeout);
      observer.subManager.subscribe(['SELECT * FROM note']);
      await observer.subManager.onSubscribeApplied.first.timeout(_timeout);

      expect(
        observer.noteTable.getRow(normal.id)!.content,
        equals('v3'),
        reason: 'good edits around the rejection must land on the server',
      );
      expect(
        observer.noteTable.getRow(locked.id)!.content,
        equals('LOCKED original'),
        reason: 'rejected edit must not reach the server',
      );
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('success and rejection flushes are distinguishable via SyncState',
        () async {
      final ts = DateTime.now().microsecondsSinceEpoch;
      final note = await createAndSync('Distinguish-$ts', 'v1');

      Future<SyncState> flushOffline(
        int expectedResults,
        Future<void> Function() queueEdits,
      ) async {
        final disconnected = env.connection.onStateChanged
            .firstWhere((s) => s is! Connected)
            .timeout(_timeout);
        await env.connection.disconnect();
        await disconnected;

        await queueEdits();

        final done = Completer<void>();
        var seen = 0;
        final sub = env.subManager.onMutationSyncResult.listen((r) {
          seen++;
          if (seen == expectedResults && !done.isCompleted) done.complete();
        });
        await env.connection.connect();
        await env.subManager.onInitialConnection.first.timeout(_timeout);
        await env.subManager.onSubscribeApplied.first.timeout(_timeout);
        await done.future.timeout(_timeout);
        await sub.cancel();
        await Future.delayed(const Duration(milliseconds: 100));
        return env.subManager.syncState;
      }

      final successState = await flushOffline(1, () async {
        await env.reducers.updateNote(
          noteId: note.id,
          title: note.title,
          content: 'good edit',
        );
      });

      final rejectionState = await flushOffline(2, () async {
        await env.reducers.updateNote(
          noteId: note.id,
          title: note.title,
          content: 'LOCKED now',
        );
        await env.reducers.updateNoteGuarded(
          noteId: note.id,
          content: 'will be rejected',
        );
      });

      expect(successState.hasError, isFalse);
      expect(successState.failedCount, equals(0));
      expect(rejectionState.hasError, isTrue);
      expect(rejectionState.failedCount, greaterThan(0));
    }, timeout: const Timeout(Duration(seconds: 90)));
  });
}
