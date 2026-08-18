import 'package:test/test.dart';
import 'package:spacetimedb_sdk/spacetimedb_sdk.dart';

import '../../mocks/silent_socket.dart';

void main() {
  group('retryInitialConnect', () {
    late int factoryCalls;
    late SilentWebSocketChannel? socket;

    SpacetimeDbConnection build(
      ConnectionConfig config, {
      required int failTimes,
    }) {
      factoryCalls = 0;
      socket = null;
      return SpacetimeDbConnection(
        host: 'localhost:3000',
        database: 'notesdb',
        config: config,
        socketFactory: (
          uri,
          protocols,
          headers, {
          connectTimeout = const Duration(seconds: 10),
          pingInterval,
        }) {
          factoryCalls++;
          if (factoryCalls <= failTimes) {
            throw Exception('simulated connect failure $factoryCalls');
          }
          socket = SilentWebSocketChannel();
          return socket!;
        },
      );
    }

    test(
      'disabled (default): a failed initial connect throws after ONE attempt '
      'and never retries',
      () async {
        final connection = build(
          const ConnectionConfig(
            autoReconnect: false,
            baseReconnectDelay: Duration(milliseconds: 10),
            maxReconnectDelay: Duration(milliseconds: 10),
            maxReconnectAttempts: 5,
          ),
          failTimes: 2,
        );
        addTearDown(connection.dispose);

        await expectLater(
          connection.connect(),
          throwsA(isA<SpacetimeDbConnectionException>()),
        );

        expect(
          factoryCalls,
          equals(1),
          reason: 'without the flag the SDK must not retry the initial connect',
        );
      },
    );

    test(
      'enabled: a failed initial connect is retried until it succeeds',
      () async {
        final connection = build(
          const ConnectionConfig(
            autoReconnect: false,
            baseReconnectDelay: Duration(milliseconds: 10),
            maxReconnectDelay: Duration(milliseconds: 10),
            maxReconnectAttempts: 5,
            retryInitialConnect: true,
          ),
          failTimes: 2,
        );
        addTearDown(connection.dispose);

        await connection.connect();

        expect(
          connection.isConnected,
          isTrue,
          reason: 'the third attempt should have connected',
        );
        expect(factoryCalls, equals(3));
      },
    );

    test('enabled: terminal failure is still observable once attempts are '
        'exhausted', () async {
      final connection = build(
        const ConnectionConfig(
          autoReconnect: false,
          baseReconnectDelay: Duration(milliseconds: 10),
          maxReconnectDelay: Duration(milliseconds: 10),
          maxReconnectAttempts: 3,
          retryInitialConnect: true,
        ),
        failTimes: 99,
      );
      addTearDown(connection.dispose);

      await expectLater(
        connection.connect(),
        throwsA(isA<Exception>()),
        reason: 'a consumer must still be able to observe giving up',
      );

      expect(factoryCalls, equals(3));
      expect(connection.state, isA<FatalError>());
    });

    test('enabled: an auth failure is NOT retried', () async {
      var calls = 0;
      final connection = SpacetimeDbConnection(
        host: 'localhost:3000',
        database: 'notesdb',
        config: const ConnectionConfig(
          autoReconnect: false,
          baseReconnectDelay: Duration(milliseconds: 10),
          maxReconnectDelay: Duration(milliseconds: 10),
          maxReconnectAttempts: 5,
          retryInitialConnect: true,
        ),
        socketFactory: (
          uri,
          protocols,
          headers, {
          connectTimeout = const Duration(seconds: 10),
          pingInterval,
        }) {
          calls++;
          throw Exception('HTTP 401 Unauthorized');
        },
      );
      addTearDown(connection.dispose);

      await expectLater(
        connection.connect(),
        throwsA(isA<SpacetimeDbAuthException>()),
      );

      expect(
        calls,
        equals(1),
        reason: 'retrying a 401 would just burn attempts on a bad token',
      );
    });
  });
}
