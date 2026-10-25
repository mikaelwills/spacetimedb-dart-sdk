import 'dart:convert';
import 'dart:typed_data';

/// Status of a reducer transaction.
///
/// Wire: v2 `ReducerOutcome` (`v2.rs:385-406`) — decoded in slice 4 via
/// `ReducerResult`. `Pending`/`Dropped` are SDK-synthetic (offline queue).
sealed class UpdateStatus {}

class Committed extends UpdateStatus {
  @override
  String toString() => 'Committed()';
}

class Failed extends UpdateStatus {
  final Uint8List errorBytes;

  Failed(this.errorBytes);

  String get errorMessage {
    if (errorBytes.length >= 4) {
      final length = ByteData.sublistView(
        errorBytes,
        0,
        4,
      ).getUint32(0, Endian.little);
      if (length == errorBytes.length - 4) {
        return utf8.decode(errorBytes.sublist(4), allowMalformed: true);
      }
    }
    return utf8.decode(errorBytes, allowMalformed: true);
  }

  @override
  String toString() => 'Failed(message: $errorMessage)';
}

class InternalError extends UpdateStatus {
  final String message;

  InternalError(this.message);

  @override
  String toString() => 'InternalError(message: $message)';
}

class Pending extends UpdateStatus {
  @override
  String toString() => 'Pending()';
}

class Dropped extends UpdateStatus {
  @override
  String toString() => 'Dropped()';
}
