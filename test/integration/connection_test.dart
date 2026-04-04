import 'dart:async';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:spacetimedb_dart_sdk/spacetimedb_dart_sdk.dart';

/// Integration tests for SpacetimeDB connection against REAL server
void main() {
  const testHost = 'localhost:3000';
  const testDatabase = 'notesdb';

  // Helper: Robustly wait for a state change
  Future<void> waitForState(
    SpacetimeDbConnection connection,
    ConnectionState targetState, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    if (connection.state == targetState) return;
    await connection.onStateChanged
        .firstWhere((state) => state == targetState)
        .timeout(
          timeout,
          onTimeout: () {
            throw TimeoutException(
              'Timed out waiting for state $targetState. Current: ${connection.state}',
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

        // Setup listener BEFORE action
        final sub = connection.onStateChanged.listen(states.add);

        try {
          await connection.connect();
          await waitForState(connection, ConnectionState.connected);

          expect(connection.isConnected, true);
          expect(states, contains(ConnectionState.connecting));
          expect(states, contains(ConnectionState.connected));
        } finally {
          await sub.cancel();
        }
      },
    );

    test('disconnect() cleanly closes connection', () async {
      await connection.connect();
      await waitForState(connection, ConnectionState.connected);

      await connection.disconnect();
      await waitForState(connection, ConnectionState.disconnected);

      expect(connection.isConnected, false);
    });

    test('Manual reconnect() works', () async {
      await connection.connect();
      await waitForState(connection, ConnectionState.connected);

      await connection.reconnect();
      // Reconnect triggers a disconnect/connect cycle.
      // We just need to ensure we end up connected.
      await waitForState(connection, ConnectionState.connected);

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
      await waitForState(connection, ConnectionState.connected);

      // We probe with a non-existent table name that serves as self-documenting "Ping"
      // The server returns an error, which proves it's alive and processing requests
      const pingQuery = 'SELECT * FROM __spacetime_dart_sdk_keepalive__';

      final messageId = Uint8List.fromList(List.filled(16, 0xDD));

      final message = OneOffQueryMessage(
        messageId: messageId,
        queryString: pingQuery,
      );

      // 1. Setup Future listener BEFORE sending
      final responseFuture = connection.onMessage
          .map(MessageDecoder.decode)
          // We explicitly want OneOffQueryResponse
          .where((msg) => msg is OneOffQueryResponse)
          .cast<OneOffQueryResponse>()
          // Match ID to ensure it's OUR ping
          .where((msg) => _listEquals(msg.messageId, messageId))
          .first
          .timeout(const Duration(seconds: 10));

      // 2. Send
      connection.send(message.encode());

      // 3. Await
      final response = await responseFuture;

      // 4. VERIFICATION: We EXPECT an error!
      // The error proves the server processed our request - the error IS the pong
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

      // If we got here, the Round Trip was successful
      expect(connection.isConnected, true);
    });
  });

  group('Error & Retry Logic', () {
    test(
      'Connection to invalid host fails and allows retry',
      () async {
        final connection = SpacetimeDbConnection(
          host: 'invalid-host-name-xyz', // Will cause DNS failure
          database: 'db',
          config: const ConnectionConfig(
            autoReconnect: false, // Disable auto so we settle on "Disconnected"
            maxReconnectAttempts: 0,
          ),
        );

        try {
          try {
            await connection.connect();
          } catch (_) {
            // Expected to throw exception immediately upon socket creation failure
          }

          // FIX: Increased timeout to 20s.
          // DNS resolution and TCP connection timeouts are handled by the OS/Dart runtime.
          // These often default to 10s-30s. A 5s test timeout is too optimistic for a failure case.
          await waitForState(
            connection,
            ConnectionState.disconnected,
            timeout: const Duration(seconds: 20),
          );

          // NOW it should be retryable
          expect(connection.status.canRetry, true);
          expect(connection.isConnected, false);
        } finally {
          await connection.dispose();
        }
      },
      timeout: const Timeout(Duration(seconds: 30)),
    ); // Test-level timeout

    test('Connection to invalid database handles result', () async {
      final connection = SpacetimeDbConnection(
        host: testHost,
        // Use a timestamp to ensure the DB definitely doesn't exist
        database: 'INVALID_DB_${DateTime.now().millisecondsSinceEpoch}',
        config: const ConnectionConfig(
          autoReconnect: false, // Ensure we don't loop in "reconnecting"
          maxReconnectAttempts: 0,
        ),
      );

      try {
        try {
          await connection.connect();
        } catch (e) {
          // Expected: WebSocketException (HTTP 400/404 from server)
        }

        // FIX: Explicitly wait for the state to settle to Disconnected.
        // Even if the socket closes immediately, the State Machine takes a few ms
        // to process the 'done' event and update the state.
        await waitForState(
          connection,
          ConnectionState.disconnected,
          timeout: const Duration(seconds: 5),
        );

        expect(connection.state, ConnectionState.disconnected);
        expect(connection.isConnected, false);
      } finally {
        await connection.dispose();
      }
    });
  });
}

// Helper for byte comparison
bool _listEquals(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
