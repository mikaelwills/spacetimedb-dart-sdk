import 'package:spacetimedb_sdk/codegen.dart';
import 'package:spacetimedb_sdk/src/connection/spacetimedb_connection.dart'
    show closeForReconnect;
import 'package:test/test.dart';

import '../generated/client.dart';
import '../helpers/integration_test_helper.dart';
import '../helpers/test_jwt.dart';

const _timeout = Duration(seconds: 10);

void main() {
  setUpAll(ensureTestEnvironment);
  tearDownAll(cleanupTestEnvironment);

  test(
    'a token the server rejects on reconnect is replaced through the '
    'provider, and the provided token is persisted',
    timeout: const Timeout(Duration(seconds: 60)),
    () async {
      final store = InMemoryTokenStore();
      String? goodToken;
      var providerCalls = 0;
      final client = await SpacetimeDbClient.create(
        host: 'localhost:3000',
        database: 'notesdb',
        authStorage: store,
        config: const ConnectionConfig(
          baseReconnectDelay: Duration(milliseconds: 50),
          maxReconnectDelay: Duration(milliseconds: 50),
        ),
        tokenProvider: () async {
          providerCalls++;
          return goodToken!;
        },
      );
      addTearDown(client.disconnect);
      final states = <ConnectionState>[];
      client.connection.onStateChanged.listen(states.add);

      await client.connect();
      await client.subscriptions.onInitialConnection.first.timeout(_timeout);
      goodToken = await store.loadToken();
      final identity = client.identity;
      expect(goodToken, isNotNull);

      final now = DateTime.now();
      final forged = testJwt({
        'iss': 'forged',
        'sub': 'forged',
        'iat': epochSeconds(now),
        'exp': epochSeconds(now.add(const Duration(hours: 1))),
      });
      client.connection.updateToken(forged);
      await store.saveToken(forged);

      final reconnected = client.subscriptions.onInitialConnection.first
          .timeout(_timeout);
      closeForReconnect(client.connection, 'test: force a reconnect');
      await reconnected;

      expect(providerCalls, 1);
      expect(states.whereType<AuthError>(), isEmpty);
      expect(client.connection.state, isA<Connected>());
      expect(client.connection.token, goodToken);
      expect(await store.loadToken(), goodToken);
      expect(client.identity, identity);
    },
  );
}
