import 'dart:typed_data';

/// An RFC 4122 universally unique identifier.
///
/// The canonical byte array is 16 bytes **big-endian**, most significant byte
/// first, and the string form is the hyphenated 8-4-4-4-12 grouping — both per
/// RFC 4122, matching upstream `Uuid`.
///
/// The BSATN wire form is a 128-bit unsigned integer written little-endian, so
/// the bytes on the wire are the reverse of [bytes]. The codec handles that
/// conversion; consumers work in canonical order.
class Uuid {
  static const int byteLength = 16;

  static final Uuid nil = Uuid(Uint8List(byteLength));

  /// The canonical 16 bytes in big-endian (RFC 4122) order.
  final Uint8List bytes;

  /// Create a UUID from its 16 canonical big-endian bytes.
  ///
  /// Throws [ArgumentError] if [bytes] is not exactly 16 bytes long.
  Uuid(this.bytes) {
    if (bytes.length != byteLength) {
      throw ArgumentError(
        'Uuid must be exactly $byteLength bytes, got ${bytes.length}',
      );
    }
  }

  /// Create a UUID from 16 little-endian bytes, as carried on the BSATN wire.
  factory Uuid.fromLittleEndianBytes(Uint8List leBytes) {
    if (leBytes.length != byteLength) {
      throw ArgumentError(
        'Uuid must be exactly $byteLength bytes, got ${leBytes.length}',
      );
    }
    return Uuid(Uint8List.fromList(leBytes.reversed.toList()));
  }

  /// Parse the hyphenated 8-4-4-4-12 form, with or without hyphens.
  factory Uuid.parse(String source) {
    final hex = source.replaceAll('-', '').toLowerCase();
    if (hex.length != byteLength * 2) {
      throw ArgumentError('Invalid UUID string: $source');
    }
    final parsed = Uint8List(byteLength);
    for (var i = 0; i < byteLength; i++) {
      final byte = int.tryParse(hex.substring(i * 2, i * 2 + 2), radix: 16);
      if (byte == null) {
        throw ArgumentError('Invalid UUID string: $source');
      }
      parsed[i] = byte;
    }
    return Uuid(parsed);
  }

  /// The 16 bytes in little-endian order, as written on the BSATN wire.
  Uint8List get littleEndianBytes =>
      Uint8List.fromList(bytes.reversed.toList());

  /// The 32-character unhyphenated hex form, big-endian.
  String get toHexString =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  /// The RFC 4122 hyphenated form, e.g. `01888d6e-5c00-7000-8000-000000000000`.
  String get toHyphenatedString {
    final hex = toHexString;
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20)}';
  }

  String toJson() => toHyphenatedString;

  static Uuid fromJson(String source) => Uuid.parse(source);

  @override
  bool operator ==(Object other) {
    if (other is! Uuid) return false;
    for (var i = 0; i < byteLength; i++) {
      if (bytes[i] != other.bytes[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(bytes);

  @override
  String toString() => toHyphenatedString;
}
