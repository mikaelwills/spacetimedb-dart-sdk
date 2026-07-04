import 'dart:async';
import 'dart:typed_data';

import 'package:spacetimedb_sdk/src/cache/client_cache.dart';
import 'package:spacetimedb_sdk/src/connection/spacetimedb_connection.dart';
import 'package:spacetimedb_sdk/src/connection/connection_state.dart';
import 'package:spacetimedb_sdk/src/exceptions.dart';
import 'package:spacetimedb_sdk/src/reducers/transaction_result.dart';
import 'package:spacetimedb_sdk/src/reducers/mutation_handler.dart';
import 'package:spacetimedb_sdk/src/offline/offline_queue_policy.dart';
import 'package:spacetimedb_sdk/src/offline/offline_storage.dart';
import 'package:spacetimedb_sdk/src/offline/optimistic_state_manager.dart';
import 'package:spacetimedb_sdk/src/offline/pending_mutation.dart';
import 'package:spacetimedb_sdk/src/offline/sync_state.dart';
import 'package:spacetimedb_sdk/src/utils/sdk_logger.dart';

typedef SendReducer =
    Future<TransactionResult> Function(
      String reducerName,
      Uint8List args, {
      String? requestId,
    });

class MutationSyncer implements MutationHandler {
  final SpacetimeDbConnection _connection;
  final OfflineStorage _storage;
  final OptimisticStateManager _optimisticState;
  final ClientCache _cache;
  final SendReducer _send;
  final OfflineQueuePolicy _policy;

  bool _isSyncing = false;
  bool _disposed = false;
  bool _storageInitialized = false;
  int _cachedPendingCount = 0;
  SyncState _currentSyncState = const SyncState();

  Timer? _retryTimer;
  int _retryAttempt = 0;
  static const Duration _initialRetryDelay = Duration(seconds: 5);
  static const Duration _maxRetryDelay = Duration(seconds: 60);

  final StreamController<SyncState> _syncStateController =
      StreamController<SyncState>.broadcast();
  final StreamController<MutationSyncResult> _mutationSyncResultController =
      StreamController<MutationSyncResult>.broadcast();

  MutationSyncer({
    required SpacetimeDbConnection connection,
    required OfflineStorage storage,
    required OptimisticStateManager optimisticState,
    required ClientCache cache,
    required SendReducer send,
    OfflineQueuePolicy policy = const OfflineQueuePolicy(),
  }) : _connection = connection,
       _storage = storage,
       _optimisticState = optimisticState,
       _cache = cache,
       _send = send,
       _policy = policy;

  Stream<SyncState> get onSyncStateChanged => _syncStateController.stream;
  Stream<MutationSyncResult> get onMutationSyncResult =>
      _mutationSyncResultController.stream;
  SyncState get syncState => _currentSyncState;
  bool get isSyncing => _isSyncing;

  @override
  void trySyncNow() {
    if (_isSyncing) {
      SdkLogger.d('Sync already in progress, skipping duplicate trigger');
      return;
    }
    SdkLogger.d('Immediate sync triggered by reducer call');
    syncPendingMutations();
  }

  @override
  void onMutationQueued(String requestId, List<OptimisticChange>? changes) {
    SdkLogger.d(
      'onMutationQueued called: requestId=$requestId, changes=${changes?.length ?? 0}',
    );
    _cachedPendingCount++;
    _updateSyncState(
      _currentSyncState.copyWith(pendingCount: _cachedPendingCount),
    );
  }

  @override
  void onOptimisticChanges(String requestId, List<OptimisticChange>? changes) {
    _optimisticState.applyOptimisticChanges(requestId, changes);
    final touchedTables = changes?.map((c) => c.tableName).toSet();
    persistTableSnapshots(onlyTables: touchedTables);
  }

  @override
  void onRollbackOptimistic(String requestId) {
    SdkLogger.w(
      'Rolling back optimistic changes for request $requestId due to timeout/failure',
    );
    final touchedTables = _optimisticState.rollbackOptimisticChanges(requestId);
    persistTableSnapshots(onlyTables: touchedTables);
  }

  Future<void> updatePendingCount() async {
    final pending = await _storage.getPendingMutations();
    _cachedPendingCount = pending.length;
    _updateSyncState(
      _currentSyncState.copyWith(pendingCount: _cachedPendingCount),
    );
  }

  void resetRetryAttempts() {
    _retryAttempt = 0;
  }

  void clearSyncErrors() {
    _updateSyncState(
      _currentSyncState.copyWith(failedCount: 0, recentFailures: const []),
    );
  }

  void cancelRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  Future<void> syncPendingMutations() async {
    if (_disposed) return;
    if (_isSyncing) {
      SdkLogger.d('Sync already in progress, skipping');
      return;
    }
    if (_connection.state is! Connected) {
      SdkLogger.d('syncPendingMutations: not connected, skipping');
      return;
    }

    SdkLogger.d('syncPendingMutations: starting');
    _isSyncing = true;
    final cycleFailures = <MutationSyncResult>[];

    try {
      final pending = await _storage.getPendingMutations();
      if (pending.isEmpty) {
        SdkLogger.d('syncPendingMutations: no pending mutations, setting idle');
        _cachedPendingCount = 0;
        _updateSyncState(
          _currentSyncState.copyWith(status: SyncStatus.idle, pendingCount: 0),
        );
        return;
      }

      _cachedPendingCount = pending.length;
      _updateSyncState(
        _currentSyncState.copyWith(
          status: SyncStatus.syncing,
          pendingCount: _cachedPendingCount,
        ),
      );

      SdkLogger.d('Syncing ${pending.length} pending mutations');

      for (final mutation in pending) {
        if (_disposed) return;
        if (_connection.state is! Connected) {
          SdkLogger.d('Connection lost during sync. Pausing queue.');
          break;
        }

        final maxAge = _policy.maxMutationAge;
        if (maxAge != null &&
            DateTime.now().difference(mutation.createdAt) > maxAge) {
          await _discardMutation(
            mutation,
            'expired: older than ${maxAge.inSeconds}s at replay',
            cycleFailures,
            expired: true,
          );
          continue;
        }

        final hook = _policy.onBeforeReplay;
        if (hook != null) {
          ReplayDecision decision;
          try {
            decision = await hook(mutation);
          } catch (e) {
            SdkLogger.e('onBeforeReplay hook threw, replaying anyway: $e');
            decision = ReplayDecision.replay;
          }
          if (decision == ReplayDecision.discard) {
            await _discardMutation(
              mutation,
              'discarded by onBeforeReplay',
              cycleFailures,
            );
            continue;
          }
        }

        try {
          SdkLogger.d(
            'SYNC_SEND: ${mutation.reducerName}, uuidRequestId=${mutation.requestId}, argsLen=${mutation.encodedArgs.length}',
          );
          final result = await _send(
            mutation.reducerName,
            mutation.encodedArgs,
            requestId: mutation.requestId,
          );

          if (_disposed) return;

          if (result.isSuccess) {
            try {
              await _storage.dequeueMutation(mutation.requestId);
            } catch (e) {
              throw SpacetimeDbStorageException(
                'Failed to dequeue ${mutation.reducerName} after a successful '
                'send (requestId=${mutation.requestId}): $e',
              );
            }
            _decrementPendingCount();
            SdkLogger.d('Synced mutation: ${mutation.reducerName}');
            if (!_disposed) {
              _mutationSyncResultController.add(
                MutationSyncResult(
                  requestId: mutation.requestId,
                  reducerName: mutation.reducerName,
                  success: true,
                ),
              );
            }
          } else {
            final errorMsg = result.errorMessage ?? 'Unknown error';
            _optimisticState.rollbackOptimisticChanges(mutation.requestId);
            await _storage.dequeueMutation(mutation.requestId);
            _decrementPendingCount();
            SdkLogger.e(
              'Server rejected mutation: ${mutation.reducerName} - $errorMsg',
            );
            final failure = MutationSyncResult(
              requestId: mutation.requestId,
              reducerName: mutation.reducerName,
              success: false,
              error: errorMsg,
              optimisticChanges: mutation.optimisticChanges,
            );
            cycleFailures.add(failure);
            if (!_disposed) {
              _mutationSyncResultController.add(failure);
            }
          }
        } on SpacetimeDbReducerException catch (e) {
          _optimisticState.rollbackOptimisticChanges(mutation.requestId);
          await _storage.dequeueMutation(mutation.requestId);
          _decrementPendingCount();
          SdkLogger.e(
            'Server rejected mutation: ${mutation.reducerName} - ${e.message}',
          );
          final failure = MutationSyncResult(
            requestId: mutation.requestId,
            reducerName: mutation.reducerName,
            success: false,
            error: e.message,
            optimisticChanges: mutation.optimisticChanges,
          );
          cycleFailures.add(failure);
          if (!_disposed) {
            _mutationSyncResultController.add(failure);
          }
        } on SpacetimeDbTimeoutException catch (e) {
          SdkLogger.w(
            'Timeout syncing ${mutation.reducerName}: $e. Keeping in queue for retry.',
          );
          break;
        } on SpacetimeDbStorageException catch (e) {
          SdkLogger.e(
            'Storage error after sending ${mutation.reducerName}: $e. '
            'Pausing queue; the mutation may re-send on the next cycle.',
          );
          break;
        } catch (e) {
          SdkLogger.w(
            'Network error syncing ${mutation.reducerName}: $e. Pausing queue.',
          );
          break;
        }
      }
    } finally {
      _isSyncing = false;
      SdkLogger.d('syncPendingMutations: finished (isSyncing=false)');
    }

    if (_disposed) {
      SdkLogger.d(
        'syncPendingMutations: disposed, skipping final state update',
      );
      return;
    }

    final remaining = await _storage.getPendingMutations();
    _cachedPendingCount = remaining.length;
    SdkLogger.d(
      'syncPendingMutations: remaining=$_cachedPendingCount, '
      'failures=${cycleFailures.length}, setting idle',
    );

    int failedCount;
    List<MutationSyncResult> recentFailures;
    if (cycleFailures.isNotEmpty) {
      failedCount = _currentSyncState.failedCount + cycleFailures.length;
      recentFailures = _capFailures([
        ..._currentSyncState.recentFailures,
        ...cycleFailures,
      ]);
    } else if (remaining.isEmpty) {
      failedCount = 0;
      recentFailures = const [];
    } else {
      failedCount = _currentSyncState.failedCount;
      recentFailures = _currentSyncState.recentFailures;
    }

    _updateSyncState(
      _currentSyncState.copyWith(
        status: SyncStatus.idle,
        pendingCount: _cachedPendingCount,
        lastSyncTime: DateTime.now(),
        failedCount: failedCount,
        recentFailures: recentFailures,
      ),
    );

    if (remaining.isNotEmpty && _connection.state is Connected) {
      _scheduleRetry();
    } else if (remaining.isEmpty) {
      cancelRetry();
      _retryAttempt = 0;
    }
  }

  @override
  Future<void> onMutationDropped(
    PendingMutation mutation,
    String reason,
  ) async {
    final touched = _optimisticState.rollbackOptimisticChanges(
      mutation.requestId,
    );
    if (touched.isNotEmpty) {
      await persistTableSnapshots(onlyTables: touched);
    }
    await _storage.dequeueMutation(mutation.requestId);
    _decrementPendingCount();
    SdkLogger.w('Dropping queued mutation ${mutation.reducerName}: $reason');
    final failure = MutationSyncResult(
      requestId: mutation.requestId,
      reducerName: mutation.reducerName,
      success: false,
      error: reason,
      optimisticChanges: mutation.optimisticChanges,
    );
    final recentFailures = _capFailures([
      ..._currentSyncState.recentFailures,
      failure,
    ]);
    _updateSyncState(
      _currentSyncState.copyWith(
        failedCount: _currentSyncState.failedCount + 1,
        recentFailures: recentFailures,
      ),
    );
    if (!_disposed) {
      _mutationSyncResultController.add(failure);
    }
  }

  Future<List<PendingMutation>> getPendingMutations() async {
    return _storage.getPendingMutations();
  }

  Future<void> clearPendingMutation(String requestId) async {
    await _storage.dequeueMutation(requestId);
    await updatePendingCount();
  }

  Future<void> clearAllPendingMutations() async {
    await _storage.clearMutationQueue();
    await updatePendingCount();
  }

  Future<void> ensureInitialized() async {
    if (_storageInitialized) return;
    await _storage.initialize();
    _storageInitialized = true;
  }

  Future<void> loadFromOfflineCache() async {
    try {
      await ensureInitialized();

      for (final tableName in _cache.registeredTableNames) {
        if (_cache.isEventTable(tableName)) continue;
        final rows = await _storage.loadTableSnapshot(tableName);
        if (rows != null && rows.isNotEmpty) {
          final table = _cache.getTableByName(tableName);
          if (table != null && table.decoder.supportsJsonSerialization) {
            table.loadFromSerializable(rows);
            SdkLogger.d(
              'Loaded ${rows.length} rows from offline cache for "$tableName"',
            );
          }
        }
      }

      final pending = await _storage.getPendingMutations();
      for (final mutation in pending) {
        _optimisticState.applyOptimisticChanges(
          mutation.requestId,
          mutation.optimisticChanges,
        );
      }

      await updatePendingCount();
    } catch (e) {
      SdkLogger.e('Error loading from offline cache: $e');
    }
  }

  Future<void> persistTableSnapshots({Set<String>? onlyTables}) async {
    if (_disposed) return;
    try {
      final tableNames = onlyTables ?? _cache.activatedTableNames;
      for (final tableName in tableNames) {
        if (_cache.isEventTable(tableName)) continue;
        final table = _cache.getTableByName(tableName);
        if (table != null && table.decoder.supportsJsonSerialization) {
          final rows = table.toSerializable();
          await _storage.saveTableSnapshot(tableName, rows);
          await _storage.setLastSyncTime(tableName, DateTime.now());
        }
      }
    } catch (e) {
      SdkLogger.e('Error persisting table snapshots: $e');
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    cancelRetry();
    _syncStateController.close();
    _mutationSyncResultController.close();
    await _storage.dispose();
  }

  Future<void> _discardMutation(
    PendingMutation mutation,
    String reason,
    List<MutationSyncResult> cycleFailures, {
    bool expired = false,
  }) async {
    final touched = _optimisticState.rollbackOptimisticChanges(
      mutation.requestId,
    );
    if (touched.isNotEmpty) {
      await persistTableSnapshots(onlyTables: touched);
    }
    await _storage.dequeueMutation(mutation.requestId);
    _decrementPendingCount();
    SdkLogger.w('Discarding mutation ${mutation.reducerName}: $reason');
    final failure = MutationSyncResult(
      requestId: mutation.requestId,
      reducerName: mutation.reducerName,
      success: false,
      error: reason,
      expired: expired,
      optimisticChanges: mutation.optimisticChanges,
    );
    cycleFailures.add(failure);
    if (!_disposed) {
      _mutationSyncResultController.add(failure);
    }
  }

  List<MutationSyncResult> _capFailures(List<MutationSyncResult> failures) {
    final max = _policy.maxRetainedFailures;
    if (max == null || failures.length <= max) return failures;
    if (max <= 0) return const [];
    return failures.sublist(failures.length - max);
  }

  void _updateSyncState(SyncState state) {
    if (_disposed) return;
    final prev = _currentSyncState;
    if (prev.status != state.status ||
        prev.pendingCount != state.pendingCount) {
      SdkLogger.d(
        'SyncState: ${prev.status}(${prev.pendingCount}) -> ${state.status}(${state.pendingCount})',
      );
    }
    _currentSyncState = state;
    _syncStateController.add(state);
  }

  void _decrementPendingCount() {
    _cachedPendingCount = (_cachedPendingCount - 1).clamp(
      0,
      _cachedPendingCount,
    );
    _updateSyncState(
      _currentSyncState.copyWith(pendingCount: _cachedPendingCount),
    );
  }

  void _scheduleRetry() {
    if (_disposed) return;
    _retryTimer?.cancel();

    final delay = Duration(
      milliseconds: (_initialRetryDelay.inMilliseconds * (1 << _retryAttempt))
          .clamp(0, _maxRetryDelay.inMilliseconds),
    );
    _retryAttempt++;

    SdkLogger.d(
      'Scheduling sync retry in ${delay.inSeconds}s (attempt $_retryAttempt)',
    );

    _retryTimer = Timer(delay, () {
      if (_disposed) return;
      if (_connection.state is Connected) {
        SdkLogger.d('Auto-retry: syncing pending mutations');
        syncPendingMutations();
      }
    });
  }
}
