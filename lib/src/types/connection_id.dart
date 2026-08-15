import 'dart:typed_data';

/// A SpacetimeDB connection identifier: one live client socket.
///
/// A single [Identity] can hold several concurrent connections (multiple
/// windows, desktop plus mobile, or a client that deliberately opens more than
/// one socket), so a `ConnectionId` is the natural key for per-connection
/// presence tables.
///
/// Wire form is a 128-bit unsigned integer, 16 bytes **little-endian**, which is
/// the order [bytes] holds. The conventional hex string is **big-endian** — the
/// reverse of [bytes] — matching upstream `to_hex`/`from_hex`.
class ConnectionId {
  static const int byteLength = 16;

  /// The raw 16 bytes in wire (little-endian) order.
  final Uint8List bytes;

  /// Create a connection id from 16 little-endian wire bytes.
  ///
  /// Throws [ArgumentError] if [bytes] is not exactly 16 bytes long.
  ConnectionId(this.bytes) {
    if (bytes.length != byteLength) {
      throw ArgumentError(
        'ConnectionId must be exactly $byteLength bytes, got ${bytes.length}',
      );
    }
  }

  /// Create a connection id from 16 big-endian bytes, as written in hex.
  factory ConnectionId.fromBigEndianBytes(Uint8List beBytes) {
    if (beBytes.length != byteLength) {
      throw ArgumentError(
        'ConnectionId must be exactly $byteLength bytes, got ${beBytes.length}',
      );
    }
    return ConnectionId(Uint8List.fromList(beBytes.reversed.toList()));
  }

  /// Parse the 32-character big-endian hex form.
  factory ConnectionId.fromHexString(String hex) {
    final normalized = hex.startsWith('0x') ? hex.substring(2) : hex;
    if (normalized.length != byteLength * 2) {
      throw ArgumentError(
        'ConnectionId hex must be ${byteLength * 2} characters, '
        'got ${normalized.length}',
      );
    }
    final beBytes = Uint8List(byteLength);
    for (var i = 0; i < byteLength; i++) {
      beBytes[i] = int.parse(normalized.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return ConnectionId.fromBigEndianBytes(beBytes);
  }

  /// The 16 bytes in big-endian order, most significant first.
  Uint8List get bigEndianBytes => Uint8List.fromList(bytes.reversed.toList());

  /// Full 32-character big-endian hex string.
  String get toHexString =>
      bigEndianBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  /// Shortened hex form for UI display: the first 16 big-endian hex characters.
  ///
  /// Display only — never use this as a key. Two distinct connection ids can
  /// share an abbreviation.
  String get toAbbreviated => toHexString.substring(0, 16);

  String toJson() => toHexString;

  static ConnectionId fromJson(String hex) => ConnectionId.fromHexString(hex);

  @override
  bool operator ==(Object other) {
    if (other is! ConnectionId) return false;
    for (var i = 0; i < byteLength; i++) {
      if (bytes[i] != other.bytes[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(bytes);

  @override
  String toString() => toHexString;
}
