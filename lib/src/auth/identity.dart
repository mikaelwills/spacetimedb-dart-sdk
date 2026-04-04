import 'dart:typed_data';

/// SpacetimeDB user identity
///
/// Represents a 32-byte public key hash that uniquely identifies a user.
/// Can be displayed as a hex string for UI purposes (ownership checks, avatars, etc.).
class Identity {
  /// The raw 32-byte identity
  final Uint8List bytes;

  /// Create an identity from 32 bytes
  ///
  /// Throws [ArgumentError] if bytes length is not exactly 32.
  Identity(this.bytes) {
    if (bytes.length != 32) {
      throw ArgumentError(
        'Identity must be exactly 32 bytes, got ${bytes.length}',
      );
    }
  }

  /// Full hex string representation (64 characters)
  ///
  /// Example: "2ab4c3d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b3"
  String get toHexString {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Abbreviated hex string for UI display (first 4 + last 4 chars)
  ///
  /// Example: "2ab4...a2b3"
  ///
  /// Perfect for avatars, user badges, and compact displays.
  String get toAbbreviated {
    final hex = toHexString;
    return '${hex.substring(0, 4)}...${hex.substring(60)}';
  }

  /// Check equality with another identity
  bool equals(Identity other) {
    if (bytes.length != other.bytes.length) return false;
    for (int i = 0; i < bytes.length; i++) {
      if (bytes[i] != other.bytes[i]) return false;
    }
    return true;
  }

  @override
  bool operator ==(Object other) {
    return other is Identity && equals(other);
  }

  @override
  int get hashCode {
    // Simple hash combining first 4 bytes
    return (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];
  }

  String toJson() => toHexString;

  static Identity fromJson(String hex) {
    final bytes = Uint8List(32);
    for (int i = 0; i < 32; i++) {
      bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return Identity(bytes);
  }

  @override
  String toString() => toAbbreviated;
}
