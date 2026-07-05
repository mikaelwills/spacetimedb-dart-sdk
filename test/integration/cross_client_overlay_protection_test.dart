import 'dart:async';

import 'package:test/test.dart';
import 'package:spacetimedb_sdk/codegen.dart';
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

  Future<TestEnv> gatedEnv(Completer<void> gate) {
    return createTestEnv(
      registerNote: true,
      offlineStorage: InMemoryOfflineStorage(),
      queuePolicy: OfflineQueuePolicy(
        onBeforeReplay: (_) async {
          await gate.future;
          return ReplayDecision.replay;
        },
      ),
    );
  }

  group('cross-client write vs a pending optimistic overlay', () {
    test(
      'a remote committed update does NOT clobber our still-pending overlay on '
      'the same pk (protection holds on the real TransactionUpdate wire path)',
      () async {
        final writer = await createTestEnv(registerNote: true);
        await writer.connection.connect();
        await writer.subManager.onInitialConnection.first.timeout(_timeout);
        await writer.reducers
            .createNote(title: 'x', content: 'seed')
            .timeout(_timeout);

        final gate = Completer<void>();
        final env = await gatedEnv(gate);
        addTearDown(() async {
          if (!gate.isCompleted) gate.complete();
          writer.subManager.dispose();
          env.subManager.dispose();
          await writer.disconnect();
          await env.disconnect();
        });

        await env.connection.connect();
        await env.subManager.onInitialConnection.first.timeout(_timeout);
        await env.subManager.subscribe(['SELECT * FROM note']);
        await Future.delayed(const Duration(milliseconds: 500));

        final seed = env.noteTable.iter().firstWhere((n) => n.title == 'x');
        final id = seed.id;
        expect(seed.content, 'seed');

        final mine = {...seed.toJson(), 'content': 'my-unsynced-edit'};
        unawaited(
          env.reducers.updateNote(
            noteId: id,
            title: 'x',
            content: 'my-unsynced-edit',
            optimisticChanges: [
              OptimisticChange.update('note', seed.toJson(), mine),
            ],
          ),
        );
        await Future.delayed(const Duration(milliseconds: 300));

        expect(
          env.subManager.optimisticKeysFor('note'),
          contains(id),
          reason: 'the overlay must still be pending (send gated) so the '
              'cross-client write below meets a live overlay to protect',
        );
        expect(env.noteTable.getRow(id)!.content, 'my-unsynced-edit');

        final txArrived = env.subManager.onTransactionUpdate.first;
        await writer.reducers
            .updateNote(
              noteId: id,
              title: 'x',
              content: 'other-client-wrote-this',
            )
            .timeout(_timeout);
        await txArrived.timeout(_timeout);
        await Future.delayed(const Duration(milliseconds: 200));

        expect(
          env.noteTable.getRow(id)!.content,
          'my-unsynced-edit',
          reason: 'the remote committed update must not overwrite our pending '
              'optimistic overlay on the same pk',
        );
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      'when our reducer fails after a remote write was protection-skipped, '
      'rollback must NOT resurrect the pre-optimistic value over the newer '
      'server-committed row',
      () async {
        final writer = await createTestEnv(registerNote: true);
        await writer.connection.connect();
        await writer.subManager.onInitialConnection.first.timeout(_timeout);
        await writer.reducers
            .createNote(title: 'x', content: 'LOCKED-seed')
            .timeout(_timeout);

        final gate = Completer<void>();
        final env = await gatedEnv(gate);
        addTearDown(() async {
          if (!gate.isCompleted) gate.complete();
          writer.subManager.dispose();
          env.subManager.dispose();
          await writer.disconnect();
          await env.disconnect();
        });

        await env.connection.connect();
        await env.subManager.onInitialConnection.first.timeout(_timeout);
        await env.subManager.subscribe(['SELECT * FROM note']);
        await Future.delayed(const Duration(milliseconds: 500));

        final seed = env.noteTable.iter().firstWhere((n) => n.title == 'x');
        final id = seed.id;
        expect(seed.content, 'LOCKED-seed');

        final mine = {...seed.toJson(), 'content': 'my-unsynced-edit'};
        unawaited(
          env.reducers.updateNoteGuarded(
            noteId: id,
            content: 'my-unsynced-edit',
            optimisticChanges: [
              OptimisticChange.update('note', seed.toJson(), mine),
            ],
          ),
        );
        await Future.delayed(const Duration(milliseconds: 300));
        expect(env.subManager.optimisticKeysFor('note'), contains(id));

        final txArrived = env.subManager.onTransactionUpdate.first;
        await writer.reducers
            .updateNote(
              noteId: id,
              title: 'x',
              content: 'LOCKED-other-client-wrote-this',
            )
            .timeout(_timeout);
        await txArrived.timeout(_timeout);
        await Future.delayed(const Duration(milliseconds: 200));

        final syncFailed = env.subManager.onMutationSyncResult.firstWhere(
          (r) => !r.success,
        );
        gate.complete();
        await syncFailed.timeout(_timeout);
        await Future.delayed(const Duration(milliseconds: 300));

        expect(
          env.noteTable.getRow(id)!.content,
          'LOCKED-other-client-wrote-this',
          reason: 'our guarded reducer was rejected server-side; rolling back '
              'our overlay must leave the newer committed remote value, not '
              'resurrect the stale pre-optimistic snapshot',
        );
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );
  });
}
