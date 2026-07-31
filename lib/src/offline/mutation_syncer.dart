import 'dart:async';
import 'dart:typed_data';

import 'package:meta/meta.dart';

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
  bool _syncLoopActive = false;
  bool _resyncRequested = false;
  bool _disposed = false;
  bool _storageInitialized = false;
  int _cachedPendingCount = 0;
  SyncState _currentSyncState = const SyncState();

  Timer? _retryTimer;
  DateTime? _nextRetryAt;
  int _retryAttempt = 0;
  static const Duration _initialRetryDelay = Duration(seconds: 5);
  static const Duration _maxRetryDelay = Duration(seconds: 60);

  final Map<String, int> _abortRecheckCount = {};
  static const int _maxAbortRecheck = 3;

  final Map<String, Set<dynamic>> _awaitedOwnershipKeys = {};

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
    _nextRetryAt = null;
  }

  void notifyOwnershipGained(String tableName, dynamic primaryKey) {
    if (_disposed) return;
    final awaited = _awaitedOwnershipKeys[tableName];
    if (awaited == null || !awaited.remove(primaryKey)) return;
    if (awaited.isEmpty) _awaitedOwnershipKeys.remove(tableName);
    if (_awaitedOwnershipKeys.isNotEmpty) return;
    SdkLogger.d(
      'Awaited insert pk=$primaryKey on "$tableName" gained a server '
      'owner; resuming the paused sync queue',
    );
    syncPendingMutations();
  }

  Future<void> syncPendingMutations() async {
    if (_disposed) return;
    if (_syncLoopActive) {
      _resyncRequested = true;
      SdkLogger.d('Sync already in progress; follow-up sync requested');
      return;
    }
    _syncLoopActive = true;
    try {
      await _runSyncCycle();
      while (_takeResyncRequest()) {
        await _runSyncCycle();
      }
    } finally {
      _syncLoopActive = false;
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
    _optimisticState.clearConfirmedOverlay(mutation.requestId);
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
    _optimisticState.clearConfirmedOverlay(requestId);
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
          final rows = table.toSerializable(
            excludeRows: _optimisticState.optimisticPkInsertRowsForTable(
              tableName,
            ),
            excludeRequestIds: _optimisticState
                .optimisticNoPkInsertRequestIdsForTable(tableName),
          );
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

  @visibleForTesting
  Duration retryDelayForAttempt(int attempt) {
    // Clamp the shift exponent BEFORE the multiply: `1 << attempt` overflows
    // 64-bit int arithmetic past attempt ~50 and the delay collapses to 0
    // (permanently from ~63), turning a persistently-stuck mutation into a
    // send-every-10s hot loop. The exponent that reaches _maxRetryDelay is
    // small (5s * 2^4 = 80s > 60s cap), so cap it there.
    final maxShift =
        (_maxRetryDelay.inMilliseconds ~/ _initialRetryDelay.inMilliseconds)
            .bitLength;
    final exponent = attempt < maxShift ? attempt : maxShift;
    return Duration(
      milliseconds: (_initialRetryDelay.inMilliseconds * (1 << exponent)).clamp(
        0,
        _maxRetryDelay.inMilliseconds,
      ),
    );
  }

  bool _takeResyncRequest() {
    if (!_resyncRequested) return false;
    _resyncRequested = false;
    if (_disposed) return false;
    if (_connection.state is! Connected) return false;
    return _cachedPendingCount > 0;
  }

  Future<void> _runSyncCycle() async {
    if (_connection.state is! Connected) {
      SdkLogger.d('syncPendingMutations: not connected, skipping');
      return;
    }

    SdkLogger.d('syncPendingMutations: starting');
    _isSyncing = true;
    _awaitedOwnershipKeys.clear();
    final cycleFailures = <MutationSyncResult>[];

    try {
      final pending = await _storage.getPendingMutations();
      if (pending.isEmpty) {
        SdkLogger.d('syncPendingMutations: no pending mutations, setting idle');
        _cachedPendingCount = 0;
        _updateSyncState(
          _currentSyncState.copyWith(
            status: SyncStatus.idle,
            pendingCount: 0,
            clearNextRetryAt: true,
          ),
        );
        return;
      }

      _cachedPendingCount = pending.length;
      _updateSyncState(
        _currentSyncState.copyWith(
          status: SyncStatus.syncing,
          pendingCount: _cachedPendingCount,
          clearNextRetryAt: true,
        ),
      );

      SdkLogger.d('Syncing ${pending.length} pending mutations');

      for (final mutation in pending) {
        final step = await _processMutation(mutation, cycleFailures);
        if (step == _SyncStep.stop) return;
        if (step == _SyncStep.pauseQueue) break;
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

    await _finalizeSyncCycle(cycleFailures);
  }

  void _stashAwaitedInsertKeys(PendingMutation mutation) {
    _awaitedOwnershipKeys.clear();
    final changes = mutation.optimisticChanges;
    if (changes == null) return;
    for (final change in changes) {
      if (change.type != OptimisticChangeType.insert) continue;
      final table = _cache.getTableByName(change.tableName);
      if (table == null || !table.decoder.supportsJsonSerialization) continue;
      final row = table.decoder.fromJson(change.newRowJson!);
      if (row == null) continue;
      final pk = table.decoder.getPrimaryKey(row);
      if (pk == null) continue;
      if (table.ownedKeys(pk).isNotEmpty) continue;
      _awaitedOwnershipKeys
          .putIfAbsent(change.tableName, () => <dynamic>{})
          .add(pk);
    }
  }

  bool _isPureInsert(PendingMutation mutation) {
    final changes = mutation.optimisticChanges;
    if (changes == null || changes.isEmpty) return false;
    return changes.every((c) => c.type == OptimisticChangeType.insert);
  }

  _TimeoutOutcome _resolveTimedOutMutation(
    PendingMutation mutation, {
    bool overlayIsProof = false,
  }) {
    final changes = mutation.optimisticChanges;
    if (changes == null || changes.isEmpty) {
      return _TimeoutOutcome.undetectable;
    }

    var allLanded = true;
    for (final change in changes) {
      final table = _cache.getTableByName(change.tableName);
      if (table == null ||
          !table.isSubscribed ||
          !table.decoder.supportsJsonSerialization) {
        return _TimeoutOutcome.undetectable;
      }

      switch (change.type) {
        case OptimisticChangeType.insert:
          final expected = table.decoder.fromJson(change.newRowJson!);
          if (expected == null) return _TimeoutOutcome.undetectable;
          final pk = table.decoder.getPrimaryKey(expected);
          if (table.ownedKeys(pk).isEmpty) {
            allLanded = false;
          }
        case OptimisticChangeType.update:
          final expected = table.decoder.fromJson(change.newRowJson!);
          if (expected == null) return _TimeoutOutcome.undetectable;
          final pk = table.decoder.getPrimaryKey(expected);
          if (!overlayIsProof &&
              (_optimisticState.hasPendingEntryForKey(change.tableName, pk) ||
                  _optimisticState.wasOverlayConfirmedForKey(
                    mutation.requestId,
                    change.tableName,
                    pk,
                  ))) {
            return _TimeoutOutcome.undetectable;
          }
          final current = table.getRow(pk);
          if (current == null) return _TimeoutOutcome.undetectable;
          final currentJson = table.decoder.toJson(current);
          if (!_jsonEquals(currentJson, change.newRowJson)) {
            allLanded = false;
          }
        case OptimisticChangeType.delete:
          final target = table.decoder.fromJson(change.oldRowJson!);
          if (target == null) return _TimeoutOutcome.undetectable;
          final pk = table.decoder.getPrimaryKey(target);
          if (!overlayIsProof &&
              (_optimisticState.hasPendingEntryForKey(change.tableName, pk) ||
                  _optimisticState.wasOverlayConfirmedForKey(
                    mutation.requestId,
                    change.tableName,
                    pk,
                  ))) {
            return _TimeoutOutcome.undetectable;
          }
          if (table.getRow(pk) != null) {
            allLanded = false;
          }
      }
    }
    return allLanded ? _TimeoutOutcome.landed : _TimeoutOutcome.notLanded;
  }

  bool _jsonEquals(Map<String, dynamic>? a, Map<String, dynamic>? b) {
    if (a == null || b == null) return a == b;
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key)) return false;
      final av = a[key];
      final bv = b[key];
      if (av is Map<String, dynamic> && bv is Map<String, dynamic>) {
        if (!_jsonEquals(av, bv)) return false;
      } else if (av.toString() != bv.toString()) {
        return false;
      }
    }
    return true;
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
    _abortRecheckCount.remove(mutation.requestId);
    _optimisticState.clearConfirmedOverlay(mutation.requestId);
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

  Future<_SyncStep> _processMutation(
    PendingMutation mutation,
    List<MutationSyncResult> cycleFailures,
  ) async {
    if (_disposed) return _SyncStep.stop;
    if (_connection.state is! Connected) {
      SdkLogger.d('Connection lost during sync. Pausing queue.');
      return _SyncStep.pauseQueue;
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
      return _SyncStep.next;
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
        return _SyncStep.next;
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

      if (_disposed) return _SyncStep.stop;

      return await _onSendResult(mutation, result, cycleFailures);
    } on SpacetimeDbReducerException catch (e) {
      return await _onReducerAbort(mutation, e, cycleFailures);
    } on SpacetimeDbTimeoutException catch (e) {
      return await _onTimeout(mutation, e);
    } on SpacetimeDbStorageException catch (e) {
      SdkLogger.e(
        'Storage error after sending ${mutation.reducerName}: $e. '
        'Pausing queue; the mutation may re-send on the next cycle.',
      );
      return _SyncStep.pauseQueue;
    } catch (e) {
      SdkLogger.w(
        'Network error syncing ${mutation.reducerName}: $e. Pausing queue.',
      );
      return _SyncStep.pauseQueue;
    }
  }

  Future<_SyncStep> _onSendResult(
    PendingMutation mutation,
    TransactionResult result,
    List<MutationSyncResult> cycleFailures,
  ) async {
    if (result.isSuccess) {
      _abortRecheckCount.remove(mutation.requestId);
      _optimisticState.clearConfirmedOverlay(mutation.requestId);
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
      return _SyncStep.next;
    }

    final errorMsg = result.errorMessage ?? 'Unknown error';
    _optimisticState.rollbackOptimisticChanges(mutation.requestId);
    _optimisticState.clearConfirmedOverlay(mutation.requestId);
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
    return _SyncStep.next;
  }

  Future<_SyncStep> _onReducerAbort(
    PendingMutation mutation,
    SpacetimeDbReducerException e,
    List<MutationSyncResult> cycleFailures,
  ) async {
    if (_resolveTimedOutMutation(mutation, overlayIsProof: true) ==
        _TimeoutOutcome.landed) {
      SdkLogger.w(
        'Reducer ${mutation.reducerName} aborted on replay but its '
        'effect is server-owned in cache; the abort is a unique-key '
        'collision on the already-committed row. Confirming instead of '
        'failing.',
      );
      _abortRecheckCount.remove(mutation.requestId);
      _optimisticState.confirmOptimisticChange(mutation.requestId);
      _optimisticState.clearConfirmedOverlay(mutation.requestId);
      await _storage.dequeueMutation(mutation.requestId);
      _decrementPendingCount();
      if (!_disposed) {
        _mutationSyncResultController.add(
          MutationSyncResult(
            requestId: mutation.requestId,
            reducerName: mutation.reducerName,
            success: true,
          ),
        );
      }
      return _SyncStep.next;
    }
    if (_isPureInsert(mutation)) {
      final rechecks = _abortRecheckCount[mutation.requestId] ?? 0;
      if (rechecks < _maxAbortRecheck) {
        _abortRecheckCount[mutation.requestId] = rechecks + 1;
        SdkLogger.w(
          'Reducer ${mutation.reducerName} aborted on replay; its '
          'insert is not yet server-owned in cache. Keeping in queue to '
          're-check after resubscribe hydrates ownership '
          '(${rechecks + 1}/$_maxAbortRecheck).',
        );
        _stashAwaitedInsertKeys(mutation);
        return _SyncStep.pauseQueue;
      }
      SdkLogger.w(
        'Reducer ${mutation.reducerName} aborted on replay '
        '$_maxAbortRecheck times without becoming server-owned; treating '
        'as a genuine failure.',
      );
    }
    _abortRecheckCount.remove(mutation.requestId);
    _optimisticState.rollbackOptimisticChanges(mutation.requestId);
    _optimisticState.clearConfirmedOverlay(mutation.requestId);
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
    return _SyncStep.next;
  }

  Future<_SyncStep> _onTimeout(
    PendingMutation mutation,
    SpacetimeDbTimeoutException e,
  ) async {
    final outcome = _resolveTimedOutMutation(mutation);
    switch (outcome) {
      case _TimeoutOutcome.landed:
        SdkLogger.w(
          'Timeout syncing ${mutation.reducerName}: $e. Effect already '
          'present in cache; confirming instead of re-sending.',
        );
        _abortRecheckCount.remove(mutation.requestId);
        _optimisticState.confirmOptimisticChange(mutation.requestId);
        _optimisticState.clearConfirmedOverlay(mutation.requestId);
        await _storage.dequeueMutation(mutation.requestId);
        _decrementPendingCount();
        if (!_disposed) {
          _mutationSyncResultController.add(
            MutationSyncResult(
              requestId: mutation.requestId,
              reducerName: mutation.reducerName,
              success: true,
            ),
          );
        }
        return _SyncStep.next;
      case _TimeoutOutcome.notLanded:
        SdkLogger.w(
          'Timeout syncing ${mutation.reducerName}: $e. Effect not '
          'present; keeping in queue for retry.',
        );
        _stashAwaitedInsertKeys(mutation);
        return _SyncStep.pauseQueue;
      case _TimeoutOutcome.undetectable:
        SdkLogger.w(
          'Timeout syncing ${mutation.reducerName}: $e. Outcome cannot '
          'be verified; keeping in queue for retry (at-least-once — the '
          'server may or may not have executed it).',
        );
        _stashAwaitedInsertKeys(mutation);
        return _SyncStep.pauseQueue;
    }
  }

  Future<void> _finalizeSyncCycle(
    List<MutationSyncResult> cycleFailures,
  ) async {
    try {
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

      if (remaining.isNotEmpty && _connection.state is Connected) {
        _scheduleRetry();
        _updateSyncState(
          _currentSyncState.copyWith(
            status: SyncStatus.waitingToRetry,
            pendingCount: _cachedPendingCount,
            lastSyncTime: DateTime.now(),
            nextRetryAt: _nextRetryAt,
            failedCount: failedCount,
            recentFailures: recentFailures,
          ),
        );
        return;
      }

      if (remaining.isEmpty) {
        cancelRetry();
        _retryAttempt = 0;
      }
      _updateSyncState(
        _currentSyncState.copyWith(
          status: SyncStatus.idle,
          pendingCount: _cachedPendingCount,
          lastSyncTime: DateTime.now(),
          clearNextRetryAt: true,
          failedCount: failedCount,
          recentFailures: recentFailures,
        ),
      );
    } catch (e) {
      SdkLogger.e('syncPendingMutations: post-sync state update failed: $e');
    }
  }

  void _scheduleRetry() {
    if (_disposed) return;
    _retryTimer?.cancel();

    final delay = retryDelayForAttempt(_retryAttempt);
    _retryAttempt++;
    _nextRetryAt = DateTime.now().add(delay);

    SdkLogger.d(
      'Scheduling sync retry in ${delay.inSeconds}s (attempt $_retryAttempt)',
    );

    _retryTimer = Timer(delay, () {
      if (_disposed) return;
      _nextRetryAt = null;
      if (_connection.state is Connected) {
        SdkLogger.d('Auto-retry: syncing pending mutations');
        syncPendingMutations();
      }
    });
  }
}

enum _TimeoutOutcome { landed, notLanded, undetectable }

enum _SyncStep { next, pauseQueue, stop }
