enum SyncStatus { idle, syncing, error }

class MutationSyncResult {
  final String requestId;
  final String reducerName;
  final bool success;
  final String? error;

  const MutationSyncResult({
    required this.requestId,
    required this.reducerName,
    required this.success,
    this.error,
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

  const SyncState({
    this.status = SyncStatus.idle,
    this.pendingCount = 0,
    this.lastError,
    this.lastSyncTime,
  });

  bool get hasPending => pendingCount > 0;
  bool get isSyncing => status == SyncStatus.syncing;
  bool get isIdle => status == SyncStatus.idle;
  bool get hasError => status == SyncStatus.error;

  SyncState copyWith({
    SyncStatus? status,
    int? pendingCount,
    String? lastError,
    DateTime? lastSyncTime,
  }) {
    return SyncState(
      status: status ?? this.status,
      pendingCount: pendingCount ?? this.pendingCount,
      lastError: lastError ?? this.lastError,
      lastSyncTime: lastSyncTime ?? this.lastSyncTime,
    );
  }

  @override
  String toString() {
    return 'SyncState(status: $status, pending: $pendingCount)';
  }
}
