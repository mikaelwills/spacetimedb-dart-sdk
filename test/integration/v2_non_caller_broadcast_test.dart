import 'package:test/test.dart';
import '../generated/note.dart';
import '../helpers/integration_test_helper.dart';
import '../helpers/test_env.dart';

/// Verifies v2 non-caller `TransactionUpdate` broadcast decodes end-to-end
/// against a live server.
///
/// Under v2, a client never sees their own write come back as a
/// `TransactionUpdate` — that message is strictly for OTHER connections to
/// observe remote changes. To exercise the decoder we need a two-connection
/// setup: connection A writes, connection B (subscribed to the same query)
/// receives the broadcast.
///
/// This is the only code path in the SDK that decodes a
/// `TransactionUpdateMessage` from real server bytes. Every other decoder is
/// covered by the main integration suite; this test closes the final gap.
void main() {
  setUpAll(ensureTestEnvironment);
  tearDownAll(cleanupTestEnvironment);

  test(
    'connection B receives TransactionUpdate when connection A writes',
    () async {
      final envA = await createTestEnv();
      final envB = await createTestEnv();

      await envA.connection.connect();
      await envA.subManager.onInitialConnection.first.timeout(
        const Duration(seconds: 5),
      );

      await envB.connection.connect();
      await envB.subManager.onInitialConnection.first.timeout(
        const Duration(seconds: 5),
      );

      await envB.subManager.subscribe(['SELECT * FROM note']);
      final tableB = envB.subManager.cache.getTableByTypedName<Note>('note');

      final txUpdateFuture = envB.subManager.onTransactionUpdate.first;
      final countBefore = tableB.count();

      await envA.reducers
          .createNote(
            title: 'Broadcast Test',
            content: 'Written by connection A, observed by connection B',
          )
          .timeout(const Duration(seconds: 5));

      final txUpdate = await txUpdateFuture.timeout(const Duration(seconds: 5));

      expect(
        txUpdate.querySets,
        isNotEmpty,
        reason:
            'v2 TransactionUpdate must carry at least one QuerySetUpdate for '
            'the subscribed set',
      );

      final tables = txUpdate.querySets.expand((qs) => qs.tables).toList();
      expect(
        tables.any((t) => t.tableName == 'note'),
        isTrue,
        reason: 'broadcast should reference the `note` table',
      );

      final noteRows = tables.firstWhere((t) => t.tableName == 'note');
      expect(
        noteRows.rows,
        isNotEmpty,
        reason: 'TableUpdate must contain row-groups',
      );

      expect(
        tableB.count(),
        equals(countBefore + 1),
        reason:
            'Connection B\'s local cache must reflect the new row from the '
            'broadcast',
      );

      final inserted = tableB.iter().any((n) => n.title == 'Broadcast Test');
      expect(inserted, isTrue);

      envA.subManager.dispose();
      envB.subManager.dispose();
      await envA.disconnect();
      await envB.disconnect();
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'connection B drops a row LIVE when connection A deletes it (remote delete propagates)',
    () async {
      // Mirrors the recent-notes regression: another client (or the MCP)
      // deletes a note server-side; a running, subscribed client must remove it
      // from its live cache without a restart/reconnect.
      final envA = await createTestEnv();
      final envB = await createTestEnv();
      addTearDown(() async {
        envA.subManager.dispose();
        envB.subManager.dispose();
        await envA.disconnect();
        await envB.disconnect();
      });

      await envA.connection.connect();
      await envA.subManager.onInitialConnection.first.timeout(
        const Duration(seconds: 5),
      );
      await envB.connection.connect();
      await envB.subManager.onInitialConnection.first.timeout(
        const Duration(seconds: 5),
      );

      await envB.subManager.subscribe(['SELECT * FROM note']);
      final tableB = envB.subManager.cache.getTableByTypedName<Note>('note');

      // A creates a note; B observes it live via broadcast.
      await envA.reducers
          .createNote(title: 'Doomed', content: 'delete me live')
          .timeout(const Duration(seconds: 5));
      await Future.delayed(const Duration(seconds: 1));

      final doomed = tableB.iter().firstWhere((n) => n.title == 'Doomed');
      expect(
        tableB.getRow(doomed.id),
        isNotNull,
        reason: 'precondition: B sees the row before the remote delete',
      );

      // A deletes it. B must drop it from the live cache — no reconnect.
      await envA.reducers
          .deleteNote(noteId: doomed.id)
          .timeout(const Duration(seconds: 5));
      await Future.delayed(const Duration(seconds: 1));

      expect(
        tableB.getRow(doomed.id),
        isNull,
        reason:
            'a remote delete must propagate to a subscribed client\'s live '
            'cache via TransactionUpdate — not require an app restart',
      );
      expect(
        tableB.iter().any((n) => n.title == 'Doomed'),
        isFalse,
        reason: 'the deleted row must be gone from rows/iter as well',
      );
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
