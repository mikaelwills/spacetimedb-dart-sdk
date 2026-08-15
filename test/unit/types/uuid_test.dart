import 'dart:typed_data';

import 'package:spacetimedb_sdk/src/codec/bsatn_decoder.dart';
import 'package:spacetimedb_sdk/src/codec/bsatn_encoder.dart';
import 'package:spacetimedb_sdk/src/types/uuid.dart';
import 'package:test/test.dart';

const _sample = '01888d6e-5c00-7000-8000-000000000001';

Uint8List _canonicalBytes() => Uint8List.fromList([
  0x01,
  0x88,
  0x8d,
  0x6e,
  0x5c,
  0x00,
  0x70,
  0x00,
  0x80,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x01,
]);

void main() {
  group('Uuid construction', () {
    test('rejects anything other than 16 bytes', () {
      expect(() => Uuid(Uint8List(15)), throwsArgumentError);
      expect(() => Uuid(Uint8List(17)), throwsArgumentError);
      expect(Uuid(Uint8List(16)).bytes.length, 16);
    });

    test('rejects a malformed string', () {
      expect(() => Uuid.parse('not-a-uuid'), throwsArgumentError);
      expect(() => Uuid.parse('01888d6e'), throwsArgumentError);
      expect(
        () => Uuid.parse('zzzzzzzz-5c00-7000-8000-000000000001'),
        throwsArgumentError,
      );
    });
  });

  group('Uuid string form is RFC 4122 hyphenated', () {
    test('nil renders as the all-zero hyphenated form', () {
      expect(
        Uuid(Uint8List(16)).toString(),
        '00000000-0000-0000-0000-000000000000',
      );
    });

    test('max renders as the all-ones hyphenated form', () {
      final maxBytes = Uint8List(16)..fillRange(0, 16, 0xff);
      expect(Uuid(maxBytes).toString(), 'ffffffff-ffff-ffff-ffff-ffffffffffff');
    });

    test('toString follows the 8-4-4-4-12 grouping', () {
      final rendered = Uuid(_canonicalBytes()).toString();

      expect(rendered, _sample);
      expect(rendered.length, 36);
      expect(rendered.split('-').map((p) => p.length).toList(), [
        8,
        4,
        4,
        4,
        12,
      ]);
    });

    test('parse round-trips the hyphenated form', () {
      expect(Uuid.parse(_sample).toString(), _sample);
    });

    test('parse accepts the unhyphenated form', () {
      expect(Uuid.parse(_sample.replaceAll('-', '')).toString(), _sample);
    });
  });

  group('Uuid byte order is big-endian, opposite the wire', () {
    test('bytes hold canonical big-endian order', () {
      expect(Uuid.parse(_sample).bytes, orderedEquals(_canonicalBytes()));
    });

    test('the wire form is the reverse of the canonical bytes', () {
      final uuid = Uuid(_canonicalBytes());
      expect(
        uuid.littleEndianBytes,
        orderedEquals(_canonicalBytes().reversed.toList()),
      );
    });

    test('fromLittleEndianBytes reverses back into canonical order', () {
      final leBytes = Uint8List.fromList(_canonicalBytes().reversed.toList());
      expect(
        Uuid.fromLittleEndianBytes(leBytes).bytes,
        orderedEquals(_canonicalBytes()),
      );
      expect(Uuid.fromLittleEndianBytes(leBytes).toString(), _sample);
    });

    test('a non-palindromic value is not equal to its own reverse', () {
      final forward = Uuid(_canonicalBytes());
      final reversed = Uuid(
        Uint8List.fromList(_canonicalBytes().reversed.toList()),
      );
      expect(forward, isNot(equals(reversed)));
    });

    test('canonical bytes and wire bytes are genuinely different orders', () {
      final uuid = Uuid(_canonicalBytes());

      expect(uuid.bytes, isNot(orderedEquals(uuid.littleEndianBytes)));
      expect(uuid.toHexString, _sample.replaceAll('-', ''));
      expect(uuid.toHexString.length, 32);
    });
  });

  group('Uuid BSATN codec', () {
    test('encodes 16 little-endian bytes, reversed from canonical', () {
      final encoder = BsatnEncoder();
      encoder.writeUuid(Uuid(_canonicalBytes()));
      final encoded = encoder.toBytes();

      expect(encoded.length, 16);
      expect(encoded, orderedEquals(_canonicalBytes().reversed.toList()));
    });

    test('round-trips through encode then decode', () {
      final original = Uuid.parse(_sample);
      final encoder = BsatnEncoder();
      encoder.writeUuid(original);

      final decoded = BsatnDecoder(encoder.toBytes()).readUuid();

      expect(decoded, equals(original));
      expect(decoded.hashCode, original.hashCode);
      expect(decoded.toString(), _sample);
    });
  });

  group('Uuid JSON', () {
    test('toJson and fromJson are exact inverses', () {
      final original = Uuid.parse(_sample);
      final restored = Uuid.fromJson(original.toJson());

      expect(restored, equals(original));
      expect(restored.hashCode, original.hashCode);
      expect(restored.bytes, orderedEquals(original.bytes));
    });

    test('toJson emits the hyphenated form, not bare hex', () {
      expect(Uuid.parse(_sample).toJson(), _sample);
      expect(Uuid.parse(_sample).toJson(), contains('-'));
    });
  });

  group('Uuid primary-key safety', () {
    test('values differing only in the last byte stay distinct', () {
      final a = Uuid(_canonicalBytes());
      final b = Uuid(_canonicalBytes()..[15] = 0x02);

      expect(a, isNot(equals(b)));
      expect(a.hashCode, isNot(equals(b.hashCode)));
      expect(a.toString(), isNot(equals(b.toString())));
    });

    test('last-byte-only differences occupy distinct map entries', () {
      final a = Uuid(_canonicalBytes());
      final b = Uuid(_canonicalBytes()..[15] = 0x02);

      final map = <dynamic, String>{a: 'first', b: 'second'};

      expect(map.length, 2);
      expect(map[a], 'first');
      expect(map[b], 'second');
      expect(map[Uuid.parse(_sample)], 'first');
    });

    test('toString is the full 36-char form, never abbreviated', () {
      final uuid = Uuid(_canonicalBytes());

      expect(uuid.toString().length, 36);
      expect(uuid.toString(), isNot(contains('...')));
    });

    test('every byte position is reflected in toString and hashCode', () {
      final base = Uuid(Uint8List(16));

      for (var i = 0; i < 16; i++) {
        final tweaked = Uint8List(16)..[i] = 0xff;
        final other = Uuid(tweaked);

        expect(other, isNot(equals(base)), reason: 'byte $i ignored by ==');
        expect(
          other.hashCode,
          isNot(equals(base.hashCode)),
          reason: 'byte $i ignored by hashCode',
        );
        expect(
          other.toString(),
          isNot(equals(base.toString())),
          reason: 'byte $i ignored by toString',
        );
      }
    });
  });
}
