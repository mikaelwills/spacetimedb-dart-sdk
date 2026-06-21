// ignore_for_file: avoid_print

import 'dart:async';

import 'package:test/test.dart';
import 'package:spacetimedb_sdk/protocol.dart';
import '../helpers/integration_test_helper.dart';
import '../helpers/test_env.dart';

const _timeout = Duration(seconds: 10);

void main() {
  setUpAll(ensureTestEnvironment);
  tearDownAll(cleanupTestEnvironment);

  setUp(() async {
    final cleaner = await createTestEnv(
      registerNote: true,
      registerFolder: true,
    );
    await cleaner.connection.connect();
    await cleaner.subManager.onInitialConnection.first.timeout(_timeout);
    await cleaner.reducers.deleteAllNotes().timeout(_timeout);
    await cleaner.reducers.deleteAllFolders().timeout(_timeout);
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

  group('Reconnect edge cases', () {
    test(
      'multiple query sets all rehydrate on one reconnect',
      () async {
        final envA = await createTestEnv(
          registerNote: true,
          registerFolder: true,
        );
        final envB = await createTestEnv(
          registerNote: true,
          registerFolder: true,
        );
        addTearDown(() async {
          envA.subManager.dispose();
          envB.subManager.dispose();
          await envA.disconnect();
          await envB.disconnect();
        });

        await envA.connection.connect();
        await envA.subManager.onInitialConnection.first.timeout(_timeout);
        await envB.connection.connect();
        await envB.subManager.onInitialConnection.first.timeout(_timeout);

        await envA.subManager.subscribe(['SELECT * FROM note']);
        await envA.subManager.subscribe(['SELECT * FROM folder']);
        final noteBefore = envA.noteTable.count();
        final folderBefore = envA.folderTable.count();

        await envA.connection.disconnect();
        await waitForState<Disconnected>(envA.connection);

        await envB.reducers
            .createNote(title: 'multiset-note', content: 'n')
            .timeout(_timeout);
        await envB.reducers
            .createFolder(path: '/multiset-folder', name: 'f')
            .timeout(_timeout);

        await envA.connection.reconnect();
        await waitForState<Connected>(envA.connection);
        await Future.delayed(const Duration(seconds: 2));

        expect(
          envA.noteTable.count(),
          equals(noteBefore + 1),
          reason: 'note query set must rehydrate on reconnect',
        );
        expect(
          envA.folderTable.count(),
          equals(folderBefore + 1),
          reason: 'folder query set must ALSO rehydrate on the same reconnect',
        );
        expect(
          envA.noteTable.iter().any((n) => n.title == 'multiset-note'),
          isTrue,
        );
        expect(
          envA.folderTable.iter().any((f) => f.path == '/multiset-folder'),
          isTrue,
        );
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      'rows deleted on the server during the disconnect are removed on reconnect',
      () async {
        final envA = await createTestEnv();
        final envB = await createTestEnv();
        addTearDown(() async {
          envA.subManager.dispose();
          envB.subManager.dispose();
          await envA.disconnect();
          await envB.disconnect();
        });

        await envA.connection.connect();
        await envA.subManager.onInitialConnection.first.timeout(_timeout);
        await envB.connection.connect();
        await envB.subManager.onInitialConnection.first.timeout(_timeout);

        await envB.reducers
            .createNote(title: 'doomed', content: 'delete-me')
            .timeout(_timeout);

        await envA.subManager.subscribe(['SELECT * FROM note']);
        final doomed = envA.noteTable.iter().firstWhere(
          (n) => n.title == 'doomed',
        );
        expect(
          envA.noteTable.getRow(doomed.id),
          isNotNull,
          reason: 'precondition: A sees the row before disconnect',
        );

        await envA.connection.disconnect();
        await waitForState<Disconnected>(envA.connection);

        await envB.reducers.deleteNote(noteId: doomed.id).timeout(_timeout);

        await envA.connection.reconnect();
        await waitForState<Connected>(envA.connection);
        await Future.delayed(const Duration(seconds: 2));

        expect(
          envA.noteTable.getRow(doomed.id),
          isNull,
          reason:
              'a row deleted on the server during the disconnect must be gone '
              'from the cache after reconnect — the snapshot reconcile must '
              'propagate deletes, not only inserts',
        );
        expect(envA.noteTable.iter().any((n) => n.title == 'doomed'), isFalse);
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      'reconnect with zero active subscriptions does not throw and reconnects',
      () async {
        final envA = await createTestEnv();
        addTearDown(() async {
          envA.subManager.dispose();
          await envA.disconnect();
        });

        await envA.connection.connect();
        await envA.subManager.onInitialConnection.first.timeout(_timeout);

        await envA.connection.disconnect();
        await waitForState<Disconnected>(envA.connection);

        await envA.connection.reconnect();
        await waitForState<Connected>(envA.connection);

        expect(
          envA.connection.isConnected,
          isTrue,
          reason: 'reconnect with no tracked query sets must still connect',
        );
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );
  });
}
