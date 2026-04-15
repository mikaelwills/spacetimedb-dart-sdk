// ignore_for_file: avoid_print
import 'package:test/test.dart';
import 'package:spacetimedb_sdk/src/codec/bsatn_encoder.dart';
import 'package:spacetimedb_sdk/src/codec/bsatn_decoder.dart';
import 'package:spacetimedb_sdk/src/messages/client_messages.dart';

void main() {
  test('CallReducer message encoding structure', () {
    print('\n🧪 Testing CallReducer Message Encoding\n');

    // Encode the reducer arguments (title: String, content: String)
    final argsEncoder = BsatnEncoder();
    argsEncoder.writeString('first');
    argsEncoder.writeString('some text');
    final args = argsEncoder.toBytes();

    print('Args bytes (${args.length}):');
    final argsDecoder = BsatnDecoder(args);
    print('  Hex: ${argsDecoder.hexDumpAll()}');

    // Create the CallReducer message
    final message = CallReducerMessage(
      reducerName: 'create_note',
      args: args,
      requestId: 0,
    );

    final encoded = message.encode();
    print('\nFull CallReducer message (${encoded.length} bytes):');
    final fullDecoder = BsatnDecoder(encoded);
    print('  Hex: ${fullDecoder.hexDumpAll()}\n');

    // Decode step by step to verify structure
    final decoder = BsatnDecoder(encoded);

    // 1. Message type tag
    final tag = decoder.readU8();
    print('1. Message type tag: $tag (expected 0 for CallReducer)');
    expect(tag, 0);

    // 2. Reducer name (String = u32 length + bytes)
    final reducerName = decoder.readString();
    print('2. Reducer name: "$reducerName"');
    expect(reducerName, 'create_note');

    // 3. Args length (u32)
    final argsLength = decoder.readU32();
    print('3. Args length: $argsLength (expected ${args.length})');
    expect(argsLength, args.length);

    // 4. Args bytes
    final argsBytes = decoder.readBytes(argsLength);
    print('4. Args bytes: ${argsBytes.length} bytes');

    // Verify args can be decoded
    final argsVerifyDecoder = BsatnDecoder(argsBytes);
    final title = argsVerifyDecoder.readString();
    final content = argsVerifyDecoder.readString();
    print('   - title: "$title"');
    print('   - content: "$content"');
    expect(title, 'first');
    expect(content, 'some text');

    // 5. Request ID (u32)
    final requestId = decoder.readU32();
    print('5. Request ID: $requestId');
    expect(requestId, 0);

    // 6. Flags (u8)
    final flags = decoder.readU8();
    print('6. Flags: $flags (0 = FullUpdate, 1 = NoSuccessNotify)');
    expect(flags, 0);

    // Should have consumed all bytes
    print('\nRemaining bytes: ${decoder.remaining} (should be 0)');
    expect(decoder.remaining, 0);

    print('\n✅ CallReducer message structure is correct!\n');
  });
}
