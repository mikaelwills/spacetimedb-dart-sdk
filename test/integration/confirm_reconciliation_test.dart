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

  group('Confirm-time reconciliation', () {
    late Directory tempDir;
    late TestEnv env;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('reconcile_test_');
      env = await createTestEnv(
        offlineStorage: JsonFileStorage(basePath: tempDir.path),
      );
      await env.connection.connect();
      await env.subManager.onInitialConnection.first.timeout(_timeout);
      env.subManager.subscribe(['SELECT * FROM note']);
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

    Note editedCopy(Note row, String content, {int? timestamp}) {
      return Note(
        id: row.id,
        title: row.title,
        content: content,
        timestamp: timestamp != null ? Int64(timestamp) : row.timestamp,
        status: row.status,
      );
    }

    Future<void> updateWithOptimistic(
      Note oldRow,
      String content, {
      required int optimisticTimestamp,
    }) async {
      await env.reducers.updateNote(
        noteId: oldRow.id,
        title: oldRow.title,
        content: content,
        optimisticChanges: [
          OptimisticChange.update(
            'note',
            oldRow.toJson(),
            editedCopy(
              oldRow,
              content,
              timestamp: optimisticTimestamp,
            ).toJson(),
          ),
        ],
      );
    }

    test(
      'server-computed field converges after online optimistic update',
      () async {
        final title = 'Converge-${DateTime.now().microsecondsSinceEpoch}';
        final note = await createAndSync(title, 'v1');

        final synced = Completer<void>();
        final sub = env.subManager.onMutationSyncResult.listen((r) {
          if (r.reducerName == 'update_note' && !synced.isCompleted) {
            expect(r.success, isTrue);
            synced.complete();
          }
        });

        final localGuess = DateTime.now().microsecondsSinceEpoch;
        await updateWithOptimistic(
          env.noteTable.getRow(note.id)!,
          'v2',
          optimisticTimestamp: localGuess,
        );
        expect(
          env.noteTable.getRow(note.id)!.timestamp.toInt(),
          equals(localGuess),
          reason: 'optimistic guess visible immediately',
        );

        await synced.future.timeout(_timeout);
        await sub.cancel();
        await Future.delayed(const Duration(milliseconds: 200));

        final row = env.noteTable.getRow(note.id)!;
        expect(row.content, equals('v2'));
        expect(
          row.timestamp.toInt(),
          equals(0),
          reason:
              'cache must converge to the server-computed timestamp, '
              'not keep the optimistic guess',
        );
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      'offline edits: no intermediate or stale values exposed, full row converges',
      () async {
        final title = 'NoFlicker-${DateTime.now().microsecondsSinceEpoch}';
        final note = await createAndSync(title, 'server v1');

        final disconnected = env.connection.onStateChanged
            .firstWhere((s) => s is! Connected)
            .timeout(_timeout);
        await env.connection.disconnect();
        await disconnected;

        for (final content in ['v2', 'v3', 'v4 final']) {
          await updateWithOptimistic(
            env.noteTable.getRow(note.id)!,
            content,
            optimisticTimestamp: DateTime.now().microsecondsSinceEpoch,
          );
        }
        expect(env.subManager.syncState.pendingCount, equals(3));

        final observedContents = <String>[];
        final eventSub = env.noteTable.onUpdate.listen((event) {
          if (event.newRow.id == note.id) {
            observedContents.add(event.newRow.content);
          }
        });

        final results = <MutationSyncResult>[];
        final allSynced = Completer<void>();
        final resultSub = env.subManager.onMutationSyncResult.listen((r) {
          results.add(r);
          if (results.length == 3 && !allSynced.isCompleted) {
            allSynced.complete();
          }
        });

        await env.connection.connect();
        await env.subManager.onInitialConnection.first.timeout(_timeout);
        await env.subManager.onSubscribeApplied.first.timeout(_timeout);
        await allSynced.future.timeout(_timeout);
        await resultSub.cancel();
        await Future.delayed(const Duration(milliseconds: 200));
        await eventSub.cancel();

        for (final r in results) {
          expect(r.success, isTrue);
        }
        expect(
          observedContents,
          isNot(contains('server v1')),
          reason: 'stale snapshot value must never surface during reconnect',
        );
        expect(
          observedContents,
          isNot(contains('v2')),
          reason: 'intermediate flush commits must not surface',
        );
        expect(
          observedContents,
          isNot(contains('v3')),
          reason: 'intermediate flush commits must not surface',
        );

        final cachedRow = env.noteTable.getRow(note.id)!;
        expect(cachedRow.content, equals('v4 final'));
        expect(
          cachedRow.timestamp.toInt(),
          equals(0),
          reason: 'released key must reconcile to server-computed fields',
        );

        final observer = await createTestEnv();
        addTearDown(() async {
          await observer.subManager.dispose();
          await observer.connection.disconnect();
        });
        await observer.connection.connect();
        await observer.subManager.onInitialConnection.first.timeout(_timeout);
        observer.subManager.subscribe(['SELECT * FROM note']);
        await observer.subManager.onSubscribeApplied.first.timeout(_timeout);

        final serverRow = observer.noteTable.getRow(note.id)!;
        expect(
          cachedRow,
          equals(serverRow),
          reason: 'cache must equal the server row field for field',
        );
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );

    test(
      'interleaved keys release and reconcile independently',
      () async {
        final ts = DateTime.now().microsecondsSinceEpoch;
        final noteA = await createAndSync('Interleave-A-$ts', 'a1');
        final noteB = await createAndSync('Interleave-B-$ts', 'b1');

        final disconnected = env.connection.onStateChanged
            .firstWhere((s) => s is! Connected)
            .timeout(_timeout);
        await env.connection.disconnect();
        await disconnected;

        final guess = DateTime.now().microsecondsSinceEpoch;
        await updateWithOptimistic(
          env.noteTable.getRow(noteA.id)!,
          'a2',
          optimisticTimestamp: guess,
        );
        await updateWithOptimistic(
          env.noteTable.getRow(noteB.id)!,
          'b2',
          optimisticTimestamp: guess,
        );
        await updateWithOptimistic(
          env.noteTable.getRow(noteA.id)!,
          'a3',
          optimisticTimestamp: guess,
        );
        expect(env.subManager.syncState.pendingCount, equals(3));

        final bSynced = Completer<void>();
        var seen = 0;
        final allSynced = Completer<void>();
        final sub = env.subManager.onMutationSyncResult.listen((r) {
          expect(r.success, isTrue);
          seen++;
          if (seen == 2 && !bSynced.isCompleted) bSynced.complete();
          if (seen == 3 && !allSynced.isCompleted) allSynced.complete();
        });

        await env.connection.connect();
        await env.subManager.onInitialConnection.first.timeout(_timeout);
        await env.subManager.onSubscribeApplied.first.timeout(_timeout);

        await bSynced.future.timeout(_timeout);
        await Future.delayed(const Duration(milliseconds: 100));

        expect(
          env.noteTable.getRow(noteB.id)!.timestamp.toInt(),
          equals(0),
          reason:
              'B released after its only overlay confirmed, must be '
              'server-reconciled even while A still has a pending overlay',
        );
        expect(
          env.noteTable.getRow(noteA.id)!.content,
          equals('a3'),
          reason: 'A keeps optimistic content while its overlay is pending',
        );

        await allSynced.future.timeout(_timeout);
        await sub.cancel();
        await Future.delayed(const Duration(milliseconds: 200));

        final rowA = env.noteTable.getRow(noteA.id)!;
        expect(rowA.content, equals('a3'));
        expect(rowA.timestamp.toInt(), equals(0));
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );
  });
}
