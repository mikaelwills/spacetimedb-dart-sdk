import 'package:spacetimedb_sdk/src/codegen/ir/algebraic_type.dart';
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

    test('Option<u64> emits writeOption with inner writeU64 callback', () {
      const t = OptionType(PrimitiveType(PrimitiveKind.u64));
      expect(
        t.encodeExpression('lastSeen'),
        equals(
          'encoder.writeOption<Int64>(lastSeen, (value) => encoder.writeU64(value))',
        ),
      );
    });

    test('Option<string> emits writeOption with inner writeString callback', () {
      const t = OptionType(PrimitiveType(PrimitiveKind.string));
      expect(
        t.encodeExpression('nickname'),
        equals(
          'encoder.writeOption<String>(nickname, (value) => encoder.writeString(value))',
        ),
      );
    });

    test('Option<Timestamp> emits writeOption with inner writeI64 callback', () {
      const t = OptionType(TimestampType());
      expect(
        t.encodeExpression('resolvedAt'),
        equals(
          'encoder.writeOption<Int64>(resolvedAt, (value) => encoder.writeI64(value))',
        ),
      );
    });

    test('Option<Array<u64>> emits nested writeOption + writeArray', () {
      const t = OptionType(ArrayType(PrimitiveType(PrimitiveKind.u64)));
      expect(
        t.encodeExpression('maybeTags'),
        equals(
          'encoder.writeOption<List<Int64>>(maybeTags, (value) => '
          'encoder.writeArray<Int64>(value, (item) => encoder.writeU64(item)))',
        ),
      );
    });

    test('TimeDurationType emits encoder.writeI64(value)', () {
      const t = TimeDurationType();
      expect(t.encodeExpression('dur'), equals('encoder.writeI64(dur)'));
    });

    test('ScheduleAtType emits value.encode(encoder)', () {
      const t = ScheduleAtType();
      expect(
        t.encodeExpression('nextTick'),
        equals('nextTick.encode(encoder)'),
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

    test('Option<u64> emits readOption with inner readU64 callback', () {
      const t = OptionType(PrimitiveType(PrimitiveKind.u64));
      expect(
        t.decodeExpression(),
        equals('decoder.readOption<Int64>(() => decoder.readU64())'),
      );
    });

    test('Option<string> emits readOption with inner readString callback', () {
      const t = OptionType(PrimitiveType(PrimitiveKind.string));
      expect(
        t.decodeExpression(),
        equals('decoder.readOption<String>(() => decoder.readString())'),
      );
    });

    test('Option<Array<u64>> emits nested readOption + readArray', () {
      const t = OptionType(ArrayType(PrimitiveType(PrimitiveKind.u64)));
      expect(
        t.decodeExpression(),
        equals(
          'decoder.readOption<List<Int64>>(() => '
          'decoder.readArray<Int64>(() => decoder.readU64()))',
        ),
      );
    });

    test('TimeDurationType emits decoder.readI64()', () {
      const t = TimeDurationType();
      expect(t.decodeExpression(), equals('decoder.readI64()'));
    });

    test('ScheduleAtType emits ScheduleAt.decode(decoder)', () {
      const t = ScheduleAtType();
      expect(t.decodeExpression(), equals('ScheduleAt.decode(decoder)'));
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

  group('AlgebraicType.toDartTypeName for OptionType', () {
    test('Option<string> emits String?', () {
      const t = OptionType(PrimitiveType(PrimitiveKind.string));
      expect(t.toDartTypeName(), equals('String?'));
    });

    test('Option<u64> emits Int64?', () {
      const t = OptionType(PrimitiveType(PrimitiveKind.u64));
      expect(t.toDartTypeName(), equals('Int64?'));
    });

    test('Option<Timestamp> emits Int64?', () {
      const t = OptionType(TimestampType());
      expect(t.toDartTypeName(), equals('Int64?'));
    });
  });

  group('AlgebraicType.toDartTypeName for special scheduled types', () {
    test('TimeDurationType emits Int64', () {
      const t = TimeDurationType();
      expect(t.toDartTypeName(), equals('Int64'));
    });

    test('ScheduleAtType emits ScheduleAt', () {
      const t = ScheduleAtType();
      expect(t.toDartTypeName(), equals('ScheduleAt'));
    });
  });

  group('AlgebraicType.fromJson detects Option sum', () {
    test('2-variant some/none sum collapses to OptionType', () {
      final json = {
        'Sum': {
          'variants': [
            {
              'name': {'some': 'some'},
              'algebraic_type': {'String': []},
            },
            {
              'name': {'some': 'none'},
              'algebraic_type': {
                'Product': {'elements': []},
              },
            },
          ],
        },
      };
      final parsed = AlgebraicType.fromJson(json);
      expect(parsed, isA<OptionType>());
      expect(
        (parsed as OptionType).element,
        isA<PrimitiveType>().having(
          (p) => p.kind,
          'kind',
          PrimitiveKind.string,
        ),
      );
    });

    test('non-option sum (3 variants) stays IrSumType', () {
      final json = {
        'Sum': {
          'variants': [
            {
              'name': {'some': 'draft'},
              'algebraic_type': {
                'Product': {'elements': []},
              },
            },
            {
              'name': {'some': 'published'},
              'algebraic_type': {
                'Product': {'elements': []},
              },
            },
            {
              'name': {'some': 'archived'},
              'algebraic_type': {
                'Product': {'elements': []},
              },
            },
          ],
        },
      };
      final parsed = AlgebraicType.fromJson(json);
      expect(parsed, isA<IrSumType>());
    });

    test('reverse-order [none, some] stays IrSumType (order matters)', () {
      final json = {
        'Sum': {
          'variants': [
            {
              'name': {'some': 'none'},
              'algebraic_type': {
                'Product': {'elements': []},
              },
            },
            {
              'name': {'some': 'some'},
              'algebraic_type': {'String': []},
            },
          ],
        },
      };
      final parsed = AlgebraicType.fromJson(json);
      expect(parsed, isA<IrSumType>());
    });

    test('2-variant sum without none stays IrSumType', () {
      final json = {
        'Sum': {
          'variants': [
            {
              'name': {'some': 'left'},
              'algebraic_type': {'String': []},
            },
            {
              'name': {'some': 'right'},
              'algebraic_type': {'U32': []},
            },
          ],
        },
      };
      final parsed = AlgebraicType.fromJson(json);
      expect(parsed, isA<IrSumType>());
    });
  });

  group('AlgebraicType.fromJson detects special scheduled types', () {
    Map<String, dynamic> timeDurationJson() => {
      'Product': {
        'elements': [
          {
            'name': {'some': '__time_duration_micros__'},
            'algebraic_type': {'I64': []},
          },
        ],
      },
    };

    Map<String, dynamic> timestampJson() => {
      'Product': {
        'elements': [
          {
            'name': {'some': '__timestamp_micros_since_unix_epoch__'},
            'algebraic_type': {'I64': []},
          },
        ],
      },
    };

    test('TimeDuration special product collapses to TimeDurationType', () {
      expect(
        AlgebraicType.fromJson(timeDurationJson()),
        isA<TimeDurationType>(),
      );
    });

    test(
      'ScheduleAt sum [Interval(TimeDuration), Time(Timestamp)] collapses to '
      'ScheduleAtType',
      () {
        final json = {
          'Sum': {
            'variants': [
              {
                'name': {'some': 'Interval'},
                'algebraic_type': timeDurationJson(),
              },
              {
                'name': {'some': 'Time'},
                'algebraic_type': timestampJson(),
              },
            ],
          },
        };
        expect(AlgebraicType.fromJson(json), isA<ScheduleAtType>());
      },
    );

    test('reversed [Time, Interval] stays IrSumType (order matters)', () {
      final json = {
        'Sum': {
          'variants': [
            {
              'name': {'some': 'Time'},
              'algebraic_type': timestampJson(),
            },
            {
              'name': {'some': 'Interval'},
              'algebraic_type': timeDurationJson(),
            },
          ],
        },
      };
      expect(AlgebraicType.fromJson(json), isA<IrSumType>());
    });

    test('lowercase variant names stay IrSumType', () {
      final json = {
        'Sum': {
          'variants': [
            {
              'name': {'some': 'interval'},
              'algebraic_type': timeDurationJson(),
            },
            {
              'name': {'some': 'time'},
              'algebraic_type': timestampJson(),
            },
          ],
        },
      };
      expect(AlgebraicType.fromJson(json), isA<IrSumType>());
    });
  });
}
