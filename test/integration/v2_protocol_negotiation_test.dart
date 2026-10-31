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

  group('v2 Protocol Negotiation', () {
    test('server accepts v2.bsatn.spacetimedb subprotocol', () async {
      final uri = Uri.parse('ws://$host/v1/database/$database/subscribe');

      print('  Opening WebSocket with v2 subprotocol...');
      final channel = IOWebSocketChannel.connect(
        uri,
        protocols: ['v2.bsatn.spacetimedb'],
      );

      try {
        await channel.ready.timeout(const Duration(seconds: 5));
        print(
          '  ✓ Upgrade succeeded. Negotiated protocol: '
          '${channel.protocol}',
        );
      } on Object catch (e) {
        print('  ✗ Upgrade failed: $e');
        rethrow;
      }

      expect(
        channel.protocol,
        'v2.bsatn.spacetimedb',
        reason:
            'Server must echo the v2 subprotocol on successful upgrade. '
            'If it echoes an empty string or v1, the server does not support '
            'v2 and the 2.0.0 plan is blocked on a server upgrade.',
      );

      await channel.sink.close();
    });

    test('first frame decodes as v2 InitialConnection (tag 0)', () async {
      final uri = Uri.parse('ws://$host/v1/database/$database/subscribe');

      final channel = IOWebSocketChannel.connect(
        uri,
        protocols: ['v2.bsatn.spacetimedb'],
      );

      await channel.ready.timeout(const Duration(seconds: 5));
      expect(channel.protocol, 'v2.bsatn.spacetimedb');

      final firstFrame = Completer<Uint8List>();
      late StreamSubscription<dynamic> sub;
      sub = channel.stream.listen(
        (data) {
          if (firstFrame.isCompleted) return;
          if (data is! List<int>) {
            firstFrame.completeError(
              StateError('Expected binary frame, got ${data.runtimeType}'),
            );
            return;
          }
          firstFrame.complete(Uint8List.fromList(data));
          sub.cancel();
        },
        onError: (Object e) {
          if (!firstFrame.isCompleted) firstFrame.completeError(e);
        },
      );

      final bytes = await firstFrame.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw TimeoutException(
          'No server frame within 5s — server accepted v2 upgrade but never '
          'sent InitialConnection. Possibly silently falling back to v1 '
          'without actually speaking v2.',
        ),
      );

      print('  Received ${bytes.length} bytes');
      print('  Frame prefix: ${bytes.sublist(0, bytes.length.clamp(0, 16))}');

      expect(
        bytes.length,
        greaterThanOrEqualTo(1),
        reason: 'Frame must carry at least a compression tag byte',
      );
      final compressionTag = bytes[0];
      print(
        '  Compression tag: $compressionTag '
        '(0=none, 1=brotli, 2=gzip)',
      );
      expect(
        compressionTag,
        0,
        reason:
            'Initial frame expected uncompressed. If server sent '
            'Brotli/Gzip for the handshake frame, test needs decompression '
            'logic — update and re-run.',
      );

      final payload = bytes.sublist(1);
      expect(
        payload.length,
        greaterThanOrEqualTo(1 + 32 + 16 + 4),
        reason:
            'InitialConnection minimum: 1 tag + 32 identity + 16 '
            'connection_id + 4 token-length prefix',
      );

      final decoder = BsatnDecoder(payload);
      final serverMessageTag = decoder.readU8();
      print(
        '  ServerMessage tag: $serverMessageTag '
        '(0=InitialConnection under v2)',
      );
      expect(
        serverMessageTag,
        0,
        reason:
            'v2 ServerMessage tag 0 is InitialConnection (v2.rs:175-196). '
            'Any other tag means the server sent a different first message '
            'or is still speaking v1 (where tag 0 was IdentityToken, whose '
            'payload shape also starts with identity bytes — distinguish by '
            'token placement if ambiguous).',
      );

      final identity = decoder.readBytes(32);
      final connectionId = decoder.readBytes(16);
      final token = decoder.readString();

      print(
        '  identity (first 8 bytes hex): '
        '${identity.sublist(0, 8).map((b) => b.toRadixString(16).padLeft(2, '0')).join()}...',
      );
      print(
        '  connection_id (first 8 bytes hex): '
        '${connectionId.sublist(0, 8).map((b) => b.toRadixString(16).padLeft(2, '0')).join()}...',
      );
      print('  token length: ${token.length}');
      print(
        '  token prefix: ${token.substring(0, token.length.clamp(0, 20))}...',
      );

      expect(identity.length, 32);
      expect(connectionId.length, 16);
      expect(token, isNotEmpty, reason: 'Server must issue a JWT');

      await channel.sink.close();
      print(
        '  ✓ W1 CLOSED: v2 subprotocol accepted, InitialConnection '
        'decoded cleanly.',
      );
    });

    test('control: v1 subprotocol still works (sanity check)', () async {
      final uri = Uri.parse('ws://$host/v1/database/$database/subscribe');

      final channel = IOWebSocketChannel.connect(
        uri,
        protocols: ['v1.bsatn.spacetimedb'],
      );

      await channel.ready.timeout(const Duration(seconds: 5));
      expect(
        channel.protocol,
        'v1.bsatn.spacetimedb',
        reason:
            'Current server still accepts v1. If this ever fails, the '
            'server has dropped v1 support and we must ship 2.0.0 before '
            'consumers can upgrade.',
      );
      await channel.sink.close();
    });
  });
}
