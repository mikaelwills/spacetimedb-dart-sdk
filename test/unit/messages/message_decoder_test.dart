import 'dart:io';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:spacetimedb_sdk/src/messages/message_decoder.dart';
import 'package:spacetimedb_sdk/src/messages/server_messages.dart';
import 'package:spacetimedb_sdk/src/codec/bsatn_encoder.dart';

/// v2 `InitialConnection`: tag 0 in the `ServerMessage` enum (v2.rs:175-196).
Uint8List _encodeInitialConnectionBody() {
  final encoder = BsatnEncoder();
  encoder.writeU8(0); // ServerMessageType.initialConnection tag
  encoder.writeBytes(Uint8List(32)); // identity
  encoder.writeBytes(Uint8List(16)); // connection_id
  encoder.writeString('test-token');
  return encoder.toBytes();
}

Uint8List _frame(int compressionTag, List<int> payload) {
  final out = BytesBuilder();
  out.addByte(compressionTag);
  out.add(payload);
  return out.toBytes();
}

void main() {
  group('MessageDecoder (v2)', () {
    test('decodes InitialConnectionMessage', () async {
      final encoder = BsatnEncoder();
      encoder.writeU8(0); // compression: none
      encoder.writeU8(0); // ServerMessageType.initialConnection
      encoder.writeBytes(Uint8List(32));
      encoder.writeBytes(Uint8List(16));
      encoder.writeString('test-token');

      final bytes = encoder.toBytes();
      final message = await MessageDecoder.decode(bytes);

      expect(message, isA<InitialConnectionMessage>());
      final initial = message as InitialConnectionMessage;
      expect(initial.token, equals('test-token'));
      expect(initial.identity.length, equals(32));
      expect(initial.connectionId.length, equals(16));
    });

    test('throws on unsupported message type', () {
      final encoder = BsatnEncoder();
      encoder.writeU8(0);
      encoder.writeU8(99);

      final bytes = encoder.toBytes();

      expect(MessageDecoder.decode(bytes), throwsA(isA<ArgumentError>()));
    });

    test('decodes a Gzip-compressed InitialConnectionMessage', () async {
      final body = _encodeInitialConnectionBody();
      final compressed = gzip.encode(body);
      final frame = _frame(2, compressed);

      final message = await MessageDecoder.decode(frame);

      expect(message, isA<InitialConnectionMessage>());
      expect((message as InitialConnectionMessage).token, equals('test-token'));
    });
  });
}
