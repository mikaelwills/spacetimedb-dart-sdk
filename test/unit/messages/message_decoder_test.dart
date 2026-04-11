import 'dart:io';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:spacetimedb_dart_sdk/src/messages/message_decoder.dart';
import 'package:spacetimedb_dart_sdk/src/messages/server_messages.dart';
import 'package:spacetimedb_dart_sdk/src/codec/bsatn_encoder.dart';

Uint8List _encodeIdentityTokenBody() {
  final encoder = BsatnEncoder();
  encoder.writeU8(3);
  encoder.writeBytes(Uint8List(32));
  encoder.writeString('test-token');
  encoder.writeBytes(Uint8List(16));
  return encoder.toBytes();
}

Uint8List _frame(int compressionTag, List<int> payload) {
  final out = BytesBuilder();
  out.addByte(compressionTag);
  out.add(payload);
  return out.toBytes();
}

void main() {
  group('MessageDecoder', () {
    test('decodes IdentityTokenMessage', () {
      final encoder = BsatnEncoder();
      encoder.writeU8(0);
      encoder.writeU8(3);
      encoder.writeBytes(Uint8List(32));
      encoder.writeString('test-token');
      encoder.writeBytes(Uint8List(16));

      final bytes = encoder.toBytes();
      final message = MessageDecoder.decode(bytes);

      expect(message, isA<IdentityTokenMessage>());
      final identityMsg = message as IdentityTokenMessage;
      expect(identityMsg.token, equals('test-token'));
    });

    test('throws on unsupported message type', () {
      final encoder = BsatnEncoder();
      encoder.writeU8(0);
      encoder.writeU8(99);

      final bytes = encoder.toBytes();

      expect(() => MessageDecoder.decode(bytes), throwsA(isA<ArgumentError>()));
    });

    test('decodes a Gzip-compressed IdentityTokenMessage', () {
      final body = _encodeIdentityTokenBody();
      final compressed = gzip.encode(body);
      final frame = _frame(2, compressed);

      final message = MessageDecoder.decode(frame);

      expect(message, isA<IdentityTokenMessage>());
      expect((message as IdentityTokenMessage).token, equals('test-token'));
    });
  });
}
