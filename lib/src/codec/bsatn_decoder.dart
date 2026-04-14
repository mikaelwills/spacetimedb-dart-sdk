import 'dart:convert';
import 'dart:typed_data';

import 'package:fixnum/fixnum.dart';
import 'package:spacetimedb_dart_sdk/src/auth/identity.dart';
import 'package:spacetimedb_dart_sdk/src/exceptions.dart';

/// Decodes BSATN (Binary Spacetime Algebraic Type Notation) format into Dart values
///
/// BSATN is SpacetimeDB's binary serialization format. Use this decoder to:
/// - Parse incoming messages from SpacetimeDB
/// - Decode table rows
/// - Read reducer results
///
/// All integers are decoded from little-endian byte order.
///
/// Example:
/// ```dart
/// final bytes = Uint8List.fromList([...]);
/// final decoder = BsatnDecoder(bytes);
///
/// // Decode primitive types
/// final text = decoder.readString();
/// final number = decoder.readU32();
/// final flag = decoder.readBool();
///
/// // Decode optional values
/// final maybeValue = decoder.readOption<String>(() => decoder.readString());
///
/// // Decode arrays
/// final numbers = decoder.readArray<int>(() => decoder.readU32());
/// ```
class BsatnDecoder {
  final Uint8List _bytes;
  int _offset = 0;

  BsatnDecoder(this._bytes);

  int get offset => _offset;
  int get remaining => _bytes.length - _offset;

  /// Debug helper: Dump next N bytes as hex
  String hexDump(int length) {
    final end = (_offset + length).clamp(0, _bytes.length);
    final bytes = _bytes.sublist(_offset, end);
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
    return 'offset=$_offset: $hex';
  }

  /// Debug helper: Dump all remaining bytes as hex
  String hexDumpAll() {
    return hexDump(remaining);
  }

  /// Decodes an unsigned 8-bit integer (0-255)
  ///
  /// Example:
  /// ```dart
  /// final value = decoder.readU8();
  /// ```
  int readU8() {
    _checkRemaining(1);
    return _bytes[_offset++];
  }

  int readU16() {
    _checkRemaining(2);
    final value = _bytes[_offset] | (_bytes[_offset + 1] << 8);
    _offset += 2;
    return value;
  }

  /// Decodes an unsigned 32-bit integer from little-endian bytes
  ///
  /// Example:
  /// ```dart
  /// final value = decoder.readU32();
  /// ```
  int readU32() {
    _checkRemaining(4);
    final value =
        _bytes[_offset] |
        (_bytes[_offset + 1] << 8) |
        (_bytes[_offset + 2] << 16) |
        (_bytes[_offset + 3] << 24);
    _offset += 4;
    return value;
  }

  Int64 readU64() {
    _checkRemaining(8);
    final low =
        _bytes[_offset] |
        (_bytes[_offset + 1] << 8) |
        (_bytes[_offset + 2] << 16) |
        (_bytes[_offset + 3] << 24);
    final high =
        _bytes[_offset + 4] |
        (_bytes[_offset + 5] << 8) |
        (_bytes[_offset + 6] << 16) |
        (_bytes[_offset + 7] << 24);
    _offset += 8;
    return Int64.fromInts(high, low);
  }

  int readI8() {
    final unsigned = readU8();
    return unsigned > 127 ? unsigned - 256 : unsigned;
  }

  int readI16() {
    final unsigned = readU16();
    return unsigned > 32767 ? unsigned - 65536 : unsigned;
  }

  int readI32() {
    final unsigned = readU32();
    return unsigned > 2147483647 ? unsigned - 4294967296 : unsigned;
  }

  Int64 readI64() {
    _checkRemaining(8);
    final low =
        _bytes[_offset] |
        (_bytes[_offset + 1] << 8) |
        (_bytes[_offset + 2] << 16) |
        (_bytes[_offset + 3] << 24);
    final high =
        _bytes[_offset + 4] |
        (_bytes[_offset + 5] << 8) |
        (_bytes[_offset + 6] << 16) |
        (_bytes[_offset + 7] << 24);
    _offset += 8;
    return Int64.fromInts(high, low);
  }

  double readF32() {
    _checkRemaining(4);
    final data = ByteData.sublistView(_bytes, _offset, _offset + 4);
    final value = data.getFloat32(0, Endian.little);
    _offset += 4;
    return value;
  }

  double readF64() {
    _checkRemaining(8);
    final data = ByteData.sublistView(_bytes, _offset, _offset + 8);
    final value = data.getFloat64(0, Endian.little);
    _offset += 8;
    return value;
  }

  /// Decodes a boolean value (0 = false, 1 = true)
  ///
  /// Throws [FormatException] if the byte is not 0 or 1.
  ///
  /// Example:
  /// ```dart
  /// final flag = decoder.readBool();
  /// ```
  bool readBool() {
    final byte = readU8();
    if (byte > 1) {
      throw SpacetimeDbProtocolException(
        'Invalid boolean value: $byte (expected 0 or 1)',
      );
    }
    return byte == 1;
  }

  /// Decodes a UTF-8 string with length prefix
  ///
  /// Format: u32 length + UTF-8 bytes
  ///
  /// Example:
  /// ```dart
  /// final text = decoder.readString();
  /// ```
  String readString() {
    final length = readU32();
    _checkRemaining(length);

    final bytes = _bytes.sublist(_offset, _offset + length);
    _offset += length;

    return utf8.decode(bytes);
  }

  Uint8List readBytes(int length) {
    _checkRemaining(length);
    final bytes = Uint8List.fromList(_bytes.sublist(_offset, _offset + length));
    _offset += length;
    return bytes;
  }

  Identity readIdentity() {
    return Identity(readBytes(32));
  }

  List<int> readByteArray() {
    final length = readU32();
    return readBytes(length).toList();
  }

  /// Decodes an optional value
  ///
  /// Format: bool discriminant (false = None, true = Some) + value if Some
  ///
  /// Returns null if the discriminant is false, otherwise returns the decoded value.
  ///
  /// Example:
  /// ```dart
  /// final maybeText = decoder.readOption<String>(() => decoder.readString());
  /// if (maybeText != null) {
  ///   print('Got: $maybeText');
  /// }
  /// ```
  T? readOption<T>(T Function() readValue) {
    final hasValue = readBool();
    if (!hasValue) {
      return null;
    }
    return readValue();
  }

  /// Decodes an array with length prefix
  ///
  /// Format: u32 length + elements
  ///
  /// Example:
  /// ```dart
  /// final numbers = decoder.readArray<int>(() => decoder.readU32());
  /// ```
  List<T> readArray<T>(T Function() readItem) {
    final length = readU32();
    final items = <T>[];
    for (int i = 0; i < length; i++) {
      items.add(readItem());
    }

    return items;
  }

  List<T> readList<T>(T Function() readItem) {
    return readArray(readItem);
  }

  /// Decodes a map with length prefix
  ///
  /// Format: u32 length + (key, value) pairs
  ///
  /// Example:
  /// ```dart
  /// final map = decoder.readMap<String, int>(
  ///   () => decoder.readString(),
  ///   () => decoder.readU32(),
  /// );
  /// ```
  Map<K, V> readMap<K, V>(K Function() readKey, V Function() readValue) {
    final length = readU32();
    final map = <K, V>{};

    for (int i = 0; i < length; i++) {
      final key = readKey();
      final value = readValue();
      map[key] = value;
    }

    return map;
  }

  void _checkRemaining(int needed) {
    if (_offset + needed > _bytes.length) {
      throw SpacetimeDbProtocolException(
        'Not enough bytes: need $needed, have $remaining at offset $_offset',
      );
    }
  }
}
