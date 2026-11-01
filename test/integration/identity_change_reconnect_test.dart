import 'package:spacetimedb_sdk/codegen.dart';
import 'package:spacetimedb_sdk/src/connection/spacetimedb_connection.dart'
    show closeForReconnect;
import 'package:spacetimedb_sdk/src/messages/server_messages.dart'
    show InitialConnectionMessage;
import 'package:test/test.dart';

import '../helpers/integration_test_helper.dart';
import '../helpers/test_env.dart';

const _timeout = Duration(seconds: 10);

Future<InitialConnectionMessage> _connect(TestEnv env) async {
  final received = env.subManager.onInitialConnection.first.timeout(_timeout);
  await env.connection.connect();
  return received;
}

Future<void> _reconnect(TestEnv env) async {
  final reconnected = env.connection.onStateChanged
      .where((state) => state is Connected)
      .first
      .timeout(_timeout);
  closeForReconnect(env.connection, 'test: force a reconnect');
  await reconnected;
}

void main() {
  setUpAll(ensureTestEnvironment);
  tearDownAll(cleanupTestEnvironment);

  test('a reconnect with its own token keeps the identity and stays '
      'connected', () async {
    final env = await createTestEnv();
    addTearDown(env.disconnect);
    final first = await _connect(env);
    env.connection.updateToken(first.token);
    final identity = env.subManager.identity;

    final received = env.subManager.onInitialConnection.first.timeout(_timeout);
    await _reconnect(env);
    await received;

    expect(env.connection.state, isA<Connected>());
    expect(env.subManager.identity, identity);
  });

  test('a reconnect with another identity\'s token ends in FatalError and '
      'keeps the old identity', () async {
    final env = await createTestEnv();
    addTearDown(env.disconnect);
    final other = await createTestEnv();
    addTearDown(other.disconnect);
    final first = await _connect(env);
    env.connection.updateToken(first.token);
    final otherToken = (await _connect(other)).token;
    final identity = env.subManager.identity;
    expect(other.subManager.identity, isNot(identity));

    final stopped = env.connection.onStateChanged
        .firstWhere((state) => state is FatalError)
        .timeout(_timeout);
    env.connection.updateToken(otherToken);
    await _reconnect(env);
    final state = await stopped;

    expect((state as FatalError).message, contains('different identity'));
    expect(env.subManager.identity, identity);
    await Future<void>.delayed(const Duration(seconds: 2));
    expect(env.connection.state, isA<FatalError>());
  });
}
