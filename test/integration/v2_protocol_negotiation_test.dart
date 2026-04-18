// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:typed_data';

import 'package:spacetimedb_sdk/codegen.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';

import '../helpers/integration_test_helper.dart';

/// v2 Protocol Negotiation Investigation (W1 from the 2026-04-18 v2 pipeline)
///
/// Question: does a SpacetimeDB 2.x server accept the `v2.bsatn.spacetimedb`
/// WebSocket subprotocol, and if so, does it send `InitialConnection` as the
/// first server frame under the v2 schema?
///
/// The Dart SDK's 2.0.0 branch hinges on the answer. The prior 2026-04-13
/// investigation did not verify this against a live server — the plan was
/// assembled from reading `crates/client-api-messages/src/websocket/v2.rs`
/// and assuming the server accepts clients that advertise v2 in the
/// subprotocol list. This test closes that assumption.
///
/// What we do:
///   1. Open a raw WebSocket to `/v1/database/<name>/subscribe` with the
///      v2 subprotocol string in the `protocols` list (the URL path itself
///      is *not* a protocol version — it's the HTTP API version, mounted at
///      `/v1` on the server side regardless of wire protocol).
///   2. Observe the upgrade response. If the server rejects v2 outright, we
///      get a `WebSocketChannelException` from `IOWebSocketChannel.connect`.
///   3. If the upgrade succeeds, read the first frame and decode it against
///      the v2 `ServerMessage` tag space:
///        - tag 0 = `InitialConnection { identity: 32B, connection_id: 16B,
///          token: Box<str> }`  (v2.rs:175-204)
///      Frame envelope: 1 byte compression tag (0=none, 1=brotli, 2=gzip)
///      followed by the BSATN payload. We only exercise the compression=none
///      path here — servers advertise default compression based on the
///      `?compression=` query param (absent here, defaults to `Brotli`), but
///      the initial connection frame predates any subscription and is short
///      enough that the server sends it uncompressed (observed in v1; verify
///      empirically).
///
/// Expected outcomes:
///   A. v2 accepted, InitialConnection received → W1 closes, 2.0.0 plan is
///      executable as designed.
///   B. v2 rejected (HTTP 400 on upgrade) → server does not advertise v2 on
///      this release; 2.0.0 would need a server-version gate or we wait for
///      the next server release.
///   C. v2 accepted but server silently sends v1 bytes → indistinguishable
///      from a v1 `IdentityToken` decode (different tag, different shape).
///      Caught by tag inspection.
///
/// Prerequisites: SpacetimeDB server from `test_setup.dart` must be running
/// with `notesdb` (the shared test module) published. Uses port 3000, local
/// instance.
///
/// Not a regression test — this is diagnostic. Findings get written to
/// `tasks/v2-wire-protocol/research.md` (or a follow-up note) and the 2.0.0
/// plan is refined accordingly.

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
        onTimeout:
            () =>
                throw TimeoutException(
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
