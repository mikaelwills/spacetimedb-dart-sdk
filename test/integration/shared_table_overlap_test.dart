// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:spacetimedb_sdk/protocol.dart';
import 'package:spacetimedb_sdk/codegen.dart';
import '../generated/note.dart';
import '../generated/note_status.dart';
import '../helpers/integration_test_helper.dart';
import '../helpers/test_env.dart';

const _timeout = Duration(seconds: 10);

void main() {
  setUpAll(ensureTestEnvironment);
  tearDownAll(cleanupTestEnvironment);

  setUp(() async {
    final cleaner = await createTestEnv(registerNote: true);
    await cleaner.connection.connect();
    await cleaner.subManager.onInitialConnection.first.timeout(_timeout);
    await cleaner.reducers.deleteAllNotes().timeout(_timeout);
    cleaner.subManager.dispose();
    await cleaner.connection.disconnect();
  });

  Future<void> waitForState<T extends ConnectionState>(
    SpacetimeDbConnection connection, {
    Duration timeout = _timeout,
  }) async {
    if (connection.state is T) return;
    await connection.onStateChanged
        .firstWhere((state) => state is T)
        .timeout(
          timeout,
          onTimeout:
              () =>
                  throw TimeoutException(
                    'Timed out waiting for state $T. Current: ${connection.state}',
                  ),
        );
  }

  Future<TestEnv> seedNotes(int count) async {
    final writer = await createTestEnv(registerNote: true);
    await writer.connection.connect();
    await writer.subManager.onInitialConnection.first.timeout(_timeout);
    for (var i = 1; i <= count; i++) {
      await writer.reducers
          .createNote(title: 'note-$i', content: 'c$i')
          .timeout(_timeout);
    }
    return writer;
  }

  group('Shared-table overlapping subscriptions', () {
    test(
      'two overlapping WHERE subsets on one table: both sets survive after both apply',
      () async {
        final writer = await seedNotes(5);
        final env = await createTestEnv(registerNote: true);
        addTearDown(() async {
          writer.subManager.dispose();
          env.subManager.dispose();
          await writer.disconnect();
          await env.disconnect();
        });

        await env.connection.connect();
        await env.subManager.onInitialConnection.first.timeout(_timeout);

        await env.subManager.subscribe([
          'SELECT * FROM note WHERE id >= 1 AND id <= 3',
        ]);
        await env.subManager.subscribe([
          'SELECT * FROM note WHERE id >= 3 AND id <= 5',
        ]);
        await Future.delayed(const Duration(seconds: 1));

        for (var id = 1; id <= 5; id++) {
          expect(
            env.noteTable.getRow(id),
            isNotNull,
            reason:
                'id $id must survive: set A matches 1..3, set B matches 3..5, '
                'the cache is the union — no set\'s apply may clobber the other\'s rows',
          );
        }
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      'overlapping shared-table sets both rehydrate on reconnect without clobbering',
      () async {
        final writer = await seedNotes(5);
        final env = await createTestEnv(registerNote: true);
        addTearDown(() async {
          writer.subManager.dispose();
          env.subManager.dispose();
          await writer.disconnect();
          await env.disconnect();
        });

        await env.connection.connect();
        await env.subManager.onInitialConnection.first.timeout(_timeout);
        await env.subManager.subscribe([
          'SELECT * FROM note WHERE id >= 1 AND id <= 3',
        ]);
        await env.subManager.subscribe([
          'SELECT * FROM note WHERE id >= 3 AND id <= 5',
        ]);
        await Future.delayed(const Duration(seconds: 1));

        await env.connection.disconnect();
        await waitForState<Disconnected>(env.connection);

        await env.connection.reconnect();
        await waitForState<Connected>(env.connection);
        await Future.delayed(const Duration(seconds: 2));

        for (var id = 1; id <= 5; id++) {
          expect(
            env.noteTable.getRow(id),
            isNotNull,
            reason:
                'id $id must rehydrate on reconnect: serial per-set re-subscribe '
                'must not let one set\'s apply transiently clobber the other\'s rows',
          );
        }
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      'eviction still works: a row no active set matches is removed',
      () async {
        final writer = await seedNotes(5);
        final env = await createTestEnv(registerNote: true);
        addTearDown(() async {
          writer.subManager.dispose();
          env.subManager.dispose();
          await writer.disconnect();
          await env.disconnect();
        });

        await env.connection.connect();
        await env.subManager.onInitialConnection.first.timeout(_timeout);

        final setA = await env.subManager.subscribe([
          'SELECT * FROM note WHERE id >= 1 AND id <= 3',
        ]);
        await env.subManager.subscribe([
          'SELECT * FROM note WHERE id >= 3 AND id <= 5',
        ]);
        await Future.delayed(const Duration(seconds: 1));

        expect(env.noteTable.getRow(1), isNotNull);
        expect(env.noteTable.getRow(2), isNotNull);

        env.subManager.unsubscribe(setA);
        await Future.delayed(const Duration(seconds: 1));

        expect(
          env.noteTable.getRow(1),
          isNull,
          reason: 'id 1 matched only by the dropped set A — must be evicted',
        );
        expect(
          env.noteTable.getRow(2),
          isNull,
          reason: 'id 2 matched only by the dropped set A — must be evicted',
        );
        expect(
          env.noteTable.getRow(3),
          isNotNull,
          reason:
              'id 3 is still matched by set B — must survive A being dropped',
        );
        expect(env.noteTable.getRow(4), isNotNull);
        expect(env.noteTable.getRow(5), isNotNull);
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      'optimistic row on shared table survives an overlapping set apply',
      () async {
        final writer = await seedNotes(5);
        final tempDir = await Directory.systemTemp.createTemp('overlap_optim');
        final env = await createTestEnv(
          registerNote: true,
          offlineStorage: JsonFileStorage(basePath: tempDir.path),
        );
        addTearDown(() async {
          writer.subManager.dispose();
          env.subManager.dispose();
          await writer.disconnect();
          await env.disconnect();
          await tempDir.delete(recursive: true);
        });

        await env.connection.connect();
        await env.subManager.onInitialConnection.first.timeout(_timeout);

        await env.subManager.subscribe([
          'SELECT * FROM note WHERE id >= 1 AND id <= 3',
        ]);
        await Future.delayed(const Duration(seconds: 1));

        const tempId = 999;
        final optimisticNote = Note(
          id: tempId,
          title: 'optimistic',
          content: 'pending',
          timestamp: Int64(0),
          status: const NoteStatusDraft(),
        );
        final pending = env.reducers
            .createNote(
              title: 'optimistic',
              content: 'pending',
              optimisticChanges: [
                OptimisticChange.insertRow(env.noteTable, optimisticNote),
              ],
            )
            .timeout(_timeout);

        expect(
          env.noteTable.getRow(tempId),
          isNotNull,
          reason: 'precondition: optimistic row is in the cache before apply',
        );

        await env.subManager.subscribe([
          'SELECT * FROM note WHERE id >= 3 AND id <= 5',
        ]);
        await Future.delayed(const Duration(milliseconds: 200));

        expect(
          env.noteTable.getRow(tempId),
          isNotNull,
          reason:
              'an in-flight optimistic row must survive another set\'s apply '
              '(protectedKeys), not be dropped by the overlap reconcile',
        );

        await pending;
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );
  });
}
