import 'dart:async';
import 'package:test/test.dart';
import 'package:spacetimedb_sdk/protocol.dart';
import '../generated/note.dart';
import '../helpers/integration_test_helper.dart';
import '../helpers/test_env.dart';

/// Reproduces the reconnect-without-rehydration bug.
///
/// Symptom (observed in the SpaceNotes Flutter client): a chat message sent to
/// an agent while the phone is asleep is received and replied to, the reply row
/// lands in STDB, but the client's local cache never picks it up — the UI stays
/// stuck on the pre-disconnect snapshot until the app is force-quit and cold
/// started.
///
/// Mechanism under test: rows written to a subscribed table WHILE a client is
/// disconnected must appear in that client's cache after `connection.reconnect()`,
/// exactly as they would on a fresh cold `connect()`. The SDK's
/// `SubscriptionManager._onReconnected` re-sends the tracked query sets on
/// reconnect; this test asserts the resulting snapshot actually rehydrates the
/// cache.
///
/// Two-connection setup: A subscribes then drops; B writes while A is down; A
/// reconnects and must observe B's row.
void main() {
  setUpAll(ensureTestEnvironment);
  tearDownAll(cleanupTestEnvironment);

  Future<void> waitForState<T extends ConnectionState>(
    SpacetimeDbConnection connection, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    if (connection.state is T) return;
    await connection.onStateChanged
        .firstWhere((state) => state is T)
        .timeout(
          timeout,
          onTimeout: () => throw TimeoutException(
            'Timed out waiting for state $T. Current: ${connection.state}',
          ),
        );
  }

  test(
    'reconnect rehydrates rows written during the disconnect window',
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

      await envA.subManager.subscribe(['SELECT * FROM note']);
      final tableA = envA.noteTable;
      final countBefore = tableA.count();

      const marker = 'Written while A was disconnected';

      await envA.connection.disconnect();
      await waitForState<Disconnected>(envA.connection);

      await envB.reducers
          .createNote(title: marker, content: 'reply-while-asleep')
          .timeout(const Duration(seconds: 5));

      await envA.connection.reconnect();
      await waitForState<Connected>(envA.connection);

      await Future.delayed(const Duration(seconds: 2));

      expect(
        tableA.count(),
        equals(countBefore + 1),
        reason:
            'After reconnect, A\'s cache must include the row written while it '
            'was disconnected — same as a cold connect would deliver',
      );
      expect(
        tableA.iter().any((n) => n.title == marker),
        isTrue,
        reason: 'the specific row written during the disconnect must be present',
      );

      // Phase 2 — the real-world failure: after A reconnected, does its
      // re-subscribed query set still receive LIVE broadcasts? At runtime the
      // snapshot hydrated on reconnect but subsequent TransactionUpdates for
      // the re-subscribed set never arrived (agent replies sent after the
      // reconnect never showed). Write a fresh row from B and assert A sees it
      // live, with no further reconnect.
      const liveMarker = 'Broadcast AFTER A reconnected';
      final countAfterReconnect = tableA.count();

      await envB.reducers
          .createNote(title: liveMarker, content: 'live-post-reconnect')
          .timeout(const Duration(seconds: 5));

      await Future.delayed(const Duration(seconds: 2));

      expect(
        tableA.count(),
        equals(countAfterReconnect + 1),
        reason:
            'After reconnect, A\'s re-subscribed query set must still receive '
            'live TransactionUpdate broadcasts — not just the reconnect snapshot',
      );
      expect(
        tableA.iter().any((n) => n.title == liveMarker),
        isTrue,
        reason: 'the row broadcast after reconnect must reach A live',
      );

      envA.subManager.dispose();
      envB.subManager.dispose();
      await envA.disconnect();
      await envB.disconnect();
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
