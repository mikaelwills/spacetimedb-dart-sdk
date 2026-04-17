import 'package:fixnum/fixnum.dart';

import '../messages/server_messages.dart';
import '../messages/update_status.dart';

/// Result of a reducer call, containing execution status and metadata.
///
/// Returned when awaiting a reducer call that completed without throwing.
/// `Failed` and `OutOfEnergy` statuses never reach this object — the
/// underlying call throws `SpacetimeDbReducerException` in those cases, so
/// the only statuses you'll observe here are `Committed`, `Pending`, and
/// `Dropped`. This means `if (result.isSuccess) { ... } else { ... }` has a
/// dead failure branch; use try/catch for failures and inspect the result for
/// metadata (energy, timestamp) or the `Pending`/`Dropped` offline states.
///
/// ```dart
/// try {
///   final result = await client.reducers.createNote(title: 'Hi', body: 'there');
///   print('energy: ${result.energyConsumed}');
///   if (result.isPending) print('queued offline, will sync on reconnect');
/// } on SpacetimeDbReducerException catch (e) {
///   print('reducer failed: ${e.message}');
/// }
/// ```
class TransactionResult {
  /// The status of the transaction (Committed, Failed, or OutOfEnergy)
  final UpdateStatus status;

  /// Timestamp when the reducer started
  final DateTime timestamp;

  /// Energy consumed by this reducer execution
  ///
  /// `null` means unavailable (e.g., TransactionUpdateLight).
  /// `0` means the reducer was free (no energy charged).
  final int? energyConsumed;

  /// Total execution duration
  ///
  /// `null` means unavailable (e.g., TransactionUpdateLight).
  final Duration? executionDuration;

  /// The reducer name (null for TransactionUpdateLight)
  final String? reducerName;

  final int? reducerId;

  final bool isLightUpdate;

  final bool isPending;

  final String? pendingRequestId;

  TransactionResult({
    required this.status,
    required this.timestamp,
    this.energyConsumed,
    this.executionDuration,
    this.reducerName,
    this.reducerId,
    this.isLightUpdate = false,
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

  /// Create result from a full TransactionUpdate message
  factory TransactionResult.fromTransactionUpdate(
    TransactionUpdateMessage message,
  ) {
    return TransactionResult(
      status: message.status,
      timestamp: DateTime.fromMicrosecondsSinceEpoch(
        (message.timestamp ~/ Int64(1000)).toInt(),
      ),
      energyConsumed: message.energyQuantaUsed,
      executionDuration: Duration(
        microseconds: message.totalHostExecutionDuration.toInt(),
      ),
      reducerName: message.reducerCall.reducerName,
      reducerId: message.reducerCall.reducerId,
      isLightUpdate: false,
    );
  }

  /// Create result from a lightweight TransactionUpdateLight message
  factory TransactionResult.fromTransactionUpdateLight(
    TransactionUpdateLightMessage message,
  ) {
    return TransactionResult(
      status: Committed(), // Light updates always mean success
      timestamp:
          DateTime.now(), // Approximate - server doesn't provide timestamp
      energyConsumed: null, // Not available in light updates
      executionDuration: null, // Not available in light updates
      reducerName: null,
      reducerId: null,
      isLightUpdate: true,
    );
  }

  /// Whether the transaction was committed successfully
  ///
  /// Note: Returns false for pending (queued offline) mutations.
  /// Use [isSuccessOrPending] if you want to treat queued mutations as success.
  bool get isSuccess => status is Committed;

  /// Whether the transaction was committed or queued for later sync
  ///
  /// Use this when you want to treat offline-queued mutations as successful.
  /// The mutation will be synced when connectivity is restored.
  bool get isSuccessOrPending => status is Committed || status is Pending;

  /// Whether the transaction failed
  bool get isFailed => status is Failed;

  /// Whether the transaction ran out of energy
  bool get isOutOfEnergy => status is OutOfEnergy;

  bool get isDropped => status is Dropped;

  /// Get error message if failed, otherwise null
  String? get errorMessage {
    final s = status;
    if (s is Failed) {
      return s.message;
    }
    if (s is OutOfEnergy) {
      return 'Out of energy';
    }
    return null;
  }

  @override
  String toString() {
    final energyStr = energyConsumed != null ? '$energyConsumed' : 'unknown';
    final durationStr =
        executionDuration != null
            ? '${executionDuration!.inMilliseconds}ms'
            : 'unknown';
    return 'TransactionResult('
        'status: ${status.runtimeType}, '
        'reducer: $reducerName, '
        'duration: $durationStr, '
        'energy: $energyStr, '
        'isLight: $isLightUpdate'
        ')';
  }
}
