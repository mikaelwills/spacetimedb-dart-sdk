import 'dart:async';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:spacetimedb_dart_sdk/spacetimedb_dart_sdk.dart';
import '../helpers/integration_test_helper.dart';

void main() {
  setUpAll(ensureTestEnvironment);
  tearDownAll(cleanupTestEnvironment);

  const testHost = 'localhost:3000';
  const testDatabase = 'notesdb';

  Future<void> waitForState<T extends ConnectionState>(
    SpacetimeDbConnection connection, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    if (connection.state is T) return;
    await connection.onStateChanged
        .firstWhere((state) => state is T)
        .timeout(
          timeout,
          onTimeout: () {
            throw TimeoutException(
              'Timed out waiting for state $T. Current: ${connection.state}',
            );
          },
        );
  }

  group('Connection State Machine', () {
    late SpacetimeDbConnection connection;

    setUp(() {
      connection = SpacetimeDbConnection(
        host: testHost,
        database: testDatabase,
        config: const ConnectionConfig(
          maxReconnectAttempts: 3,
          baseReconnectDelay: Duration(milliseconds: 100),
          pingInterval: Duration(seconds: 2),
          pongTimeout: Duration(milliseconds: 500),
        ),
      );
    });

    tearDown(() async {
      await connection.dispose();
    });

    test(
      'connect() transitions: disconnected -> connecting -> connected',
      () async {
        final states = <ConnectionState>[];

        final sub = connection.onStateChanged.listen(states.add);

        try {
          await connection.connect();
          await waitForState<Connected>(connection);

          expect(connection.isConnected, true);
          expect(states.any((s) => s is Connecting), true);
          expect(states.any((s) => s is Connected), true);
        } finally {
          await sub.cancel();
        }
      },
    );

    test('disconnect() cleanly closes connection', () async {
      await connection.connect();
      await waitForState<Connected>(connection);

      await connection.disconnect();
      await waitForState<Disconnected>(connection);

      expect(connection.isConnected, false);
    });

    test('Manual reconnect() works', () async {
      await connection.connect();
      await waitForState<Connected>(connection);

      await connection.reconnect();
      await waitForState<Connected>(connection);

      expect(connection.isConnected, true);
    });
  });

  group('Keep-Alive & Protocol', () {
    late SpacetimeDbConnection connection;

    setUp(() {
      connection = SpacetimeDbConnection(
        host: testHost,
        database: testDatabase,
      );
    });

    tearDown(() async => await connection.dispose());

    test('Server responds to Keep-Alive Probe (Intentional Error)', () async {
      await connection.connect();
      await waitForState<Connected>(connection);

      const pingQuery = 'SELECT * FROM __spacetime_dart_sdk_keepalive__';

      final messageId = Uint8List.fromList(List.filled(16, 0xDD));

      final message = OneOffQueryMessage(
        messageId: messageId,
        queryString: pingQuery,
      );

      final responseFuture = connection.onMessage
          .map(MessageDecoder.decode)
          .where((msg) => msg is OneOffQueryResponse)
          .cast<OneOffQueryResponse>()
          .where((msg) => _listEquals(msg.messageId, messageId))
          .first
          .timeout(const Duration(seconds: 10));

      connection.send(message.encode());

      final response = await responseFuture;

      expect(
        response.error,
        isNotNull,
        reason: 'Server should report table not found',
      );
      expect(
        response.error,
        anyOf(contains('not a valid table'), contains('no such table')),
        reason: 'Error should indicate table does not exist',
      );

      expect(connection.isConnected, true);
    });
  });

  group('Error & Retry Logic', () {
    test(
      'Connection to invalid host fails and allows retry',
      () async {
        final connection = SpacetimeDbConnection(
          host: 'invalid-host-name-xyz',
          database: 'db',
          config: const ConnectionConfig(
            autoReconnect: false,
            maxReconnectAttempts: 0,
          ),
        );

        try {
          try {
            await connection.connect();
          } catch (_) {}

          await waitForState<Disconnected>(
            connection,
            timeout: const Duration(seconds: 20),
          );

          expect(connection.state.canRetry, true);
          expect(connection.isConnected, false);
        } finally {
          await connection.dispose();
        }
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test('Connection to invalid database handles result', () async {
      final connection = SpacetimeDbConnection(
        host: testHost,
        database: 'INVALID_DB_${DateTime.now().millisecondsSinceEpoch}',
        config: const ConnectionConfig(
          autoReconnect: false,
          maxReconnectAttempts: 0,
        ),
      );

      try {
        try {
          await connection.connect();
        } catch (_) {}

        await waitForState<Disconnected>(
          connection,
          timeout: const Duration(seconds: 5),
        );

        expect(connection.state, isA<Disconnected>());
        expect(connection.isConnected, false);
      } finally {
        await connection.dispose();
      }
    });
  });
}

bool _listEquals(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
