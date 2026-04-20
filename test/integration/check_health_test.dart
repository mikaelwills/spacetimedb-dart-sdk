library;

// ignore_for_file: avoid_print
import 'package:test/test.dart';
import '../helpers/integration_test_helper.dart';
import '../helpers/test_env.dart';

/// Exercises the new `SubscriptionManager.checkHealth()` probe.
///
/// Three scenarios:
/// 1. Healthy connection → returns `true`.
/// 2. Disconnected connection → returns `false` without hanging.
/// 3. Server is reachable but unresponsive (simulated by disposing the
///    SubscriptionManager so incoming messages are dropped) → returns
///    `false` within timeout. This mirrors the iOS-suspended-socket case
///    where writes succeed but reads are dead.
void main() {
  setUpAll(ensureTestEnvironment);
  tearDownAll(cleanupTestEnvironment);

  test('checkHealth returns true on a live connection', () async {
    final env = await createTestEnv();
    await env.connection.connect();
    await env.subManager.onInitialConnection.first;

    final start = DateTime.now();
    final ok = await env.subManager.checkHealth();
    final elapsed = DateTime.now().difference(start);

    print(
      'checkHealth on live connection: ok=$ok elapsed=${elapsed.inMilliseconds}ms',
    );
    expect(ok, isTrue);

    await env.disconnect();
  });

  test('checkHealth returns false when not connected', () async {
    final env = await createTestEnv();
    // Do NOT call connect().

    final start = DateTime.now();
    final ok = await env.subManager.checkHealth();
    final elapsed = DateTime.now().difference(start);

    print(
      'checkHealth on disconnected conn: ok=$ok elapsed=${elapsed.inMilliseconds}ms',
    );
    expect(ok, isFalse);
    expect(
      elapsed.inMilliseconds,
      lessThan(1000),
      reason: 'should short-circuit without waiting for timeout',
    );
  });

  test(
    'checkHealth returns false within timeout on silent dead socket',
    () async {
      // Scenario: client believes it's connected, but the server-side socket
      // is not responding. We simulate by closing the underlying channel
      // sink without going through disconnect() — the state will still read
      // Connected until the keepalive timer catches it.
      final env = await createTestEnv();
      await env.connection.connect();
      await env.subManager.onInitialConnection.first;

      // Grab a reference to the underlying ws channel, close its sink.
      // We reach into the private field via a small hack: directly kill
      // the write end by dispatching a reducer to something that forces
      // the server to drop us — or, simpler: just rely on `disconnect()`
      // then manually flip the state back to Connected for the check.
      //
      // Simplest repro: dispose the SubscriptionManager so the
      // oneOffQueryResult stream is closed. checkHealth should still
      // time out.
      env.subManager.dispose();

      const probeTimeout = Duration(seconds: 1);
      final start = DateTime.now();
      final ok = await env.subManager.checkHealth(timeout: probeTimeout);
      final elapsed = DateTime.now().difference(start);

      print(
        'checkHealth on disposed manager: ok=$ok elapsed=${elapsed.inMilliseconds}ms',
      );
      expect(ok, isFalse);
      expect(
        elapsed.inMilliseconds,
        lessThanOrEqualTo(1200),
        reason: 'should honour the timeout parameter',
      );

      await env.disconnect();
    },
  );
}
