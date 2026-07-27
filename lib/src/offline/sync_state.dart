import 'optimistic_change.dart';

enum SyncStatus { idle, syncing, waitingToRetry, error }

class MutationSyncResult {
  final String requestId;
  final String reducerName;
  final bool success;
  final String? error;
  final bool expired;
  final List<OptimisticChange>? optimisticChanges;

  const MutationSyncResult({
    required this.requestId,
    required this.reducerName,
    required this.success,
    this.error,
    this.expired = false,
    this.optimisticChanges,
  });

  @override
  String toString() {
    return 'MutationSyncResult(requestId: $requestId, reducer: $reducerName, success: $success)';
  }
}

class SyncState {
  final SyncStatus status;
  final int pendingCount;
  final String? lastError;
  final DateTime? lastSyncTime;
  final DateTime? nextRetryAt;
  final int failedCount;
  final List<MutationSyncResult> recentFailures;

  const SyncState({
    this.status = SyncStatus.idle,
    this.pendingCount = 0,
    this.lastError,
    this.lastSyncTime,
    this.nextRetryAt,
    this.failedCount = 0,
    this.recentFailures = const [],
  });

  bool get hasPending => pendingCount > 0;
  bool get isSyncing => status == SyncStatus.syncing;
  bool get isIdle => status == SyncStatus.idle;
  bool get isWaitingToRetry => status == SyncStatus.waitingToRetry;
  bool get hasError => failedCount > 0 || status == SyncStatus.error;

  SyncState copyWith({
    SyncStatus? status,
    int? pendingCount,
    String? lastError,
    DateTime? lastSyncTime,
    DateTime? nextRetryAt,
    bool clearNextRetryAt = false,
    int? failedCount,
    List<MutationSyncResult>? recentFailures,
  }) {
    return SyncState(
      status: status ?? this.status,
      pendingCount: pendingCount ?? this.pendingCount,
      lastError: lastError ?? this.lastError,
      lastSyncTime: lastSyncTime ?? this.lastSyncTime,
      nextRetryAt: clearNextRetryAt ? null : (nextRetryAt ?? this.nextRetryAt),
      failedCount: failedCount ?? this.failedCount,
      recentFailures: recentFailures ?? this.recentFailures,
    );
  }

  @override
  String toString() {
    return 'SyncState(status: $status, pending: $pendingCount, failed: $failedCount)';
  }
}
