// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:io';
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// WebSocket Close Codes Investigation for SpacetimeDB
///
/// Goal: Determine what close codes SpacetimeDB sends for different failure
/// scenarios so clients can differentiate between:
/// - Network failure: keep retrying with existing token
/// - Auth failure (stale/invalid token): clear token and connect fresh
///
/// FINDINGS (as of testing):
/// ┌─────────────────────────────────────┬───────────────────────────────────────────┐
/// │ Scenario                            │ Result                                    │
/// ├─────────────────────────────────────┼───────────────────────────────────────────┤
/// │ Valid/No token (anonymous)          │ Connection succeeds, graceful close       │
/// │ Invalid/garbage token               │ HTTP 401 - WebSocket upgrade rejected     │
/// │ Malformed Authorization header      │ HTTP 400 - WebSocket upgrade rejected     │
/// │ Non-existent database               │ HTTP 400 - WebSocket upgrade rejected     │
/// │ Wrong protocol                      │ HTTP 400 - WebSocket upgrade rejected     │
/// │ Network failure (unreachable host)  │ TimeoutException or SocketException       │
/// └─────────────────────────────────────┴───────────────────────────────────────────┘
///
/// Key insight: SpacetimeDB rejects auth failures at HTTP level (before WebSocket
/// upgrade) with HTTP 401/400 status codes, NOT WebSocket close codes. The client
/// receives a WebSocketException with the HTTP status, not a close code.
///
/// CLIENT IMPLEMENTATION RECOMMENDATION:
/// - Catch WebSocketChannelException during connect()
/// - Parse HTTP status from exception message:
///   - 401: Auth failure → clear token, reconnect fresh
///   - 400: Config error (bad protocol, bad database) → don't retry
/// - Catch SocketException/TimeoutException: Network failure → retry with backoff
///
/// Prerequisites: SpacetimeDB must be running with notesdb published
/// Run with: dart test test/integration/websocket_close_codes_test.dart

void main() {
  // Ensure SpacetimeDB is running before tests
  setUpAll(() async {
    try {
      final socket = await Socket.connect(
        'localhost',
        3000,
        timeout: const Duration(seconds: 2),
      );
      socket.destroy();
      print('✅ SpacetimeDB is running on localhost:3000');
    } catch (e) {
      fail('SpacetimeDB is not running. Start with: spacetime start');
    }
  });

  const host = 'localhost:3000';
  const database = 'notesdb';

  group('WebSocket Close Codes Investigation', () {
    test('1. Valid connection (no token) - connects successfully', () async {
      final uri = Uri.parse('ws://$host/v1/database/$database/subscribe');

      final channel = IOWebSocketChannel.connect(
        uri,
        protocols: ['v1.bsatn.spacetimedb'],
      );

      final completer = Completer<void>();
      var receivedData = false;

      channel.stream.listen(
        (data) {
          receivedData = true;
          print(
            '  Received data: ${data.runtimeType} (${(data as List).length} bytes)',
          );
        },
        onError: (e) => print('  Error: $e'),
        onDone: () {
          print('  Close code: ${channel.closeCode}');
          print('  Close reason: ${channel.closeReason}');
          completer.complete();
        },
      );

      // Wait a moment to receive initial messages (IdentityToken)
      await Future.delayed(const Duration(seconds: 2));
      expect(
        receivedData,
        isTrue,
        reason: 'Should receive IdentityToken message',
      );

      // Gracefully close
      await channel.sink.close();
      await completer.future.timeout(const Duration(seconds: 5));

      print(
        '  ✅ Anonymous connection works - server sends data then accepts close',
      );
    });

    test(
      '2. Invalid token - HTTP 401 rejection (not WebSocket close code)',
      () async {
        final uri = Uri.parse('ws://$host/v1/database/$database/subscribe');

        final channel = IOWebSocketChannel.connect(
          uri,
          protocols: ['v1.bsatn.spacetimedb'],
          headers: {'Authorization': 'Bearer invalid_garbage_token_12345'},
        );

        Object? caughtError;
        try {
          await channel.ready;
          fail('Should not connect with invalid token');
        } on WebSocketChannelException catch (e) {
          caughtError = e;
          print('  Error: $e');
        }

        expect(caughtError, isNotNull);
        expect(caughtError.toString(), contains('401'));
        print('  ✅ Invalid token correctly rejected with HTTP 401');
      },
    );

    test('3. Malformed Authorization header - HTTP 400 rejection', () async {
      final uri = Uri.parse('ws://$host/v1/database/$database/subscribe');

      final channel = IOWebSocketChannel.connect(
        uri,
        protocols: ['v1.bsatn.spacetimedb'],
        headers: {'Authorization': 'NotBearer malformed'},
      );

      Object? caughtError;
      try {
        await channel.ready;
        fail('Should not connect with malformed auth');
      } on WebSocketChannelException catch (e) {
        caughtError = e;
        print('  Error: $e');
      }

      expect(caughtError, isNotNull);
      expect(caughtError.toString(), contains('400'));
      print('  ✅ Malformed auth header correctly rejected with HTTP 400');
    });

    test('4. Non-existent database - HTTP 400 rejection', () async {
      final uri = Uri.parse(
        'ws://$host/v1/database/nonexistent_db_xyz/subscribe',
      );

      final channel = IOWebSocketChannel.connect(
        uri,
        protocols: ['v1.bsatn.spacetimedb'],
      );

      Object? caughtError;
      try {
        await channel.ready;
        fail('Should not connect to non-existent database');
      } on WebSocketChannelException catch (e) {
        caughtError = e;
        print('  Error: $e');
      }

      expect(caughtError, isNotNull);
      expect(caughtError.toString(), contains('400'));
      print('  ✅ Non-existent database correctly rejected with HTTP 400');
    });

    test('5. Wrong protocol - HTTP 400 rejection', () async {
      final uri = Uri.parse('ws://$host/v1/database/$database/subscribe');

      final channel = IOWebSocketChannel.connect(
        uri,
        protocols: ['wrong.protocol'],
      );

      Object? caughtError;
      try {
        await channel.ready;
        fail('Should not connect with wrong protocol');
      } on WebSocketChannelException catch (e) {
        caughtError = e;
        print('  Error: $e');
      }

      expect(caughtError, isNotNull);
      expect(caughtError.toString(), contains('400'));
      print('  ✅ Wrong protocol correctly rejected with HTTP 400');
    });

    test('6. Network failure - throws exception (no close code)', () async {
      // 192.0.2.1 is TEST-NET-1, guaranteed non-routable
      final uri = Uri.parse('ws://192.0.2.1:9999/v1/database/test/subscribe');

      Object? caughtError;

      try {
        final channel = IOWebSocketChannel.connect(
          uri,
          protocols: ['v1.bsatn.spacetimedb'],
          connectTimeout: const Duration(seconds: 3),
        );

        await channel.ready;
        fail('Should not connect to non-existent host');
      } catch (e) {
        caughtError = e;
        print('  Exception type: ${e.runtimeType}');
        print('  Exception: $e');
      }

      expect(caughtError, isNotNull);
      // Should be either TimeoutException or SocketException
      expect(
        caughtError is TimeoutException ||
            caughtError.toString().contains('SocketException'),
        isTrue,
        reason:
            'Network failure should throw TimeoutException or SocketException',
      );
      print('  ✅ Network failure correctly throws exception');
    });
  });
}
