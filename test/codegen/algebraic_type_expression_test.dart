import 'package:spacetimedb_dart_sdk/src/codegen/ir/algebraic_type.dart';
import 'package:test/test.dart';

void main() {
  group('AlgebraicType.encodeExpression', () {
    test('primitive u32 emits encoder.writeU32(value)', () {
      const t = PrimitiveType(PrimitiveKind.u32);
      expect(t.encodeExpression('id'), equals('encoder.writeU32(id)'));
    });

    test('primitive u64 emits encoder.writeU64(value)', () {
      const t = PrimitiveType(PrimitiveKind.u64);
      expect(t.encodeExpression('id'), equals('encoder.writeU64(id)'));
    });

    test('primitive string emits encoder.writeString(value)', () {
      const t = PrimitiveType(PrimitiveKind.string);
      expect(t.encodeExpression('title'), equals('encoder.writeString(title)'));
    });

    test('IdentityType emits encoder.writeIdentity(value)', () {
      const t = IdentityType();
      expect(t.encodeExpression('id'), equals('encoder.writeIdentity(id)'));
    });

    test('TimestampType emits encoder.writeI64(value)', () {
      const t = TimestampType();
      expect(t.encodeExpression('ts'), equals('encoder.writeI64(ts)'));
    });

    test('ByteArrayType emits encoder.writeByteArray(value)', () {
      const t = ByteArrayType();
      expect(
        t.encodeExpression('bytes'),
        equals('encoder.writeByteArray(bytes)'),
      );
    });

    test('Array<u64> emits writeArray with inner writeU64 callback', () {
      const t = ArrayType(PrimitiveType(PrimitiveKind.u64));
      expect(
        t.encodeExpression('tags'),
        equals(
          'encoder.writeArray<Int64>(tags, (item) => encoder.writeU64(item))',
        ),
      );
    });

    test('Array<string> emits writeArray with inner writeString callback', () {
      const t = ArrayType(PrimitiveType(PrimitiveKind.string));
      expect(
        t.encodeExpression('names'),
        equals(
          'encoder.writeArray<String>(names, (item) => encoder.writeString(item))',
        ),
      );
    });

    test('Array<i32> emits writeArray with inner writeI32 callback', () {
      const t = ArrayType(PrimitiveType(PrimitiveKind.i32));
      expect(
        t.encodeExpression('scores'),
        equals(
          'encoder.writeArray<int>(scores, (item) => encoder.writeI32(item))',
        ),
      );
    });

    test(
      'Array<Identity> emits writeArray with inner writeIdentity callback',
      () {
        const t = ArrayType(IdentityType());
        expect(
          t.encodeExpression('owners'),
          equals(
            'encoder.writeArray<Identity>(owners, (item) => encoder.writeIdentity(item))',
          ),
        );
      },
    );

    test('Array<Timestamp> emits writeArray with inner writeI64 callback', () {
      const t = ArrayType(TimestampType());
      expect(
        t.encodeExpression('times'),
        equals(
          'encoder.writeArray<Int64>(times, (item) => encoder.writeI64(item))',
        ),
      );
    });

    test('nested Array<Array<u64>> emits nested writeArray', () {
      const t = ArrayType(ArrayType(PrimitiveType(PrimitiveKind.u64)));
      expect(
        t.encodeExpression('grid'),
        equals(
          'encoder.writeArray<List<Int64>>(grid, (item) => '
          'encoder.writeArray<Int64>(item, (item) => encoder.writeU64(item)))',
        ),
      );
    });

    test('IrProductType throws StateError', () {
      const t = IrProductType(elements: []);
      expect(() => t.encodeExpression('value'), throwsA(isA<StateError>()));
    });

    test('IrSumType throws StateError', () {
      const t = IrSumType(variants: []);
      expect(() => t.encodeExpression('value'), throwsA(isA<StateError>()));
    });
  });

  group('AlgebraicType.decodeExpression', () {
    test('primitive u32 emits decoder.readU32()', () {
      const t = PrimitiveType(PrimitiveKind.u32);
      expect(t.decodeExpression(), equals('decoder.readU32()'));
    });

    test('primitive string emits decoder.readString()', () {
      const t = PrimitiveType(PrimitiveKind.string);
      expect(t.decodeExpression(), equals('decoder.readString()'));
    });

    test('ByteArrayType emits decoder.readByteArray()', () {
      const t = ByteArrayType();
      expect(t.decodeExpression(), equals('decoder.readByteArray()'));
    });

    test('Array<u64> emits readArray with inner readU64 callback', () {
      const t = ArrayType(PrimitiveType(PrimitiveKind.u64));
      expect(
        t.decodeExpression(),
        equals('decoder.readArray<Int64>(() => decoder.readU64())'),
      );
    });

    test('Array<string> emits readArray with inner readString callback', () {
      const t = ArrayType(PrimitiveType(PrimitiveKind.string));
      expect(
        t.decodeExpression(),
        equals('decoder.readArray<String>(() => decoder.readString())'),
      );
    });

    test('nested Array<Array<u64>> emits nested readArray', () {
      const t = ArrayType(ArrayType(PrimitiveType(PrimitiveKind.u64)));
      expect(
        t.decodeExpression(),
        equals(
          'decoder.readArray<List<Int64>>(() => '
          'decoder.readArray<Int64>(() => decoder.readU64()))',
        ),
      );
    });

    test('IrProductType throws StateError', () {
      const t = IrProductType(elements: []);
      expect(() => t.decodeExpression(), throwsA(isA<StateError>()));
    });

    test('IrSumType throws StateError', () {
      const t = IrSumType(variants: []);
      expect(() => t.decodeExpression(), throwsA(isA<StateError>()));
    });
  });
}
