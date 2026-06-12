// ignore_for_file: avoid_print
//
// Reproduces the 2026-06-12 field incident: note edits made while the
// server was unreachable were queued offline, the app was restarted, and
// after reconnect the queue flushed "successfully" (pending 18 -> 0, no
// errors) yet the note came back as the stale server copy.
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

  group('Offline edits survive app restart + reconnect', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('offline_edit_restart_');
    });

    tearDown(() async {
      try {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      } catch (_) {}
    });

    test(
      'edits queued while disconnected reach the server and the cache after restart + reconnect',
      () async {
        final title = 'PullDay-${DateTime.now().microsecondsSinceEpoch}';

        // === Phase 1: online session — note exists on the server ===
        final storage1 = JsonFileStorage(basePath: tempDir.path);
        final env1 = await createTestEnv(offlineStorage: storage1);

        await env1.connection.connect();
        await env1.subManager.onInitialConnection.first.timeout(_timeout);
        env1.subManager.subscribe(['SELECT * FROM note']);
        await env1.subManager.onSubscribeApplied.first.timeout(_timeout);

        final createSynced = Completer<void>();
        final createSub = env1.subManager.onMutationSyncResult.listen((r) {
          if (r.reducerName == 'create_note' && !createSynced.isCompleted) {
            expect(r.success, isTrue, reason: 'setup create must sync');
            createSynced.complete();
          }
        });
        final insertFuture = waitForInsert(
          env1.noteTable,
          (n) => n.title == title,
          timeout: _timeout,
        );
        await env1.reducers.createNote(title: title, content: 'server v1');
        await createSynced.future.timeout(_timeout);
        await createSub.cancel();
        final created = await insertFuture;
        final noteId = created.id;

        // === Phase 2: server becomes unreachable, user keeps editing ===
        final disconnected = env1.connection.onStateChanged
            .firstWhere((s) => s is! Connected)
            .timeout(_timeout);
        await env1.connection.disconnect();
        await disconnected;

        const offlineEdits = ['offline v2', 'offline v3', 'offline v4 final'];
        for (final content in offlineEdits) {
          final oldRow = env1.noteTable.getRow(noteId)!;
          final newRow = Note(
            id: oldRow.id,
            title: oldRow.title,
            content: content,
            timestamp: oldRow.timestamp,
            status: oldRow.status,
          );
          final result = await env1.reducers.updateNote(
            noteId: noteId,
            title: title,
            content: content,
            optimisticChanges: [
              OptimisticChange.update('note', oldRow.toJson(), newRow.toJson()),
            ],
          );
          expect(result.isPending, isTrue, reason: 'offline edit is queued');
        }

        expect(
          env1.noteTable.getRow(noteId)!.content,
          equals('offline v4 final'),
          reason: 'optimistic content visible while offline',
        );
        expect(
          env1.subManager.syncState.pendingCount,
          equals(offlineEdits.length),
          reason: 'every offline edit is pending',
        );

        // === Phase 3: app restart — fresh client, same storage path ===
        await env1.subManager.dispose();
        await env1.connection.disconnect();

        final storage2 = JsonFileStorage(basePath: tempDir.path);
        final env2 = await createTestEnv(offlineStorage: storage2);
        addTearDown(() async {
          await env2.subManager.dispose();
          await env2.connection.disconnect();
        });

        await env2.subManager.loadFromOfflineCache();

        expect(
          env2.subManager.syncState.pendingCount,
          equals(offlineEdits.length),
          reason: 'pending queue must survive app restart',
        );
        expect(
          env2.noteTable.getRow(noteId)?.content,
          equals('offline v4 final'),
          reason: 'offline edit visible from snapshot + overlay after restart',
        );

        // === Phase 4: server comes back, app reconnects and flushes ===
        final syncResults = <MutationSyncResult>[];
        final allSynced = Completer<void>();
        final syncSub = env2.subManager.onMutationSyncResult.listen((r) {
          syncResults.add(r);
          if (syncResults.length == offlineEdits.length &&
              !allSynced.isCompleted) {
            allSynced.complete();
          }
        });

        await env2.connection.connect();
        await env2.subManager.onInitialConnection.first.timeout(_timeout);
        env2.subManager.subscribe(['SELECT * FROM note']);
        await env2.subManager.onSubscribeApplied.first.timeout(_timeout);

        await allSynced.future.timeout(_timeout);
        await syncSub.cancel();

        for (final r in syncResults) {
          expect(
            r.success,
            isTrue,
            reason: 'flush reported failure: ${r.reducerName} - ${r.error}',
          );
        }

        await Future.delayed(const Duration(milliseconds: 200));

        final cacheContent = env2.noteTable.getRow(noteId)?.content;

        // === Phase 5: independent client proves what the server holds ===
        final env3 = await createTestEnv();
        addTearDown(() async {
          await env3.subManager.dispose();
          await env3.connection.disconnect();
        });
        await env3.connection.connect();
        await env3.subManager.onInitialConnection.first.timeout(_timeout);
        env3.subManager.subscribe(['SELECT * FROM note']);
        await env3.subManager.onSubscribeApplied.first.timeout(_timeout);
        final serverContent = env3.noteTable.getRow(noteId)?.content;

        print('After flush: cache="$cacheContent" server="$serverContent"');

        expect(
          serverContent,
          equals('offline v4 final'),
          reason:
              'FIELD BUG: offline edits never reached the server despite a clean flush',
        );

        // This is what the user sees when opening the note after reconnect.
        expect(
          cacheContent,
          equals('offline v4 final'),
          reason:
              'FIELD BUG: cache showed the stale server copy after a clean flush',
        );
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );
  });
}
