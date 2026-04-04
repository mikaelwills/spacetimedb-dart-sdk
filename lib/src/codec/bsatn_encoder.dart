import 'dart:convert';
import 'dart:typed_data';

import 'package:fixnum/fixnum.dart';
import 'package:spacetimedb_dart_sdk/src/auth/identity.dart';

/// Encodes Dart values into BSATN (Binary Spacetime Algebraic Type Notation) format
///
/// BSATN is SpacetimeDB's binary serialization format. Use this encoder to:
/// - Create reducer/procedure arguments
/// - Encode custom data structures
/// - Build binary messages for SpacetimeDB
///
/// All integers are encoded in little-endian byte order.
///
/// Example:
/// ```dart
/// final encoder = BsatnEncoder();
///
/// // Encode primitive types
/// encoder.writeString('Hello');
/// encoder.writeU32(42);
/// encoder.writeBool(true);
///
/// // Encode optional values
/// encoder.writeOption<String>('value', (v) => encoder.writeString(v));
/// encoder.writeOption<String>(null, (v) => encoder.writeString(v));
///
/// // Encode arrays
/// encoder.writeArray([1, 2, 3], (item) => encoder.writeU32(item));
///
/// // Get the encoded bytes
/// final bytes = encoder.toBytes();
///
/// // Send to SpacetimeDB
/// connection.send(bytes);
/// ```
class BsatnEncoder {
  final BytesBuilder _buffer = BytesBuilder();

  /// Returns the encoded bytes
  ///
  /// Example:
  /// ```dart
  /// final encoder = BsatnEncoder();
  /// encoder.writeU32(123);
  /// final bytes = encoder.toBytes();
  /// ```
  Uint8List toBytes() => _buffer.toBytes();

  int get length => _buffer.length;

  /// Encodes an unsigned 8-bit integer (0-255)
  ///
  /// Example:
  /// ```dart
  /// encoder.writeU8(255);
  /// ```
  void writeU8(int value) {
    if (value < 0 || value > 0xFF) {
      throw ArgumentError.value(value, 'value', 'Must be 0-255 for u8');
    }
    _buffer.addByte(value);
  }

  /// Encodes an unsigned 16-bit integer (0-65535) in little-endian
  ///
  /// Example:
  /// ```dart
  /// encoder.writeU16(65535);
  /// ```
  void writeU16(int value) {
    if (value < 0 || value > 0xFFFF) {
      throw ArgumentError.value(value, 'value', 'Must be 0-65535 for u16');
    }
    _buffer.add([value & 0xFF, (value >> 8) & 0xFF]);
  }

  /// Encodes an unsigned 32-bit integer (0-4294967295) in little-endian
  ///
  /// Example:
  /// ```dart
  /// encoder.writeU32(1000000);
  /// ```
  void writeU32(int value) {
    if (value < 0 || value > 0xFFFFFFFF) {
      throw ArgumentError.value(value, 'value', 'Must be 0-4294967295 for u32');
    }
    _buffer.add([
      value & 0xFF,
      (value >> 8) & 0xFF,
      (value >> 16) & 0xFF,
      (value >> 24) & 0xFF,
    ]);
  }

  void writeU64(Int64 value) {
    final bytes = Uint8List(8);
    final low = value.toInt() & 0xFFFFFFFF;
    final high = (value >> 32).toInt() & 0xFFFFFFFF;
    bytes[0] = low & 0xFF;
    bytes[1] = (low >> 8) & 0xFF;
    bytes[2] = (low >> 16) & 0xFF;
    bytes[3] = (low >> 24) & 0xFF;
    bytes[4] = high & 0xFF;
    bytes[5] = (high >> 8) & 0xFF;
    bytes[6] = (high >> 16) & 0xFF;
    bytes[7] = (high >> 24) & 0xFF;
    _buffer.add(bytes);
  }

  void writeI8(int value) {
    if (value < -128 || value > 127) {
      throw ArgumentError.value(value, 'value', 'Must be -128 to 127 for i8');
    }
    final unsigned = value < 0 ? value + 256 : value;
    writeU8(unsigned);
  }

  void writeI16(int value) {
    if (value < -32768 || value > 32767) {
      throw ArgumentError.value(
        value,
        'value',
        'Must be -32768 to 32767 for i16',
      );
    }
    final unsigned = value < 0 ? value + 65536 : value;
    writeU16(unsigned);
  }

  void writeI32(int value) {
    if (value < -2147483648 || value > 2147483647) {
      throw ArgumentError.value(
        value,
        'value',
        'Must be -2147483648 to 2147483647 for i32',
      );
    }
    final unsigned = value < 0 ? value + 4294967296 : value;
    writeU32(unsigned);
  }

  void writeI64(Int64 value) {
    final bytes = Uint8List(8);
    final low = value.toInt() & 0xFFFFFFFF;
    final high = (value >> 32).toInt() & 0xFFFFFFFF;
    bytes[0] = low & 0xFF;
    bytes[1] = (low >> 8) & 0xFF;
    bytes[2] = (low >> 16) & 0xFF;
    bytes[3] = (low >> 24) & 0xFF;
    bytes[4] = high & 0xFF;
    bytes[5] = (high >> 8) & 0xFF;
    bytes[6] = (high >> 16) & 0xFF;
    bytes[7] = (high >> 24) & 0xFF;
    _buffer.add(bytes);
  }

  void writeF32(double value) {
    final data = ByteData(4);
    data.setFloat32(0, value, Endian.little);
    _buffer.add(data.buffer.asUint8List());
  }

  void writeF64(double value) {
    final data = ByteData(8);
    data.setFloat64(0, value, Endian.little);
    _buffer.add(data.buffer.asUint8List());
  }

  /// Encodes a boolean value (false = 0, true = 1)
  ///
  /// Example:
  /// ```dart
  /// encoder.writeBool(true);
  /// ```
  void writeBool(bool value) {
    _buffer.addByte(value ? 1 : 0);
  }

  /// Encodes a UTF-8 string with length prefix
  ///
  /// Format: u32 length + UTF-8 bytes
  ///
  /// Example:
  /// ```dart
  /// encoder.writeString('Hello, SpacetimeDB!');
  /// ```
  void writeString(String value) {
    final bytes = utf8.encode(value);
    writeU32(bytes.length);
    _buffer.add(bytes);
  }

  void writeBytes(Uint8List bytes) {
    _buffer.add(bytes);
  }

  void writeIdentity(Identity value) {
    writeBytes(value.bytes);
  }

  void writeByteArray(List<int> value) {
    writeU32(value.length);
    _buffer.add(value);
  }

  /// Encodes an optional value
  ///
  /// Format: bool discriminant (false = None, true = Some) + value if Some
  ///
  /// Example:
  /// ```dart
  /// // Encode Some(42)
  /// encoder.writeOption<int>(42, (v) => encoder.writeU32(v));
  ///
  /// // Encode None
  /// encoder.writeOption<int>(null, (v) => encoder.writeU32(v));
  /// ```
  void writeOption<T>(T? value, void Function(T) writeValue) {
    if (value == null) {
      writeBool(false);
    } else {
      writeBool(true);
      writeValue(value);
    }
  }

  /// Encodes an array with length prefix
  ///
  /// Format: u32 length + elements
  ///
  /// Example:
  /// ```dart
  /// encoder.writeArray([1, 2, 3, 4, 5], (item) => encoder.writeU32(item));
  /// ```
  void writeArray<T>(List<T> items, void Function(T) writeItem) {
    writeU32(items.length);
    for (final item in items) {
      writeItem(item);
    }
  }

  void writeList<T>(List<T> items, void Function(T) writeItems) {
    writeArray(items, writeItems);
  }

  /// Encodes a map with length prefix
  ///
  /// Format: u32 length + (key, value) pairs
  ///
  /// Example:
  /// ```dart
  /// final map = {'a': 1, 'b': 2};
  /// encoder.writeMap(
  ///   map,
  ///   (key) => encoder.writeString(key),
  ///   (value) => encoder.writeU32(value),
  /// );
  /// ```
  void writeMap<K, V>(
    Map<K, V> map,
    void Function(K) writeKey,
    void Function(V) writeValue,
  ) {
    writeU32(map.length);
    for (final entry in map.entries) {
      writeKey(entry.key);
      writeValue(entry.value);
    }
  }

  void writeProduct(List<void Function()> writeFields) {
    for (final writeField in writeFields) {
      writeField();
    }
  }

  void writeSum(int tag, void Function() writeVariant) {
    writeU8(tag);
    writeVariant();
  }
}
