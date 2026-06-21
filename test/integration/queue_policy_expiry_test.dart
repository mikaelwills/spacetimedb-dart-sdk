// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:convert';
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

  group('Queue replay policy end-to-end', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('queue_policy_test_');
    });

    tearDown(() async {
      try {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      } catch (_) {}
    });

    Future<TestEnv> connectEnv(TestEnv env) async {
      await env.connection.connect();
      await env.subManager.onInitialConnection.first.timeout(_timeout);
      env.subManager.subscribe(['SELECT * FROM note']);
      await env.subManager.onSubscribeApplied.first.timeout(_timeout);
      return env;
    }

    Future<Note> createAndSync(TestEnv env, String title, String content) async {
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

    Note editedCopy(Note row, String content) => Note(
      id: row.id,
      title: row.title,
      content: content,
      timestamp: row.timestamp,
      status: row.status,
    );

    Future<void> queueEdit(TestEnv env, Note row, String content) async {
      await env.reducers.updateNote(
        noteId: row.id,
        title: row.title,
        content: content,
        optimisticChanges: [
          OptimisticChange.update(
            'note',
            row.toJson(),
            editedCopy(row, content).toJson(),
          ),
        ],
      );
    }

    Future<void> backdateMutation(String requestId, Duration age) async {
      final file = File('${tempDir.path}/pending_mutations.jsonl');
      final lines = await file.readAsLines();
      final rewritten = <String>[];
      for (final line in lines) {
        if (line.trim().isEmpty) continue;
        final decoded = jsonDecode(line);
        if (decoded is! Map<String, dynamic>) {
          fail('journal line should be an object');
        }
        final mutation = decoded['mutation'];
        if (mutation is Map<String, dynamic> &&
            mutation['requestId'] == requestId) {
          mutation['createdAt'] =
              DateTime.now().subtract(age).toIso8601String();
        }
        rewritten.add(jsonEncode(decoded));
      }
      await file.writeAsString('${rewritten.join('\n')}\n', flush: true);
    }

    test(
      'expired mutation never reaches the wire, fresh one lands',
      () async {
        final title = 'Expiry-${DateTime.now().microsecondsSinceEpoch}';

        final env1 = await connectEnv(
          await createTestEnv(
            offlineStorage: JsonFileStorage(basePath: tempDir.path),
          ),
        );
        final note = await createAndSync(env1, title, 'server v1');

        final disconnected = env1.connection.onStateChanged
            .firstWhere((s) => s is! Connected)
            .timeout(_timeout);
        await env1.connection.disconnect();
        await disconnected;

        final staleResult = await env1.reducers.updateNote(
          noteId: note.id,
          title: note.title,
          content: 'stale edit A',
        );
        await queueEdit(env1, env1.noteTable.getRow(note.id)!, 'fresh edit');

        await env1.subManager.dispose();
        await env1.connection.disconnect();

        await backdateMutation(
          staleResult.pendingRequestId!,
          const Duration(hours: 2),
        );

        final observer = await connectEnv(await createTestEnv());
        addTearDown(() async {
          await observer.subManager.dispose();
          await observer.connection.disconnect();
        });
        final observedContents = <String>[];
        final observerSub = observer.noteTable.onUpdate.listen((event) {
          if (event.newRow.id == note.id) {
            observedContents.add(event.newRow.content);
          }
        });

        final env2 = await createTestEnv(
          offlineStorage: JsonFileStorage(basePath: tempDir.path),
          queuePolicy: const OfflineQueuePolicy(
            maxMutationAge: Duration(hours: 1),
          ),
        );
        addTearDown(() async {
          await env2.subManager.dispose();
          await env2.connection.disconnect();
        });
        await env2.subManager.loadFromOfflineCache();
        expect(env2.subManager.syncState.pendingCount, equals(2));

        final results = <MutationSyncResult>[];
        final allDone = Completer<void>();
        final resultSub = env2.subManager.onMutationSyncResult.listen((r) {
          results.add(r);
          if (results.length == 2 && !allDone.isCompleted) allDone.complete();
        });
        await connectEnv(env2);
        await allDone.future.timeout(_timeout);
        await resultSub.cancel();
        await Future.delayed(const Duration(milliseconds: 300));
        await observerSub.cancel();

        final expired = results.where((r) => r.expired).toList();
        expect(expired, hasLength(1));
        expect(expired.single.success, isFalse);
        expect(results.where((r) => r.success), hasLength(1));
        expect(env2.subManager.syncState.failedCount, equals(1));

        expect(
          observer.noteTable.getRow(note.id)!.content,
          equals('fresh edit'),
          reason: 'fresh edit must land on the server',
        );
        expect(
          observedContents,
          isNot(contains('stale edit A')),
          reason: 'expired mutation content must never appear on the wire',
        );
        expect(
          env2.noteTable.getRow(note.id)!.content,
          equals('fresh edit'),
          reason: 'local cache converges to the surviving edit',
        );
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );

    test(
      'bounded queue with dropOldest keeps the latest state for the row',
      () async {
        final title = 'Bound-${DateTime.now().microsecondsSinceEpoch}';

        final env = await connectEnv(
          await createTestEnv(
            offlineStorage: JsonFileStorage(basePath: tempDir.path),
            queuePolicy: const OfflineQueuePolicy(
              maxQueueLength: 5,
              overflow: OverflowStrategy.dropOldest,
            ),
          ),
        );
        addTearDown(() async {
          await env.subManager.dispose();
          await env.connection.disconnect();
        });
        final note = await createAndSync(env, title, 'v1');

        final disconnected = env.connection.onStateChanged
            .firstWhere((s) => s is! Connected)
            .timeout(_timeout);
        await env.connection.disconnect();
        await disconnected;

        final dropResults = <MutationSyncResult>[];
        final dropSub = env.subManager.onMutationSyncResult.listen((r) {
          if (!r.success) dropResults.add(r);
        });

        for (var v = 2; v <= 9; v++) {
          await queueEdit(env, env.noteTable.getRow(note.id)!, 'v$v');
        }
        expect(env.subManager.syncState.pendingCount, equals(5));
        expect(
          env.subManager.syncState.failedCount,
          equals(3),
          reason: 'drops are surfaced as they happen while offline',
        );
        expect(
          env.noteTable.getRow(note.id)!.content,
          equals('v9'),
          reason: 'latest edit stays visible locally',
        );

        final successResults = <MutationSyncResult>[];
        final allDone = Completer<void>();
        final resultSub = env.subManager.onMutationSyncResult.listen((r) {
          if (r.success) successResults.add(r);
          if (successResults.length == 5 && !allDone.isCompleted) {
            allDone.complete();
          }
        });
        await env.connection.connect();
        await env.subManager.onInitialConnection.first.timeout(_timeout);
        await env.subManager.onSubscribeApplied.first.timeout(_timeout);
        await allDone.future.timeout(_timeout);
        await resultSub.cancel();
        await dropSub.cancel();
        await Future.delayed(const Duration(milliseconds: 300));

        expect(
          successResults,
          hasLength(5),
          reason: 'only the bounded queue depth replays',
        );
        expect(dropResults, hasLength(3));

        final observer = await connectEnv(await createTestEnv());
        addTearDown(() async {
          await observer.subManager.dispose();
          await observer.connection.disconnect();
        });
        expect(
          observer.noteTable.getRow(note.id)!.content,
          equals('v9'),
          reason:
              'the latest edit must survive bounding, only intermediates shed',
        );
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );

    test(
      'TTL and bounds together: expired drop AND overflow drop both shed, '
      'newest survives',
      () async {
        final title = 'TtlBound-${DateTime.now().microsecondsSinceEpoch}';

        final env1 = await connectEnv(
          await createTestEnv(
            offlineStorage: JsonFileStorage(basePath: tempDir.path),
            queuePolicy: const OfflineQueuePolicy(
              maxQueueLength: 3,
              overflow: OverflowStrategy.dropOldest,
            ),
          ),
        );
        final note = await createAndSync(env1, title, 'server v1');

        final disconnected = env1.connection.onStateChanged
            .firstWhere((s) => s is! Connected)
            .timeout(_timeout);
        await env1.connection.disconnect();
        await disconnected;

        final staleResult = await env1.reducers.updateNote(
          noteId: note.id,
          title: note.title,
          content: 'stale-then-backdated',
        );
        await queueEdit(env1, env1.noteTable.getRow(note.id)!, 'mid');
        await queueEdit(env1, env1.noteTable.getRow(note.id)!, 'newest');
        expect(env1.subManager.syncState.pendingCount, equals(3));

        await env1.subManager.dispose();
        await env1.connection.disconnect();

        await backdateMutation(
          staleResult.pendingRequestId!,
          const Duration(hours: 2),
        );

        final env2 = await createTestEnv(
          offlineStorage: JsonFileStorage(basePath: tempDir.path),
          queuePolicy: const OfflineQueuePolicy(
            maxMutationAge: Duration(hours: 1),
            maxQueueLength: 3,
            overflow: OverflowStrategy.dropOldest,
          ),
        );
        addTearDown(() async {
          await env2.subManager.dispose();
          await env2.connection.disconnect();
        });
        await env2.subManager.loadFromOfflineCache();
        expect(env2.subManager.syncState.pendingCount, equals(3));

        final results = <MutationSyncResult>[];
        final allDone = Completer<void>();
        final resultSub = env2.subManager.onMutationSyncResult.listen((r) {
          results.add(r);
          if (results.length == 3 && !allDone.isCompleted) allDone.complete();
        });
        await connectEnv(env2);
        await allDone.future.timeout(_timeout);
        await resultSub.cancel();
        await Future.delayed(const Duration(milliseconds: 300));

        expect(results.where((r) => r.expired), hasLength(1),
            reason: 'the backdated mutation is dropped by TTL even within bounds');
        expect(results.where((r) => r.success), hasLength(2),
            reason: 'the two in-policy edits replay');

        final observer = await connectEnv(await createTestEnv());
        addTearDown(() async {
          await observer.subManager.dispose();
          await observer.connection.disconnect();
        });
        expect(
          observer.noteTable.getRow(note.id)!.content,
          equals('newest'),
          reason: 'newest in-policy edit must win on the server',
        );
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );

    test(
      'maxRetainedFailures caps recentFailures while failedCount tracks the true total',
      () async {
        final title = 'Retain-${DateTime.now().microsecondsSinceEpoch}';

        final env = await connectEnv(
          await createTestEnv(
            offlineStorage: JsonFileStorage(basePath: tempDir.path),
            queuePolicy: const OfflineQueuePolicy(
              maxQueueLength: 1,
              overflow: OverflowStrategy.dropOldest,
              maxRetainedFailures: 2,
            ),
          ),
        );
        addTearDown(() async {
          await env.subManager.dispose();
          await env.connection.disconnect();
        });
        final note = await createAndSync(env, title, 'v1');

        final disconnected = env.connection.onStateChanged
            .firstWhere((s) => s is! Connected)
            .timeout(_timeout);
        await env.connection.disconnect();
        await disconnected;

        for (var v = 2; v <= 7; v++) {
          await queueEdit(env, env.noteTable.getRow(note.id)!, 'v$v');
        }

        expect(env.subManager.syncState.failedCount, equals(5),
            reason: '6 edits into a depth-1 queue => 5 overflow drops total');
        expect(env.subManager.syncState.recentFailures, hasLength(2),
            reason: 'recentFailures is capped at maxRetainedFailures=2');
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );
  });
}
