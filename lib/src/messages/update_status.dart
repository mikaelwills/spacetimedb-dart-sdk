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

  String get errorMessage => utf8.decode(errorBytes, allowMalformed: true);

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
