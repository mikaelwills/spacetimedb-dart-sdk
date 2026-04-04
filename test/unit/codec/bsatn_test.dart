import 'dart:typed_data';
import 'package:fixnum/fixnum.dart';
import 'package:test/test.dart';
import 'package:spacetimedb_dart_sdk/src/codec/bsatn_decoder.dart';
import 'package:spacetimedb_dart_sdk/src/codec/bsatn_encoder.dart';

void main() {
  group('BSATN Primitives', () {
    test('u8 round-trip', () {
      final encoder = BsatnEncoder();
      encoder.writeU8(42);
      encoder.writeU8(0);
      encoder.writeU8(255);

      final decoder = BsatnDecoder(encoder.toBytes());
      expect(decoder.readU8(), 42);
      expect(decoder.readU8(), 0);
      expect(decoder.readU8(), 255);
    });

    test('u16 round-trip', () {
      final encoder = BsatnEncoder();
      encoder.writeU16(0);
      encoder.writeU16(258);
      encoder.writeU16(65535);

      final decoder = BsatnDecoder(encoder.toBytes());
      expect(decoder.readU16(), 0);
      expect(decoder.readU16(), 258);
      expect(decoder.readU16(), 65535);
    });

    test('u32 round-trip', () {
      final encoder = BsatnEncoder();
      encoder.writeU32(0);
      encoder.writeU32(42);
      encoder.writeU32(4294967295);

      final decoder = BsatnDecoder(encoder.toBytes());
      expect(decoder.readU32(), 0);
      expect(decoder.readU32(), 42);
      expect(decoder.readU32(), 4294967295);
    });

    test('u64 round-trip', () {
      final encoder = BsatnEncoder();
      encoder.writeU64(Int64.ZERO);
      encoder.writeU64(Int64(42));
      encoder.writeU64(Int64.MAX_VALUE);

      final decoder = BsatnDecoder(encoder.toBytes());
      expect(decoder.readU64(), Int64.ZERO);
      expect(decoder.readU64(), Int64(42));
      expect(decoder.readU64(), Int64.MAX_VALUE);
    });

    test('i8 round-trip', () {
      final encoder = BsatnEncoder();
      encoder.writeI8(-128);
      encoder.writeI8(0);
      encoder.writeI8(127);

      final decoder = BsatnDecoder(encoder.toBytes());
      expect(decoder.readI8(), -128);
      expect(decoder.readI8(), 0);
      expect(decoder.readI8(), 127);
    });

    test('i16 round-trip', () {
      final encoder = BsatnEncoder();
      encoder.writeI16(-32768);
      encoder.writeI16(0);
      encoder.writeI16(32767);

      final decoder = BsatnDecoder(encoder.toBytes());
      expect(decoder.readI16(), -32768);
      expect(decoder.readI16(), 0);
      expect(decoder.readI16(), 32767);
    });

    test('i32 round-trip', () {
      final encoder = BsatnEncoder();
      encoder.writeI32(-2147483648);
      encoder.writeI32(-100);
      encoder.writeI32(0);
      encoder.writeI32(100);
      encoder.writeI32(2147483647);

      final decoder = BsatnDecoder(encoder.toBytes());
      expect(decoder.readI32(), -2147483648);
      expect(decoder.readI32(), -100);
      expect(decoder.readI32(), 0);
      expect(decoder.readI32(), 100);
      expect(decoder.readI32(), 2147483647);
    });

    test('i64 round-trip', () {
      final encoder = BsatnEncoder();
      encoder.writeI64(Int64.MIN_VALUE);
      encoder.writeI64(Int64(-1));
      encoder.writeI64(Int64.ZERO);
      encoder.writeI64(Int64.MAX_VALUE);

      final decoder = BsatnDecoder(encoder.toBytes());
      expect(decoder.readI64(), Int64.MIN_VALUE);
      expect(decoder.readI64(), Int64(-1));
      expect(decoder.readI64(), Int64.ZERO);
      expect(decoder.readI64(), Int64.MAX_VALUE);
    });

    test('f32 round-trip', () {
      final encoder = BsatnEncoder();
      encoder.writeF32(3.14);
      encoder.writeF32(-2.71828);
      encoder.writeF32(0.0);

      final decoder = BsatnDecoder(encoder.toBytes());
      expect(decoder.readF32(), closeTo(3.14, 0.0001));
      expect(decoder.readF32(), closeTo(-2.71828, 0.0001));
      expect(decoder.readF32(), 0.0);
    });

    test('f64 round-trip', () {
      final encoder = BsatnEncoder();
      encoder.writeF64(3.141592653589793);
      encoder.writeF64(-2.718281828);
      encoder.writeF64(0.0);

      final decoder = BsatnDecoder(encoder.toBytes());
      expect(decoder.readF64(), closeTo(3.141592653589793, 0.00001));
      expect(decoder.readF64(), closeTo(-2.718281828, 0.00001));
      expect(decoder.readF64(), 0.0);
    });

    test('bool round-trip', () {
      final encoder = BsatnEncoder();
      encoder.writeBool(true);
      encoder.writeBool(false);
      encoder.writeBool(true);

      final decoder = BsatnDecoder(encoder.toBytes());
      expect(decoder.readBool(), true);
      expect(decoder.readBool(), false);
      expect(decoder.readBool(), true);
    });

    test('string round-trip', () {
      final encoder = BsatnEncoder();
      encoder.writeString("Hello");
      encoder.writeString("");
      encoder.writeString("Emoji: 🚀🎮");

      final decoder = BsatnDecoder(encoder.toBytes());
      expect(decoder.readString(), "Hello");
      expect(decoder.readString(), "");
      expect(decoder.readString(), "Emoji: 🚀🎮");
    });
  });

  group('BSATN Composite Types', () {
    test('Option<int> with Some', () {
      final encoder = BsatnEncoder();
      encoder.writeOption(42, (v) => encoder.writeU32(v));

      final decoder = BsatnDecoder(encoder.toBytes());
      final value = decoder.readOption(() => decoder.readU32());
      expect(value, 42);
    });

    test('Option<int> with None', () {
      final encoder = BsatnEncoder();
      encoder.writeOption<int>(null, (v) => encoder.writeU32(v));

      final decoder = BsatnDecoder(encoder.toBytes());
      final value = decoder.readOption(() => decoder.readU32());
      expect(value, null);
    });

    test('List<int> round-trip', () {
      final encoder = BsatnEncoder();
      final list = [1, 2, 3, 4, 5];
      encoder.writeList(list, (item) => encoder.writeU32(item));

      final decoder = BsatnDecoder(encoder.toBytes());
      final decoded = decoder.readList(() => decoder.readU32());
      expect(decoded, equals(list));
    });

    test('Empty list round-trip', () {
      final encoder = BsatnEncoder();
      encoder.writeList<int>([], (item) => encoder.writeU32(item));

      final decoder = BsatnDecoder(encoder.toBytes());
      final decoded = decoder.readList(() => decoder.readU32());
      expect(decoded, isEmpty);
    });

    test('List<String> round-trip', () {
      final encoder = BsatnEncoder();
      final list = ['apple', 'banana', 'cherry'];
      encoder.writeList(list, (item) => encoder.writeString(item));

      final decoder = BsatnDecoder(encoder.toBytes());
      final decoded = decoder.readList(() => decoder.readString());
      expect(decoded, equals(list));
    });

    test('Map<String, int> round-trip', () {
      final encoder = BsatnEncoder();
      final map = {'a': 1, 'b': 2, 'c': 3};
      encoder.writeMap(
        map,
        (k) => encoder.writeString(k),
        (v) => encoder.writeU32(v),
      );

      final decoder = BsatnDecoder(encoder.toBytes());
      final decoded = decoder.readMap(
        () => decoder.readString(),
        () => decoder.readU32(),
      );
      expect(decoded, equals(map));
    });

    test('Nested Option<List<int>>', () {
      final encoder = BsatnEncoder();
      final value = [1, 2, 3];
      encoder.writeOption(
        value,
        (list) => encoder.writeList(list, (i) => encoder.writeU32(i)),
      );

      final decoder = BsatnDecoder(encoder.toBytes());
      final decoded = decoder.readOption(
        () => decoder.readList(() => decoder.readU32()),
      );
      expect(decoded, equals(value));
    });

    test('Nested List<Option<int>>', () {
      final encoder = BsatnEncoder();
      final list = [1, null, 3, null, 5];
      encoder.writeList(
        list,
        (item) => encoder.writeOption(item, (v) => encoder.writeU32(v)),
      );

      final decoder = BsatnDecoder(encoder.toBytes());
      final decoded = decoder.readList(
        () => decoder.readOption(() => decoder.readU32()),
      );
      expect(decoded, equals(list));
    });
  });

  group('BSATN Edge Cases', () {
    test('Large string (>255 bytes)', () {
      final encoder = BsatnEncoder();
      final largeString = 'x' * 1000;
      encoder.writeString(largeString);

      final decoder = BsatnDecoder(encoder.toBytes());
      expect(decoder.readString(), equals(largeString));
    });

    test('Unicode string with emojis', () {
      final encoder = BsatnEncoder();
      const emoji = '👾🎮🚀💻🔥';
      encoder.writeString(emoji);

      final decoder = BsatnDecoder(encoder.toBytes());
      expect(decoder.readString(), equals(emoji));
    });

    test('Float special values', () {
      final encoder = BsatnEncoder();
      encoder.writeF64(double.infinity);
      encoder.writeF64(double.negativeInfinity);
      encoder.writeF64(double.nan);

      final decoder = BsatnDecoder(encoder.toBytes());
      expect(decoder.readF64(), equals(double.infinity));
      expect(decoder.readF64(), equals(double.negativeInfinity));
      expect(decoder.readF64().isNaN, true);
    });
  });

  group('BSATN Error Handling', () {
    test('Reading past buffer throws', () {
      final decoder = BsatnDecoder(Uint8List.fromList([1, 2, 3]));
      decoder.readU8();
      decoder.readU8();
      decoder.readU8();

      expect(() => decoder.readU8(), throwsStateError);
    });

    test('Invalid boolean value throws', () {
      final decoder = BsatnDecoder(
        Uint8List.fromList([2]),
      ); // Invalid (not 0 or 1)
      expect(() => decoder.readBool(), throwsFormatException);
    });

    test('Out of range u8 throws', () {
      final encoder = BsatnEncoder();
      expect(() => encoder.writeU8(-1), throwsArgumentError);
      expect(() => encoder.writeU8(256), throwsArgumentError);
    });

    test('Out of range i32 throws', () {
      final encoder = BsatnEncoder();
      expect(() => encoder.writeI32(-2147483649), throwsArgumentError);
      expect(() => encoder.writeI32(2147483648), throwsArgumentError);
    });
  });
}
