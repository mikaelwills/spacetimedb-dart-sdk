import 'dart:async';
import 'package:test/test.dart';
import 'package:spacetimedb_sdk/protocol.dart';
import '../helpers/integration_test_helper.dart';
import '../helpers/test_env.dart';

/// PROBE (certainty stage) — provoke the resubscribe-non-convergence claim.
///
/// Claim under test (instructions #2/#3):
///  - A disconnect firing while _onReconnected() awaits subscribe() resolves the
///    waiter WITHOUT a SubscribeApplied, guard at line 389 fails,
///    subscriptionsReady stays false, and the query set is retained in the map.
///  - On the NEXT Connected, whether the set is re-applied decides convergence.
///
/// This is NOT a fix; it establishes the empirical facts the fix pivots on.
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
          onTimeout:
              () =>
                  throw TimeoutException(
                    'Timed out waiting for state $T. Current: ${connection.state}',
                  ),
        );
  }

  test(
    'PROBE: map retains set after interrupted resubscribe; next reconnect converges',
    () async {
      final env = await createTestEnv();
      await env.connection.connect();
      await env.subManager.onInitialConnection.first.timeout(
        const Duration(seconds: 5),
      );

      // Establish an active subscription so _onReconnected has a set to replay.
      await env.subManager.subscribe(['SELECT * FROM note']);
      expect(
        env.subManager.subscriptionsByQuerySetId,
        isNotEmpty,
        reason: 'baseline: one active query set',
      );
      expect(
        env.subManager.subscriptionsReady.value,
        isTrue,
        reason: 'baseline: ready after initial SubscribeApplied',
      );

      // --- Interrupt a resubscribe mid-flight ---
      // reconnect() -> disconnect(); connect(). The subsequent Connected fires
      // _onReconnected which clears+replays the set. We slam a disconnect right
      // after to try to catch the resubscribe before its SubscribeApplied lands.
      // On a clean local server the apply is fast, so we may or may not win the
      // race; either way we assert the load-bearing invariants below.
      await env.connection.reconnect();
      // Do NOT await Connected/apply — disconnect immediately.
      await env.connection.disconnect();
      await waitForState<Disconnected>(env.connection);

      // OBSERVATION A (C3 / claim 2a): record whether the set survives in the
      // map across a disconnect-flushed resubscribe. Do NOT hard-fail — we want
      // to observe convergence (C) regardless of this branch.
      final mapEmptyAfterInterrupt =
          env.subManager.subscriptionsByQuerySetId.isEmpty;
      // ignore: avoid_print
      print(
        'PROBE OBSERVATION A: map empty after interrupt = '
        '$mapEmptyAfterInterrupt',
      );

      // INVARIANT B: while disconnected, ready is false.
      expect(
        env.subManager.subscriptionsReady.value,
        isFalse,
        reason: 'ready latches false on Disconnected',
      );

      // --- Now allow a clean reconnect and observe convergence (claim 2b) ---
      await env.connection.connect();
      await waitForState<Connected>(env.connection);

      // Give _onReconnected time to replay the retained set and apply.
      final converged = await _waitReady(
        env.subManager,
        timeout: const Duration(seconds: 10),
      );

      // ignore: avoid_print
      print(
        'PROBE OBSERVATION C: converged after clean reconnect = $converged; '
        'map now = ${env.subManager.subscriptionsByQuerySetId}',
      );

      // INVARIANT C (claim 2b): the set IS re-applied on the next Connected and
      // subscriptionsReady returns to true. If this is FALSE, the
      // "never converges / retry is lost" branch is REAL (the load-bearing bug).
      expect(
        converged,
        isTrue,
        reason:
            'CLAIM 2b: after a clean reconnect following an interrupted one, '
            'the set must be re-applied and ready must recover to true. '
            'mapEmptyAfterInterrupt=$mapEmptyAfterInterrupt',
      );

      env.subManager.dispose();
      await env.disconnect();
    },
    timeout: const Timeout(Duration(seconds: 45)),
  );

  test(
    'PROBE branch-A: disconnect AFTER subscribe re-registers -> map non-empty',
    () async {
      final env = await createTestEnv();
      await env.connection.connect();
      await env.subManager.onInitialConnection.first.timeout(
        const Duration(seconds: 5),
      );
      await env.subManager.subscribe(['SELECT * FROM note']);

      // reconnect, then let the Connected listener + _onReconnected reach the
      // subscribe() await (line 165 re-registers) BEFORE we disconnect. A tiny
      // yield lets the state listener microtask run the loop body.
      final reconnectFuture = env.connection.reconnect();
      await reconnectFuture;
      // At this point Connected has fired and _onReconnected is likely awaiting
      // subscribe()'s SubscribeApplied — line 165 has re-added the set.
      final mapDuringInflight = Map.of(
        env.subManager.subscriptionsByQuerySetId,
      );
      // ignore: avoid_print
      print(
        'PROBE branch-A: map during in-flight resubscribe = '
        '$mapDuringInflight',
      );

      // Now interrupt.
      await env.connection.disconnect();
      await waitForState<Disconnected>(env.connection);
      // ignore: avoid_print
      print(
        'PROBE branch-A: map after post-subscribe interrupt = '
        '${env.subManager.subscriptionsByQuerySetId}',
      );

      env.subManager.dispose();
      await env.disconnect();
    },
    timeout: const Timeout(Duration(seconds: 45)),
  );
}

Future<bool> _waitReady(dynamic subManager, {required Duration timeout}) async {
  final ready = subManager.subscriptionsReady;
  if (ready.value == true) return true;
  final completer = Completer<bool>();
  void listener() {
    if (ready.value == true && !completer.isCompleted) {
      completer.complete(true);
    }
  }

  ready.addListener(listener);
  try {
    return await completer.future.timeout(timeout, onTimeout: () => false);
  } finally {
    ready.removeListener(listener);
  }
}
