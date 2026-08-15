import 'dart:typed_data';

import 'package:spacetimedb_sdk/src/codec/bsatn_decoder.dart';
import 'package:spacetimedb_sdk/src/codec/bsatn_encoder.dart';
import 'package:spacetimedb_sdk/src/types/connection_id.dart';
import 'package:test/test.dart';

Uint8List _wireBytes() => Uint8List.fromList([
  0x01,
  0x02,
  0x03,
  0x04,
  0x05,
  0x06,
  0x07,
  0x08,
  0x09,
  0x0a,
  0x0b,
  0x0c,
  0x0d,
  0x0e,
  0x0f,
  0x10,
]);

void main() {
  group('ConnectionId construction', () {
    test('rejects anything other than 16 bytes', () {
      expect(() => ConnectionId(Uint8List(15)), throwsArgumentError);
      expect(() => ConnectionId(Uint8List(17)), throwsArgumentError);
      expect(() => ConnectionId(Uint8List(32)), throwsArgumentError);
      expect(ConnectionId(Uint8List(16)).bytes.length, 16);
    });

    test('rejects a hex string of the wrong length', () {
      expect(() => ConnectionId.fromHexString('abcd'), throwsArgumentError);
    });
  });

  group('ConnectionId byte order', () {
    test('bytes hold little-endian wire order verbatim', () {
      final id = ConnectionId(_wireBytes());
      expect(id.bytes, orderedEquals(_wireBytes()));
    });

    test('hex form is big-endian, the reverse of the wire bytes', () {
      final id = ConnectionId(_wireBytes());

      expect(id.toHexString, '100f0e0d0c0b0a090807060504030201');
      expect(id.bigEndianBytes, orderedEquals(_wireBytes().reversed.toList()));
    });

    test('fromHexString reverses back into wire order', () {
      final id = ConnectionId.fromHexString('100f0e0d0c0b0a090807060504030201');
      expect(id.bytes, orderedEquals(_wireBytes()));
    });

    test('a big-endian byte array round-trips through hex', () {
      final beBytes = Uint8List.fromList(_wireBytes().reversed.toList());
      final id = ConnectionId.fromBigEndianBytes(beBytes);

      expect(id.bytes, orderedEquals(_wireBytes()));
      expect(id.bigEndianBytes, orderedEquals(beBytes));
    });

    test('a non-palindromic value is not equal to its own reverse', () {
      final forward = ConnectionId(_wireBytes());
      final reversed = ConnectionId(
        Uint8List.fromList(_wireBytes().reversed.toList()),
      );

      expect(forward, isNot(equals(reversed)));
    });
  });

  group('ConnectionId BSATN codec', () {
    test('encodes exactly the 16 wire bytes, in wire order', () {
      final encoder = BsatnEncoder();
      encoder.writeConnectionId(ConnectionId(_wireBytes()));
      final encoded = encoder.toBytes();

      expect(encoded.length, 16);
      expect(encoded, orderedEquals(_wireBytes()));
    });

    test('round-trips through encode then decode', () {
      final original = ConnectionId(_wireBytes());
      final encoder = BsatnEncoder();
      encoder.writeConnectionId(original);

      final decoded = BsatnDecoder(encoder.toBytes()).readConnectionId();

      expect(decoded, equals(original));
      expect(decoded.hashCode, original.hashCode);
      expect(decoded.bytes, orderedEquals(_wireBytes()));
    });
  });

  group('ConnectionId JSON', () {
    test('toJson and fromJson are exact inverses', () {
      final original = ConnectionId(_wireBytes());
      final restored = ConnectionId.fromJson(original.toJson());

      expect(restored, equals(original));
      expect(restored.hashCode, original.hashCode);
      expect(restored.bytes, orderedEquals(original.bytes));
    });

    test('a JSON round-trip preserves the all-zero value', () {
      final zero = ConnectionId(Uint8List(16));
      expect(ConnectionId.fromJson(zero.toJson()), equals(zero));
    });
  });

  group('ConnectionId primary-key safety', () {
    test('values differing only in the last wire byte stay distinct', () {
      final a = ConnectionId(_wireBytes());
      final tweaked = _wireBytes()..[15] = 0x11;
      final b = ConnectionId(tweaked);

      expect(a, isNot(equals(b)));
      expect(a.hashCode, isNot(equals(b.hashCode)));
      expect(a.toString(), isNot(equals(b.toString())));
    });

    test('values differing only in the first wire byte stay distinct', () {
      final a = ConnectionId(_wireBytes());
      final tweaked = _wireBytes()..[0] = 0x99;
      final b = ConnectionId(tweaked);

      expect(a, isNot(equals(b)));
      expect(a.hashCode, isNot(equals(b.hashCode)));
      expect(a.toString(), isNot(equals(b.toString())));
    });

    test('last-byte-only differences occupy distinct map entries', () {
      final a = ConnectionId(_wireBytes());
      final b = ConnectionId(_wireBytes()..[15] = 0x11);

      final map = <dynamic, String>{a: 'first', b: 'second'};

      expect(map.length, 2);
      expect(map[a], 'first');
      expect(map[b], 'second');
      expect(map[ConnectionId(_wireBytes())], 'first');
    });

    test('toString is the full 32-char hex, never abbreviated', () {
      final id = ConnectionId(_wireBytes());

      expect(id.toString().length, 32);
      expect(id.toString(), id.toHexString);
      expect(id.toString(), isNot(contains('...')));
    });

    test('every byte position is reflected in toString and hashCode', () {
      final base = ConnectionId(Uint8List(16));

      for (var i = 0; i < 16; i++) {
        final tweaked = Uint8List(16)..[i] = 0xff;
        final other = ConnectionId(tweaked);

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
