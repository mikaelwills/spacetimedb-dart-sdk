// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:typed_data';

import 'package:spacetimedb_sdk/codegen.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';

import '../helpers/integration_test_helper.dart';

void main() {
  setUpAll(ensureTestEnvironment);
  tearDownAll(cleanupTestEnvironment);

  const host = 'localhost:3000';
  const database = 'notesdb';

  group('v3 Protocol Negotiation (SpacetimeDB 2.2.0+)', () {
    test('server accepts v3.bsatn.spacetimedb subprotocol', () async {
      final uri = Uri.parse('ws://$host/v1/database/$database/subscribe');

      final channel = IOWebSocketChannel.connect(
        uri,
        protocols: ['v3.bsatn.spacetimedb'],
      );

      try {
        await channel.ready.timeout(const Duration(seconds: 5));
        print('  Negotiated protocol: ${channel.protocol}');
      } on Object catch (e) {
        print('  ✗ Upgrade failed: $e');
        rethrow;
      }

      expect(
        channel.protocol,
        'v3.bsatn.spacetimedb',
        reason:
            'Server must echo v3 subprotocol on successful upgrade. If it '
            'echoes v2 or empty, the server is < 2.2.0 and the test '
            'environment needs `spacetime version use >= 2.2.0`.',
      );

      await channel.sink.close();
    });

    test('server prefers v3 when client advertises [v3, v2]', () async {
      final uri = Uri.parse('ws://$host/v1/database/$database/subscribe');

      final channel = IOWebSocketChannel.connect(
        uri,
        protocols: const ['v3.bsatn.spacetimedb', 'v2.bsatn.spacetimedb'],
      );

      await channel.ready.timeout(const Duration(seconds: 5));
      expect(
        channel.protocol,
        'v3.bsatn.spacetimedb',
        reason:
            'Per upstream subscribe.rs (PR #4761), server preference order '
            'is v3 > v2 > v1.bsatn > v1.json. Dual-advertise must land on v3.',
      );

      await channel.sink.close();
    });

    test(
      'v2 fallback still works (regression guard for dual-support)',
      () async {
        final uri = Uri.parse('ws://$host/v1/database/$database/subscribe');

        final channel = IOWebSocketChannel.connect(
          uri,
          protocols: const ['v2.bsatn.spacetimedb'],
        );

        await channel.ready.timeout(const Duration(seconds: 5));
        expect(channel.protocol, 'v2.bsatn.spacetimedb');

        await channel.sink.close();
      },
    );

    test('SpacetimeDbConnection negotiates v3 end-to-end', () async {
      final connection = SpacetimeDbConnection(
        host: host,
        database: database,
        config: ConnectionConfig.development,
      );

      final initialConnectionMessage = Completer<Uint8List>();
      late StreamSubscription<Uint8List> sub;
      sub = connection.onMessage.listen((bytes) {
        if (!initialConnectionMessage.isCompleted) {
          initialConnectionMessage.complete(bytes);
          sub.cancel();
        }
      });

      try {
        await connection.connect();
        expect(
          connection.negotiatedProtocol,
          NegotiatedWsProtocol.v3,
          reason:
              'SDK with kPreferredWsProtocols = [v3, v2] must negotiate v3 '
              'against a 2.2.0+ server.',
        );

        await initialConnectionMessage.future.timeout(
          const Duration(seconds: 5),
        );
      } finally {
        await sub.cancel();
        await connection.dispose();
      }
    });
  });
}
