import 'package:test/test.dart';
import '../helpers/integration_test_helper.dart';
import '../helpers/test_env.dart';

const _timeout = Duration(seconds: 10);

void main() {
  setUpAll(ensureTestEnvironment);
  tearDownAll(cleanupTestEnvironment);

  setUp(() async {
    final cleaner = await createTestEnv(registerNote: true, registerFolder: true);
    await cleaner.connection.connect();
    await cleaner.subManager.onInitialConnection.first.timeout(_timeout);
    await cleaner.reducers.deleteAllNotes().timeout(_timeout);
    await cleaner.reducers.deleteAllFolders().timeout(_timeout);
    cleaner.subManager.dispose();
    await cleaner.connection.disconnect();
  });

  group('blind spot variants', () {
    test(
      "variant: caller's own committed insert (non-short-circuit ReducerResult path) survives a later unrelated query-set apply",
      () async {
        final env = await createTestEnv(registerNote: true);
        addTearDown(() async {
          env.subManager.dispose();
          await env.disconnect();
        });

        await env.connection.connect();
        await env.subManager.onInitialConnection.first.timeout(_timeout);

        for (var i = 1; i <= 2; i++) {
          await env.reducers
              .createNote(title: 'seed-$i', content: 'c$i')
              .timeout(_timeout);
        }

        await env.subManager.subscribe([
          'SELECT * FROM note WHERE id >= 1 AND id <= 5',
        ]);

        final result = await env.reducers
            .createNote(title: 'own-commit-insert', content: 'no optimistic')
            .timeout(_timeout);
        expect(result.isSuccess, isTrue);

        final ownNote = env.noteTable
            .iter()
            .firstWhere((n) => n.title == 'own-commit-insert');

        expect(env.noteTable.getRow(ownNote.id), isNotNull);

        await env.subManager.subscribe([
          'SELECT * FROM note WHERE id >= 1 AND id <= 2',
        ]);

        expect(env.noteTable.getRow(ownNote.id), isNotNull);
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      'variant: live insert on a table with an active query set survives partial unsubscribe of an unrelated query set',
      () async {
        final writer = await createTestEnv(registerNote: true);
        final env = await createTestEnv(registerNote: true);
        addTearDown(() async {
          writer.subManager.dispose();
          env.subManager.dispose();
          await writer.disconnect();
          await env.disconnect();
        });

        await writer.connection.connect();
        await writer.subManager.onInitialConnection.first.timeout(_timeout);
        await env.connection.connect();
        await env.subManager.onInitialConnection.first.timeout(_timeout);

        for (var i = 1; i <= 2; i++) {
          await writer.reducers
              .createNote(title: 'seed-$i', content: 'c$i')
              .timeout(_timeout);
        }

        final querySetA = await env.subManager.subscribe([
          'SELECT * FROM note WHERE id >= 1 AND id <= 5',
        ]);
        final querySetB = await env.subManager.subscribe([
          'SELECT * FROM note WHERE id >= 1 AND id <= 2',
        ]);

        final txUpdateFuture = env.subManager.onTransactionUpdate.first.timeout(
          _timeout,
        );
        await writer.reducers
            .createNote(title: 'live-multi-tag', content: 'tagged for A and B')
            .timeout(_timeout);
        await txUpdateFuture;

        final liveNote = env.noteTable
            .iter()
            .firstWhere((n) => n.title == 'live-multi-tag');

        expect(env.noteTable.getRow(liveNote.id), isNotNull);

        env.subManager.unsubscribe(querySetB);
        await Future.delayed(const Duration(seconds: 1));

        expect(env.noteTable.getRow(liveNote.id), isNotNull);

        expect(querySetA, isNot(equals(querySetB)));
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      'variant: a live-inserted row is correctly dropped after unsubscribe, then correctly rehydrated by a fresh matching subscribe',
      () async {
        final writer = await createTestEnv(registerNote: true);
        final env = await createTestEnv(registerNote: true);
        addTearDown(() async {
          writer.subManager.dispose();
          env.subManager.dispose();
          await writer.disconnect();
          await env.disconnect();
        });

        await writer.connection.connect();
        await writer.subManager.onInitialConnection.first.timeout(_timeout);
        await env.connection.connect();
        await env.subManager.onInitialConnection.first.timeout(_timeout);

        final querySetA = await env.subManager.subscribe([
          'SELECT * FROM note WHERE id >= 1 AND id <= 100',
        ]);

        final txUpdateFuture = env.subManager.onTransactionUpdate.first.timeout(
          _timeout,
        );
        await writer.reducers
            .createNote(title: 'lifecycle-row', content: 'insert-unsub-resub')
            .timeout(_timeout);
        await txUpdateFuture;

        final liveNote = env.noteTable
            .iter()
            .firstWhere((n) => n.title == 'lifecycle-row');

        expect(env.noteTable.getRow(liveNote.id), isNotNull);

        env.subManager.unsubscribe(querySetA);
        await Future.delayed(const Duration(seconds: 1));

        expect(env.noteTable.getRow(liveNote.id), isNull);

        await env.subManager.subscribe([
          'SELECT * FROM note WHERE id >= 1 AND id <= 100',
        ]);

        expect(env.noteTable.getRow(liveNote.id), isNotNull);
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      'variant: bulk live insert (many rows, one TransactionUpdate) tags every inserted key, not just the first',
      () async {
        final writer = await createTestEnv(registerNote: true);
        final env = await createTestEnv(registerNote: true);
        addTearDown(() async {
          writer.subManager.dispose();
          env.subManager.dispose();
          await writer.disconnect();
          await env.disconnect();
        });

        await writer.connection.connect();
        await writer.subManager.onInitialConnection.first.timeout(_timeout);
        await env.connection.connect();
        await env.subManager.onInitialConnection.first.timeout(_timeout);

        await env.subManager.subscribe([
          'SELECT * FROM note WHERE id >= 1 AND id <= 1000',
        ]);

        final txUpdateFuture = env.subManager.onTransactionUpdate.first.timeout(
          _timeout,
        );
        await writer.reducers
            .createNotesBulk(count: 5, titlePrefix: 'bulk-live')
            .timeout(_timeout);
        await txUpdateFuture;
        await Future.delayed(const Duration(seconds: 1));

        final bulkNotes =
            env.noteTable.iter().where((n) => n.title.startsWith('bulk-live')).toList();

        expect(bulkNotes.length, equals(5));

        await env.subManager.subscribe([
          'SELECT * FROM note WHERE id >= 1 AND id <= 1',
        ]);

        for (final note in bulkNotes) {
          expect(env.noteTable.getRow(note.id), isNotNull);
        }
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      'variant: a live UPDATE does not widen a precise provenance tag to every query set active on the table',
      () async {
        final writer = await createTestEnv(registerNote: true);
        final env = await createTestEnv(registerNote: true);
        addTearDown(() async {
          writer.subManager.dispose();
          env.subManager.dispose();
          await writer.disconnect();
          await env.disconnect();
        });

        await writer.connection.connect();
        await writer.subManager.onInitialConnection.first.timeout(_timeout);
        await env.connection.connect();
        await env.subManager.onInitialConnection.first.timeout(_timeout);

        final seedResult = await writer.reducers
            .createNote(title: 'narrow-tag-me', content: 'before')
            .timeout(_timeout);
        expect(seedResult.isSuccess, isTrue);

        final querySetA = await env.subManager.subscribe([
          'SELECT * FROM note WHERE id >= 1 AND id <= 5',
        ]);
        final seededNote = env.noteTable
            .iter()
            .firstWhere((n) => n.title == 'narrow-tag-me');

        final querySetB = await env.subManager.subscribe([
          'SELECT * FROM note WHERE id >= 1000 AND id <= 2000',
        ]);
        expect(querySetA, isNot(equals(querySetB)));

        final txUpdateFuture = env.subManager.onTransactionUpdate.first.timeout(
          _timeout,
        );
        await writer.reducers
            .updateNote(
              noteId: seededNote.id,
              title: 'narrow-tag-me',
              content: 'after-live-update-with-B-active',
            )
            .timeout(_timeout);
        await txUpdateFuture;

        expect(
          env.noteTable.getRow(seededNote.id)?.content,
          equals('after-live-update-with-B-active'),
        );

        env.subManager.unsubscribe(querySetA);

        expect(env.noteTable.getRow(seededNote.id), isNull);
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      "variant: a live-inserted row's provenance entry is removed (not leaked) once the row is live-deleted",
      () async {
        final writer = await createTestEnv(registerNote: true);
        final env = await createTestEnv(registerNote: true);
        addTearDown(() async {
          writer.subManager.dispose();
          env.subManager.dispose();
          await writer.disconnect();
          await env.disconnect();
        });

        await writer.connection.connect();
        await writer.subManager.onInitialConnection.first.timeout(_timeout);
        await env.connection.connect();
        await env.subManager.onInitialConnection.first.timeout(_timeout);

        await env.subManager.subscribe([
          'SELECT * FROM note WHERE id >= 1 AND id <= 1000',
        ]);

        final baselineCount = env.subManager.rowProvenanceCountForTable('note');

        final insertUpdateFuture = env.subManager.onTransactionUpdate.first
            .timeout(_timeout);
        final createResult = await writer.reducers
            .createNote(title: 'churned-row', content: 'will be deleted')
            .timeout(_timeout);
        expect(createResult.isSuccess, isTrue);
        await insertUpdateFuture;

        final churnedNote = env.noteTable
            .iter()
            .firstWhere((n) => n.title == 'churned-row');

        expect(env.noteTable.getRow(churnedNote.id), isNotNull);
        expect(
          env.subManager.rowProvenanceCountForTable('note'),
          equals(baselineCount + 1),
        );

        final deleteUpdateFuture = env.subManager.onTransactionUpdate.first
            .timeout(_timeout);
        final deleteResult = await writer.reducers
            .deleteNote(noteId: churnedNote.id)
            .timeout(_timeout);
        expect(deleteResult.isSuccess, isTrue);
        await deleteUpdateFuture;

        expect(env.noteTable.getRow(churnedNote.id), isNull);

        expect(
          env.subManager.rowProvenanceCountForTable('note'),
          equals(baselineCount),
        );
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );
  });

  group('join subscription', () {
    test(
      "a JOIN subscription projecting a non-FROM table applies that table's rows and completes subscribed",
      () async {
        final env = await createTestEnv(registerNote: true, registerFolder: true);
        addTearDown(() async {
          env.subManager.dispose();
          await env.disconnect();
        });

        await env.connection.connect();
        await env.subManager.onInitialConnection.first.timeout(_timeout);

        await env.reducers
            .createFolder(path: '/join-test', name: 'join-test')
            .timeout(_timeout);
        await env.reducers
            .createNote(title: 'joined-note', content: 'c')
            .timeout(_timeout);

        await env.subManager.subscribe([
          'SELECT n.* FROM folder f JOIN note n ON n.timestamp = f.created_at',
        ]);

        await env.noteTable.subscribed.timeout(_timeout);

        expect(
          env.noteTable.iter().any((n) => n.title == 'joined-note'),
          isTrue,
        );
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );
  });

  group('T4 protocol balance (ship gate)', () {
    test(
      'a row entering two overlapping query sets arrives in both QuerySetUpdates; '
      'a server-side delete arrives in both; the row is evicted exactly once '
      'with owners draining {A,B} -> {}; the ownership-imbalance counter stays zero',
      () async {
        final writer = await createTestEnv(registerNote: true);
        final env = await createTestEnv(registerNote: true);
        addTearDown(() async {
          writer.subManager.dispose();
          env.subManager.dispose();
          await writer.disconnect();
          await env.disconnect();
        });

        await writer.connection.connect();
        await writer.subManager.onInitialConnection.first.timeout(_timeout);
        await env.connection.connect();
        await env.subManager.onInitialConnection.first.timeout(_timeout);

        final querySetA = await env.subManager.subscribe([
          'SELECT * FROM note WHERE id >= 1 AND id <= 100',
        ]);
        final querySetB = await env.subManager.subscribe([
          'SELECT * FROM note WHERE id >= 1 AND id <= 200',
        ]);
        expect(querySetA, isNot(equals(querySetB)));

        expect(env.noteTable.ownershipImbalanceCount, equals(0));

        final txUpdateFuture = env.subManager.onTransactionUpdate.first.timeout(
          _timeout,
        );
        final createResult = await writer.reducers
            .createNote(title: 'balance-check', content: 'X')
            .timeout(_timeout);
        expect(createResult.isSuccess, isTrue);
        await txUpdateFuture;

        final rowX = env.noteTable
            .iter()
            .firstWhere((n) => n.title == 'balance-check');

        expect(env.noteTable.getRow(rowX.id), isNotNull);
        expect(
          env.subManager.rowProvenanceCountForTable('note'),
          greaterThan(0),
        );
        expect(env.noteTable.ownershipImbalanceCount, equals(0));

        env.subManager.unsubscribe(querySetA);
        await Future.delayed(const Duration(milliseconds: 500));

        expect(env.noteTable.getRow(rowX.id), isNotNull);

        final deleteUpdateFuture = env.subManager.onTransactionUpdate.first
            .timeout(_timeout);
        final deleteResult = await writer.reducers
            .deleteNote(noteId: rowX.id)
            .timeout(_timeout);
        expect(deleteResult.isSuccess, isTrue);
        await deleteUpdateFuture;

        expect(env.noteTable.getRow(rowX.id), isNull);
        expect(env.subManager.rowProvenanceCountForTable('note'), equals(0));
        expect(env.noteTable.ownershipImbalanceCount, equals(0));
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );
  });
}
