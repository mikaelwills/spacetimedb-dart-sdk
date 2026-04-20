import 'dart:typed_data';

import 'package:fixnum/fixnum.dart';

import '../messages/server_messages.dart';
import '../messages/update_status.dart';

/// Result of a reducer call.
///
/// On v2 this is built by the caller-side `ReducerResult` handler (slice 4).
/// `Failed` / `InternalError` statuses do not reach consumers directly —
/// `ReducerCaller.completeRequest` throws `SpacetimeDbReducerException` in
/// those cases — so observed statuses here are `Committed`, `Pending`, and
/// `Dropped`.
class TransactionResult {
  final UpdateStatus status;
  final DateTime timestamp;
  final String? reducerName;
  final int? reducerId;

  /// BSATN-encoded reducer return value. `null` when the reducer was unit-return
  /// (current Rust macro constraint) or when the wire sent `OkEmpty`. Populated
  /// in slice 4 from `ReducerOk.ret_value`.
  final Uint8List? retValue;

  final bool isPending;
  final String? pendingRequestId;

  TransactionResult({
    required this.status,
    required this.timestamp,
    this.reducerName,
    this.reducerId,
    this.retValue,
    this.isPending = false,
    this.pendingRequestId,
  });

  factory TransactionResult.pending({
    required String reducerName,
    required String requestId,
  }) {
    return TransactionResult(
      status: Pending(),
      timestamp: DateTime.now(),
      reducerName: reducerName,
      isPending: true,
      pendingRequestId: requestId,
    );
  }

  factory TransactionResult.dropped({required String reducerName}) {
    return TransactionResult(
      status: Dropped(),
      timestamp: DateTime.now(),
      reducerName: reducerName,
    );
  }

  /// Build from a v2 `ReducerResult`. Timestamp is microseconds-since-epoch
  /// (canonical `sats/src/timestamp.rs:11-14`). `OkEmpty` and zero-length
  /// `Ok.ret_value` both collapse to `retValue: null`.
  factory TransactionResult.fromReducerResult(
    ReducerResultMessage message, {
    required String reducerName,
    int? reducerId,
  }) {
    return TransactionResult(
      status: message.status,
      timestamp: DateTime.fromMicrosecondsSinceEpoch(
        (message.timestamp ~/ Int64(1000)).toInt(),
      ),
      reducerName: reducerName,
      reducerId: reducerId,
      retValue: message.retValue,
    );
  }

  bool get isSuccess => status is Committed;

  bool get isSuccessOrPending => status is Committed || status is Pending;

  bool get isFailed => status is Failed;

  bool get isInternalError => status is InternalError;

  bool get isDropped => status is Dropped;

  String? get errorMessage {
    final s = status;
    if (s is Failed) return s.errorMessage;
    if (s is InternalError) return s.message;
    return null;
  }

  @override
  String toString() =>
      'TransactionResult(status: ${status.runtimeType}, reducer: $reducerName)';
}
