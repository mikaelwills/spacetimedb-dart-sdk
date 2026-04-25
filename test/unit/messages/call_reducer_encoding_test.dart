import 'package:test/test.dart';
import 'package:spacetimedb_sdk/src/codec/bsatn_encoder.dart';
import 'package:spacetimedb_sdk/src/codec/bsatn_decoder.dart';
import 'package:spacetimedb_sdk/src/messages/client_messages.dart';

void main() {
  test('v2 CallReducer encodes { tag=3, requestId, flags, reducer, args }', () {
    final argsEncoder = BsatnEncoder();
    argsEncoder.writeString('first');
    argsEncoder.writeString('some text');
    final args = argsEncoder.toBytes();

    final message = CallReducerMessage(
      reducerName: 'create_note',
      args: args,
      requestId: 0,
    );

    final encoded = message.encode();
    final decoder = BsatnDecoder(encoded);

    // 1. Message tag — v2 CallReducer is tag 3 (v2.rs:18-29).
    expect(decoder.readU8(), equals(3));

    // 2. request_id (u32) — v2 order puts request_id BEFORE reducer name.
    expect(decoder.readU32(), equals(0));

    // 3. flags (u8) — CallReducerFlags::Default = 0.
    expect(decoder.readU8(), equals(0));

    // 4. reducer name (string).
    expect(decoder.readString(), equals('create_note'));

    // 5. args bytes (u32 length prefix + bytes).
    final argsLength = decoder.readU32();
    expect(argsLength, equals(args.length));
    final argsBytes = decoder.readBytes(argsLength);

    final argsVerifyDecoder = BsatnDecoder(argsBytes);
    expect(argsVerifyDecoder.readString(), equals('first'));
    expect(argsVerifyDecoder.readString(), equals('some text'));

    // Fully consumed.
    expect(decoder.remaining, equals(0));
  });
}
