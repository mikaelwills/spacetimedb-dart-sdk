import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:spacetimedb_dart_sdk/spacetimedb_dart_sdk.dart';

void main() {
  group('Identity', () {
    test('creates identity from 32 bytes', () {
      final bytes = Uint8List.fromList(List.generate(32, (i) => i));
      final identity = Identity(bytes);

      expect(identity.bytes, equals(bytes));
      expect(identity.bytes.length, equals(32));
    });

    test('throws on incorrect byte length', () {
      expect(() => Identity(Uint8List(16)), throwsA(isA<ArgumentError>()));

      expect(() => Identity(Uint8List(64)), throwsA(isA<ArgumentError>()));
    });

    test('toHexString produces correct 64-character hex string', () {
      // Create identity with known bytes
      final bytes = Uint8List.fromList([
        0x2a, 0xb4, 0xc3, 0xd5, 0xe6, 0xf7, 0xa8, 0xb9, // First 8 bytes
        0xc0, 0xd1, 0xe2, 0xf3, 0xa4, 0xb5, 0xc6, 0xd7, // Next 8 bytes
        0xe8, 0xf9, 0xa0, 0xb1, 0xc2, 0xd3, 0xe4, 0xf5, // Next 8 bytes
        0xa6, 0xb7, 0xc8, 0xd9, 0xe0, 0xf1, 0xa2, 0xb3, // Last 8 bytes
      ]);
      final identity = Identity(bytes);

      final hex = identity.toHexString;
      expect(hex.length, equals(64));
      expect(hex, startsWith('2ab4c3d5'));
      expect(hex, endsWith('a2b3'));
    });

    test('toAbbreviated produces correct shortened format', () {
      final bytes = Uint8List.fromList([
        0x2a,
        0xb4,
        0xc3,
        0xd5,
        0xe6,
        0xf7,
        0xa8,
        0xb9,
        0xc0,
        0xd1,
        0xe2,
        0xf3,
        0xa4,
        0xb5,
        0xc6,
        0xd7,
        0xe8,
        0xf9,
        0xa0,
        0xb1,
        0xc2,
        0xd3,
        0xe4,
        0xf5,
        0xa6,
        0xb7,
        0xc8,
        0xd9,
        0xe0,
        0xf1,
        0xa2,
        0xb3,
      ]);
      final identity = Identity(bytes);

      final abbreviated = identity.toAbbreviated;
      expect(abbreviated, equals('2ab4...a2b3'));
    });

    test('equals compares identity bytes correctly', () {
      final bytes1 = Uint8List.fromList(List.generate(32, (i) => i));
      final bytes2 = Uint8List.fromList(List.generate(32, (i) => i));
      final bytes3 = Uint8List.fromList(List.generate(32, (i) => i + 1));

      final identity1 = Identity(bytes1);
      final identity2 = Identity(bytes2);
      final identity3 = Identity(bytes3);

      expect(identity1.equals(identity2), isTrue);
      expect(identity1.equals(identity3), isFalse);
    });

    test('== operator works correctly', () {
      final bytes1 = Uint8List.fromList(List.generate(32, (i) => i));
      final bytes2 = Uint8List.fromList(List.generate(32, (i) => i));
      final bytes3 = Uint8List.fromList(List.generate(32, (i) => i + 1));

      final identity1 = Identity(bytes1);
      final identity2 = Identity(bytes2);
      final identity3 = Identity(bytes3);

      expect(identity1 == identity2, isTrue);
      expect(identity1 == identity3, isFalse);
    });

    test('hashCode is consistent for equal identities', () {
      final bytes1 = Uint8List.fromList(List.generate(32, (i) => i));
      final bytes2 = Uint8List.fromList(List.generate(32, (i) => i));

      final identity1 = Identity(bytes1);
      final identity2 = Identity(bytes2);

      expect(identity1.hashCode, equals(identity2.hashCode));
    });

    test('toString returns abbreviated format', () {
      final bytes = Uint8List.fromList([
        0x2a,
        0xb4,
        0xc3,
        0xd5,
        0xe6,
        0xf7,
        0xa8,
        0xb9,
        0xc0,
        0xd1,
        0xe2,
        0xf3,
        0xa4,
        0xb5,
        0xc6,
        0xd7,
        0xe8,
        0xf9,
        0xa0,
        0xb1,
        0xc2,
        0xd3,
        0xe4,
        0xf5,
        0xa6,
        0xb7,
        0xc8,
        0xd9,
        0xe0,
        0xf1,
        0xa2,
        0xb3,
      ]);
      final identity = Identity(bytes);

      expect(identity.toString(), equals('2ab4...a2b3'));
    });

    test('hex string handles leading zeros correctly', () {
      final bytes = Uint8List.fromList([
        0x00,
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
        0x11,
        0x12,
        0x13,
        0x14,
        0x15,
        0x16,
        0x17,
        0x18,
        0x19,
        0x1a,
        0x1b,
        0x1c,
        0x1d,
        0x1e,
        0x1f,
      ]);
      final identity = Identity(bytes);

      final hex = identity.toHexString;
      expect(hex, startsWith('00010203'));
      expect(hex.length, equals(64));
    });
  });
}
