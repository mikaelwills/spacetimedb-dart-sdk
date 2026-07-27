import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:spacetimedb_sdk/src/cache/client_cache.dart';
import 'package:spacetimedb_sdk/src/utils/sdk_logger.dart';

import '../connection/spacetimedb_connection.dart';
import '../connection/connection_state.dart';
import '../messages/message_decoder.dart';
import '../messages/server_messages.dart';
import '../messages/shared_types.dart';
import '../messages/client_messages.dart';
import '../messages/update_status.dart';
import '../reducers/reducer_caller.dart';
import '../reducers/reducer_registry.dart';
import '../reducers/reducer_emitter.dart';
import '../reducers/transaction_result.dart';
import '../exceptions.dart';
import '../events/event.dart';
import '../events/event_context.dart';
import '../auth/identity.dart';
import '../offline/offline_queue_policy.dart';
import '../offline/offline_storage.dart';
import '../offline/sync_state.dart';
import '../offline/pending_mutation.dart';
import '../offline/optimistic_state_manager.dart';
import '../offline/mutation_syncer.dart';

class SubscriptionManager {
  final SpacetimeDbConnection _connection;
  final ClientCache cache = ClientCache();
  late final ReducerCaller reducers;
  final ReducerRegistry reducerRegistry = ReducerRegistry();
  final ReducerEmitter reducerEmitter = ReducerEmitter();

  Identity? _identity;
  String? _address;
  Uint8List? _connectionId;

  /// Tracks active subscriptions by client-assigned `QuerySetId` so we can
  /// re-subscribe on reconnect and route `SubscribeApplied`/`UnsubscribeApplied`.
  final Map<int, List<String>> _subscriptionsByQuerySetId = {};
  int _nextQuerySetId = 1;

  final _subscribeWaiters = <int, Completer<void>>{};

  final ValueNotifier<bool> _subscriptionsReady = ValueNotifier<bool>(false);

  late final OptimisticStateManager _optimisticState;
  MutationSyncer? _mutationSyncer;
  bool _disposed = false;

  final _transactionUpdateController =
      StreamController<TransactionUpdateMessage>.broadcast();
  final _initialConnectionController =
      StreamController<InitialConnectionMessage>.broadcast();
  final _oneOffQueryResultController =
      StreamController<OneOffQueryResult>.broadcast();
  final _subscribeAppliedController =
      StreamController<SubscribeApplied>.broadcast();
  final _unsubscribeAppliedController =
      StreamController<UnsubscribeApplied>.broadcast();
  final _subscriptionErrorController =
      StreamController<SubscriptionErrorMessage>.broadcast();
  final _reducerResultController =
      StreamController<ReducerResultMessage>.broadcast();
  final _procedureResultController =
      StreamController<ProcedureResultMessage>.broadcast();

  StreamSubscription<Uint8List>? _messageSubscription;
  StreamSubscription<ConnectionState>? _connectionStatusSubscription;

  SubscriptionManager(
    this._connection, {
    OfflineStorage? offlineStorage,
    OfflineQueuePolicy queuePolicy = const OfflineQueuePolicy(),
  }) {
    _optimisticState = OptimisticStateManager(cache);

    if (offlineStorage != null) {
      late ReducerCaller caller;
      _mutationSyncer = MutationSyncer(
        connection: _connection,
        storage: offlineStorage,
        optimisticState: _optimisticState,
        cache: cache,
        send:
            (name, args, {requestId}) =>
                caller.callWithBytes(name, args, requestId: requestId),
        policy: queuePolicy,
      );
      caller = ReducerCaller(
        _connection,
        offlineStorage: offlineStorage,
        mutationHandler: _mutationSyncer,
        policy: queuePolicy,
      );
      reducers = caller;
    } else {
      reducers = ReducerCaller(_connection);
    }

    _startListening();
    _startConnectionMonitoring();
  }

  Stream<SyncState> get onSyncStateChanged =>
      _mutationSyncer?.onSyncStateChanged ?? const Stream.empty();
  Stream<MutationSyncResult> get onMutationSyncResult =>
      _mutationSyncer?.onMutationSyncResult ?? const Stream.empty();
  SyncState get syncState => _mutationSyncer?.syncState ?? const SyncState();
  bool get hasOfflineStorage => _mutationSyncer != null;

  /// True only when the connection is open AND every active query set has had
  /// its `SubscribeApplied` fully applied to the cache — i.e. the connection is
  /// genuinely usable, not merely socket-open. Latches back to false the moment
  /// the socket drops or a reconnect begins resubscribing, and returns to true
  /// when the resubscribe completes. Consumers should treat "connected but not
  /// ready" as still-connecting.
  ValueListenable<bool> get subscriptionsReady => _subscriptionsReady;

  @visibleForTesting
  Map<int, List<String>> get subscriptionsByQuerySetId =>
      _subscriptionsByQuerySetId;

  /// All currently-subscribed query strings across every active `QuerySetId`.
  @visibleForTesting
  Set<String> get activeSubscriptionQueries =>
      _subscriptionsByQuerySetId.values.expand((q) => q).toSet();

  @visibleForTesting
  int rowProvenanceCountForTable(String tableName) =>
      cache.getTableByName(tableName)?.ownerEntryCount ?? 0;

  @visibleForTesting
  Set<dynamic> optimisticKeysFor(String tableName) =>
      _optimisticState.optimisticPrimaryKeysForTable(tableName);

  Stream<TransactionUpdateMessage> get onTransactionUpdate =>
      _transactionUpdateController.stream;
  Stream<InitialConnectionMessage> get onInitialConnection =>
      _initialConnectionController.stream;
  Stream<OneOffQueryResult> get onOneOffQueryResult =>
      _oneOffQueryResultController.stream;
  Stream<SubscribeApplied> get onSubscribeApplied =>
      _subscribeAppliedController.stream;
  Stream<UnsubscribeApplied> get onUnsubscribeApplied =>
      _unsubscribeAppliedController.stream;
  Stream<SubscriptionErrorMessage> get onSubscriptionError =>
      _subscriptionErrorController.stream;
  Stream<ReducerResultMessage> get onReducerResult =>
      _reducerResultController.stream;
  Stream<ProcedureResultMessage> get onProcedureResult =>
      _procedureResultController.stream;

  Identity? get identity => _identity;
  String? get address => _address;

  /// Subscribe a new query set. Returns the assigned `querySetId`.
  /// Awaits the matching `SubscribeApplied` so initial rows are in the cache.
  /// Resolves without throwing if the manager is disposed, the connection
  /// drops, or the server rejects the subscription before then.
  Future<int> subscribe(List<String> queries) async {
    final querySetId = _nextQuerySetId++;
    _subscriptionsByQuerySetId[querySetId] = List.of(queries);
    await _sendSubscribeAndWait(
      querySetId,
      _subscriptionsByQuerySetId[querySetId]!,
    );
    return querySetId;
  }

  void oneOffQuery(String query, {int requestId = 0}) {
    final message = OneOffQueryMessage(
      queryString: query,
      requestId: requestId,
    );
    _connection.send(message.encode());
  }

  int _healthCheckRequestId = 100000;

  /// Probe whether the server is actually answering on this socket.
  ///
  /// Sends a trivial `OneOffQuery` and awaits the matching
  /// `OneOffQueryResult` within [timeout]. Returns `true` if a response
  /// arrives, `false` if the timeout elapses first OR if the connection
  /// reports itself disconnected.
  ///
  /// Intended for app-resume flows on mobile, where the OS may have
  /// silently killed the socket's read-half while the app was suspended.
  /// The SDK's built-in `KeepAliveMonitor` will catch this eventually
  /// (via its own idle-ping + pong-timeout), but its timers are paused
  /// while the app is backgrounded, so on resume there's a window where
  /// the client believes the connection is alive but server messages
  /// never arrive. Callers should invoke `checkHealth()` on resume and
  /// call [SpacetimeDbConnection.reconnect] when it returns `false`.
  Future<bool> checkHealth({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    if (!_connection.isConnected) return false;

    final requestId = _healthCheckRequestId++;
    final completer = Completer<bool>();
    late StreamSubscription<OneOffQueryResult> sub;

    sub = onOneOffQueryResult.listen((result) {
      if (result.requestId == requestId && !completer.isCompleted) {
        completer.complete(true);
      }
    });

    try {
      oneOffQuery(
        'SELECT * FROM __spacetime_dart_sdk_healthcheck__',
        requestId: requestId,
      );
      return await completer.future.timeout(timeout, onTimeout: () => false);
    } finally {
      await sub.cancel();
    }
  }

  /// Remove a subscription. Set `sendDroppedRows: true` to receive the
  /// dropped-row payload on the resulting `UnsubscribeApplied` (slice 5 /
  /// `v2.rs:86-93`). The default is `false` — server sends no dropped rows.
  void unsubscribe(
    int querySetId, {
    int requestId = 0,
    bool sendDroppedRows = false,
  }) {
    final message = UnsubscribeMessage(
      querySetId: querySetId,
      requestId: requestId,
      flags:
          sendDroppedRows
              ? UnsubscribeFlags.sendDroppedRows
              : UnsubscribeFlags.defaultFlag,
    );
    _connection.send(message.encode());
    _subscriptionsByQuerySetId.remove(querySetId);
    _dropQuerySetEverywhere(querySetId);
  }

  void callProcedure(
    String procedureName,
    Uint8List args, {
    int requestId = 0,
  }) {
    final message = CallProcedureMessage(
      procedureName: procedureName,
      args: args,
      requestId: requestId,
    );
    _connection.send(message.encode());
  }

  // --- Offline API (delegates to syncer/coordinator) ---

  Future<void> loadFromOfflineCache() async {
    await _mutationSyncer?.loadFromOfflineCache();
  }

  Future<void> syncPendingMutations() async {
    await _mutationSyncer?.syncPendingMutations();
  }

  Future<List<PendingMutation>> getPendingMutations() async {
    return await _mutationSyncer?.getPendingMutations() ?? [];
  }

  Future<void> clearPendingMutation(String requestId) async {
    await _mutationSyncer?.clearPendingMutation(requestId);
  }

  Future<void> clearAllPendingMutations() async {
    await _mutationSyncer?.clearAllPendingMutations();
  }

  void clearSyncErrors() {
    _mutationSyncer?.clearSyncErrors();
  }

  // --- Lifecycle ---

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _completeAllSubscribeWaiters();
    _messageSubscription?.cancel();
    _connectionStatusSubscription?.cancel();
    _transactionUpdateController.close();
    _initialConnectionController.close();
    _oneOffQueryResultController.close();
    _subscribeAppliedController.close();
    _unsubscribeAppliedController.close();
    _subscriptionErrorController.close();
    _reducerResultController.close();
    _procedureResultController.close();
    reducerEmitter.dispose();
    _subscriptionsReady.dispose();
    await _mutationSyncer?.dispose();
  }

  bool get _allQuerySetsApplied =>
      _subscriptionsByQuerySetId.isNotEmpty &&
      _subscriptionsByQuerySetId.keys.every(
        (id) =>
            !_subscribeWaiters.containsKey(id) ||
            _subscribeWaiters[id]!.isCompleted,
      );

  void _completeSubscribeWaiter(int querySetId) {
    final waiter = _subscribeWaiters[querySetId];
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete();
    }
  }

  void _completeAllSubscribeWaiters() {
    for (final waiter in _subscribeWaiters.values) {
      if (!waiter.isCompleted) {
        waiter.complete();
      }
    }
  }

  void _startConnectionMonitoring() {
    bool hasConnectedBefore = false;

    _connectionStatusSubscription = _connection.onStateChanged.listen((state) {
      if (_disposed) return;
      if (state is Connected) {
        if (hasConnectedBefore) {
          _mutationSyncer?.resetRetryAttempts();
          _onReconnected();
        }
        hasConnectedBefore = true;
      } else if (state is Disconnected ||
          state is FatalError ||
          state is AuthError) {
        _subscriptionsReady.value = false;
        _mutationSyncer?.cancelRetry();
        reducers.failAllPendingRequests(state.displayName);
        _completeAllSubscribeWaiters();
      }
    });
  }

  bool _reconnectInFlight = false;

  Future<void> _onReconnected() async {
    if (_subscriptionsByQuerySetId.isNotEmpty) {
      _subscriptionsReady.value = false;

      final oldKeysByTable = <String, Set<dynamic>>{
        for (final table in cache.allTables)
          if (table.hasPrimaryKey) table.tableName: table.primaryKeys,
      };
      for (final table in cache.allTables) {
        if (table.hasPrimaryKey) table.clearOwners();
      }

      _reconnectInFlight = true;
      var allResubscribed = true;
      try {
        final entries = _subscriptionsByQuerySetId.entries.toList();
        SdkLogger.i(
          'Re-subscribing to ${entries.length} query sets in place...',
        );
        for (final entry in entries) {
          if (!_connection.isConnected) {
            allResubscribed = false;
            break;
          }
          final ok = await _sendSubscribeAndWait(entry.key, entry.value)
              .then((_) => true)
              .timeout(
                const Duration(seconds: 30),
                onTimeout: () {
                  SdkLogger.e(
                    'subscribe(${entry.value}) timed out during reconnect '
                    '(querySetId=${entry.key}); retaining it for the next '
                    'reconnect',
                  );
                  return false;
                },
              );
          if (!ok) allResubscribed = false;
        }
      } finally {
        _reconnectInFlight = false;
      }

      if (_disposed) return;
      if (allResubscribed && _connection.isConnected) {
        _evictReconnectDeletes(oldKeysByTable);
        _subscriptionsReady.value = true;
      } else {
        SdkLogger.w(
          'Skipping reconnect eviction: resubscribe did not fully complete '
          '(connection dropped mid-reconnect); retaining cached rows and '
          'subscription map for the next reconnect',
        );
      }
    }

    if (_mutationSyncer != null) {
      SdkLogger.i('Syncing pending mutations after reconnect...');
      _mutationSyncer!.syncPendingMutations();
    }
  }

  void _evictReconnectDeletes(Map<String, Set<dynamic>> oldKeysByTable) {
    for (final entry in oldKeysByTable.entries) {
      final tableName = entry.key;
      final oldKeys = entry.value;
      final table = cache.getTableByName(tableName);
      if (table == null) continue;
      final optimisticPKs = _optimisticState.optimisticPrimaryKeysForTable(
        tableName,
      );
      final toEvict = <dynamic>[];
      for (final pk in oldKeys) {
        if (optimisticPKs.contains(pk)) continue;
        if (table.ownedKeys(pk).isEmpty) toEvict.add(pk);
      }
      _evict(tableName, toEvict);
    }
  }

  void _startListening() {
    _messageSubscription = _connection.onMessage.listen(_handleMessage);
  }

  Future<void> _handleMessage(Uint8List bytes) async {
    if (_disposed) return;
    try {
      final messages = await MessageDecoder.decodeAll(bytes);
      if (_disposed) return;
      for (final message in messages) {
        if (_disposed) return;
        SdkLogger.d('RX_MSG: ${message.runtimeType}');
        _routeMessage(message);
      }
    } catch (e, st) {
      SdkLogger.e(
        'RX_DECODE_FAILED: $e (${bytes.length} bytes, '
        'head=${bytes.take(8).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')})\n$st',
      );
    }
  }

  void _routeMessage(ServerMessage message) {
    if (_disposed) return;
    switch (message) {
      case InitialConnectionMessage():
        _identity = Identity(message.identity);
        _connectionId = message.connectionId;
        _address =
            message.connectionId
                .map((b) => b.toRadixString(16).padLeft(2, '0'))
                .join();
        _initialConnectionController.add(message);
      case SubscribeApplied():
        _handleSubscribeApplied(message)
            .then((_) {
              if (_disposed) return;
              _subscribeAppliedController.add(message);
              SdkLogger.i(
                'Syncing pending mutations after SubscribeApplied...',
              );
              _mutationSyncer?.syncPendingMutations();
            })
            .catchError((Object e, StackTrace st) {
              SdkLogger.e('SUBSCRIBE_APPLIED_FAILED: $e\n$st');
            })
            .whenComplete(() {
              if (_disposed) return;
              _completeSubscribeWaiter(message.querySetId);
              if (!_reconnectInFlight &&
                  _connection.isConnected &&
                  _allQuerySetsApplied) {
                _subscriptionsReady.value = true;
              }
            });
      case TransactionUpdateMessage():
        _handleTransactionUpdate(message);
        _transactionUpdateController.add(message);
      case OneOffQueryResult():
        _oneOffQueryResultController.add(message);
      case UnsubscribeApplied():
        _handleUnsubscribeApplied(message);
        _unsubscribeAppliedController.add(message);
      case SubscriptionErrorMessage():
        _handleSubscriptionError(message);
        _subscriptionErrorController.add(message);
      case ReducerResultMessage():
        _handleReducerResult(message);
        _reducerResultController.add(message);
      case ProcedureResultMessage():
        _procedureResultController.add(message);
    }
  }

  void _handleSubscriptionError(SubscriptionErrorMessage message) {
    final tableNameMatch = RegExp(
      r'`(\w+)` is not a valid table',
    ).firstMatch(message.error);
    if (tableNameMatch == null) {
      SdkLogger.e('Subscription error: ${message.error}');
      _completeSubscribeWaiter(message.querySetId);
      return;
    }

    final badTable = tableNameMatch.group(1)!;
    final queries = _subscriptionsByQuerySetId[message.querySetId];
    if (queries == null) {
      SdkLogger.e(
        'Subscription error for unknown querySetId ${message.querySetId}: ${message.error}',
      );
      _completeSubscribeWaiter(message.querySetId);
      return;
    }

    final badQuery = queries.firstWhere(
      (q) => RegExp(
        'FROM\\s+[`"]?${RegExp.escape(badTable)}[`"]?',
        caseSensitive: false,
      ).hasMatch(q),
      orElse: () => '',
    );

    if (badQuery.isEmpty) {
      SdkLogger.e(
        'Subscription error for unknown table "$badTable": ${message.error}',
      );
      _completeSubscribeWaiter(message.querySetId);
      return;
    }

    queries.remove(badQuery);
    SdkLogger.w(
      'Subscription failed for table "$badTable" in querySetId ${message.querySetId}, removed query. ${queries.length} queries left in the set.',
    );

    final badTableCache = cache.getTableByName(badTable);
    badTableCache?.markSubscribeFailed(
      SpacetimeDbSubscriptionException(message.error, tableName: badTable),
    );

    if (queries.isEmpty) {
      _subscriptionsByQuerySetId.remove(message.querySetId);
      _dropQuerySetEverywhere(message.querySetId);
      _completeSubscribeWaiter(message.querySetId);
    } else {
      final resubscribe = SubscribeMessage(
        List.of(queries),
        querySetId: message.querySetId,
      );
      _connection.send(resubscribe.encode());
    }
  }

  Future<void> _handleSubscribeApplied(SubscribeApplied message) async {
    SdkLogger.d(
      'Handling SubscribeApplied querySetId=${message.querySetId}, ${message.rows.tables.length} tables',
    );

    final event = SubscribeAppliedEvent();
    final context = EventContext(myConnectionId: _connectionId, event: event);
    final querySetId = message.querySetId;

    final serverRowsByTable = _groupRowsByTable(message.rows);
    final querySetTables = _tablesToApply(serverRowsByTable, querySetId);
    _applyInitialRows(querySetTables, serverRowsByTable, querySetId, context);

    await _mutationSyncer?.persistTableSnapshots();
  }

  Map<String, BsatnRowList> _groupRowsByTable(QueryRows rows) {
    final serverRowsByTable = <String, BsatnRowList>{};
    for (final tableRows in rows.tables) {
      final existing = serverRowsByTable[tableRows.tableName];
      serverRowsByTable[tableRows.tableName] =
          existing == null
              ? tableRows.rows
              : _mergeRowLists(existing, tableRows.rows);
    }
    return serverRowsByTable;
  }

  Set<String> _tablesToApply(
    Map<String, BsatnRowList> serverRowsByTable,
    int querySetId,
  ) => <String>{...serverRowsByTable.keys, ..._tablesForQuerySetId(querySetId)};

  void _applyInitialRows(
    Set<String> querySetTables,
    Map<String, BsatnRowList> serverRowsByTable,
    int querySetId,
    EventContext context,
  ) {
    for (final tableName in querySetTables) {
      final table = cache.getTableByName(tableName);
      if (table == null) continue;

      SdkLogger.d('  Table "$tableName": applying initial rows');
      final protectedKeys = _optimisticState.optimisticPrimaryKeysForTable(
        tableName,
      );
      final merged = serverRowsByTable[tableName];
      final inserts = merged ?? BsatnRowList.empty();

      if (table.hasPrimaryKey) {
        table.applySnapshot(
          inserts,
          context,
          querySetId: querySetId,
          protectedKeys: protectedKeys,
          reconnectInFlight: _reconnectInFlight,
        );
      } else {
        _optimisticState.clearNonOptimisticRows(tableName);
        if (merged != null) {
          table.applyInitialData(
            inserts,
            context,
            protectedKeys: protectedKeys,
          );
        }
      }
      table.markSubscribed();
    }
  }

  BsatnRowList _mergeRowLists(BsatnRowList a, BsatnRowList b) {
    final rows = [...a.getRows(), ...b.getRows()];
    final offsets = <int>[];
    var offset = 0;
    for (final row in rows) {
      offsets.add(offset);
      offset += row.length;
    }
    final merged = Uint8List(offset);
    var writeOffset = 0;
    for (final row in rows) {
      merged.setRange(writeOffset, writeOffset + row.length, row);
      writeOffset += row.length;
    }
    return BsatnRowList(
      sizeHint: RowSizeHint.rowOffsets(offsets),
      rowsData: merged,
    );
  }

  void _evict(String tableName, List<dynamic> pks) {
    if (pks.isEmpty) return;
    final evictSet = pks.toSet();
    cache.getTableByName(tableName)?.removeRowsWhere(evictSet.contains);
  }

  void _dropQuerySetEverywhere(int querySetId) {
    for (final table in cache.allTables) {
      if (!table.hasPrimaryKey) continue;
      table.dropQuerySet(
        querySetId,
        protectedKeys: _optimisticState.optimisticPrimaryKeysForTable(
          table.tableName,
        ),
      );
    }
  }

  static final _fromRegex = RegExp(
    r'FROM\s+[`"]?(\w+)[`"]?',
    caseSensitive: false,
  );

  Set<String> _tablesForQuerySetId(int querySetId) {
    final queries = _subscriptionsByQuerySetId[querySetId] ?? const [];
    return <String>{
      for (final query in queries)
        for (final match in _fromRegex.allMatches(query)) match.group(1)!,
    };
  }

  void _handleUnsubscribeApplied(UnsubscribeApplied message) {
    final querySetId = message.querySetId;
    _subscriptionsByQuerySetId.remove(querySetId);
    _dropQuerySetEverywhere(querySetId);

    final rows = message.rows;
    if (rows == null) return;

    final context = EventContext(
      myConnectionId: _connectionId,
      event: UnknownTransactionEvent(),
    );

    for (final single in rows.tables) {
      final table = cache.getTableByName(single.tableName);
      if (table == null) continue;
      if (table.hasPrimaryKey) {
        table.applyServerDelta(
          single.rows,
          BsatnRowList.empty(),
          context,
          querySetId: querySetId,
          protectedKeys: _optimisticState.optimisticPrimaryKeysForTable(
            single.tableName,
          ),
          trackImbalance: false,
        );
      } else {
        table.applyTransactionUpdate(
          single.rows,
          BsatnRowList.empty(),
          context,
        );
      }
    }
  }

  /// Non-caller `TransactionUpdate` — row broadcasts for remote writes.
  /// Wire carries no reducer metadata (v2.rs:302-306); nothing to complete
  /// on the caller side here. Caller completion runs in `_handleReducerResult`.
  void _handleTransactionUpdate(TransactionUpdateMessage message) {
    if (message.querySets.isEmpty) return;

    final context = EventContext(
      myConnectionId: _connectionId,
      event: UnknownTransactionEvent(),
    );

    final touchedTables = <String>{};

    for (final querySet in message.querySets) {
      if (!_subscriptionsByQuerySetId.containsKey(querySet.querySetId)) {
        continue;
      }
      for (final tableUpdate in querySet.tables) {
        final table = cache.getTableByName(tableUpdate.tableName);
        if (table == null) continue;
        touchedTables.add(tableUpdate.tableName);

        void onProtectedKeyCommitted(
          dynamic primaryKey,
          Map<String, dynamic>? committedRowJson,
        ) {
          _optimisticState.stashCommittedState(
            tableUpdate.tableName,
            primaryKey,
            committedRowJson,
          );
        }

        for (final rowGroup in tableUpdate.rows) {
          if (rowGroup is PersistentTableRows) {
            table.applyServerDelta(
              rowGroup.deletes,
              rowGroup.inserts,
              context,
              querySetId: querySet.querySetId,
              protectedKeys: _optimisticState.optimisticPrimaryKeysForTable(
                tableUpdate.tableName,
              ),
              reconcile: true,
              onProtectedKeyCommitted: onProtectedKeyCommitted,
            );
          } else if (rowGroup is EventTableRows) {
            table.applyTransactionUpdate(
              BsatnRowList.empty(),
              rowGroup.events,
              context,
            );
          }
        }
      }
    }

    _mutationSyncer?.persistTableSnapshots(onlyTables: touchedTables);
  }

  void _handleReducerResult(ReducerResultMessage message) {
    final numericRequestId = message.requestId;
    final reducerName = reducers.pendingReducerName(numericRequestId) ?? '';
    final uuidRequestId = reducers.getUuidForRequest(numericRequestId);

    final result = TransactionResult.fromReducerResult(
      message,
      reducerName: reducerName,
    );

    final effectiveRequestId = uuidRequestId ?? numericRequestId.toString();
    final isOurTransaction = uuidRequestId != null;
    final hasOptimistic = _optimisticState.hasOptimisticChange(
      effectiveRequestId,
    );
    final isCommitted = message.status is Committed;

    SdkLogger.d(
      'REDUCER_RESULT: reducer=$reducerName, requestId=$numericRequestId, '
      'status=${message.status}, querySets=${message.querySets.length}, '
      'isOurs=$isOurTransaction, hasOptimistic=$hasOptimistic',
    );

    final context = _buildReducerContext(
      message,
      reducerName,
      numericRequestId,
    );

    if (isOurTransaction && isCommitted && hasOptimistic) {
      _confirmSelfCommit(message, effectiveRequestId, context);
    } else {
      _applyForeignOrRollback(
        message,
        effectiveRequestId,
        isCommitted,
        context,
      );
    }

    reducers.completeRequest(numericRequestId, result);
    final event = context.event;
    if (event is ReducerEvent) {
      reducerEmitter.emit(event.reducerName, context);
    }
  }

  EventContext _buildReducerContext(
    ReducerResultMessage message,
    String reducerName,
    int numericRequestId,
  ) {
    Event event = UnknownTransactionEvent();
    if (reducerName.isNotEmpty) {
      final argsBytes = reducers.pendingArgs(numericRequestId);
      dynamic reducerArgs;
      if (argsBytes != null) {
        reducerArgs = reducerRegistry.deserializeArgs(reducerName, argsBytes);
      }
      event = ReducerEvent(
        timestamp: message.timestamp,
        status: message.status,
        callerIdentity: _identity?.bytes ?? Uint8List(32),
        callerConnectionId: _connectionId,
        reducerName: reducerName,
        reducerArgs: reducerArgs,
      );
    }
    return EventContext(myConnectionId: _connectionId, event: event);
  }

  Map<String, Set<dynamic>> _applyReducerTables(
    ReducerResultMessage message,
    EventContext context, {
    required bool reconcile,
  }) {
    final touchedKeysByTable = <String, Set<dynamic>>{};
    for (final querySet in message.querySets) {
      if (!_subscriptionsByQuerySetId.containsKey(querySet.querySetId)) {
        continue;
      }
      for (final tableUpdate in querySet.tables) {
        final table = cache.getTableByName(tableUpdate.tableName);
        if (table == null) continue;

        final protectedKeys = _optimisticState.optimisticPrimaryKeysForTable(
          tableUpdate.tableName,
        );
        void onProtectedKeyCommitted(
          dynamic primaryKey,
          Map<String, dynamic>? committedRowJson,
        ) {
          _optimisticState.stashCommittedState(
            tableUpdate.tableName,
            primaryKey,
            committedRowJson,
          );
        }

        final touchedKeys = touchedKeysByTable.putIfAbsent(
          tableUpdate.tableName,
          () => <dynamic>{},
        );
        for (final rowGroup in tableUpdate.rows) {
          if (rowGroup is PersistentTableRows) {
            touchedKeys.addAll(
              table.applyServerDelta(
                rowGroup.deletes,
                rowGroup.inserts,
                context,
                querySetId: querySet.querySetId,
                protectedKeys: protectedKeys,
                reconcile: reconcile,
                onProtectedKeyCommitted:
                    reconcile ? onProtectedKeyCommitted : null,
              ),
            );
          } else if (rowGroup is EventTableRows) {
            touchedKeys.addAll(
              table.applyTransactionUpdateAndCollectKeys(
                BsatnRowList.empty(),
                rowGroup.events,
                context,
                protectedKeys: reconcile ? protectedKeys : null,
                reconcile: reconcile,
                onProtectedKeyCommitted:
                    reconcile ? onProtectedKeyCommitted : null,
              ),
            );
          }
        }
      }
    }
    return touchedKeysByTable;
  }

  void _confirmSelfCommit(
    ReducerResultMessage message,
    String effectiveRequestId,
    EventContext context,
  ) {
    final confirmedEntries = _optimisticState.confirmOptimisticChange(
      effectiveRequestId,
    );

    final touchedKeysByTable = _applyReducerTables(
      message,
      context,
      reconcile: true,
    );

    for (final entry in confirmedEntries) {
      final pk = entry.primaryKey;
      if (pk == null) continue;
      final tableName = entry.tableName;
      final table = cache.getTableByName(tableName);
      if (table == null) continue;
      final stillPending = _optimisticState.optimisticPrimaryKeysForTable(
        tableName,
      );
      if (stillPending.contains(pk)) continue;
      final touchedKeys = touchedKeysByTable[tableName] ?? const {};
      switch (entry.type) {
        case OptimisticChangeType.insert:
          if (!touchedKeys.contains(pk)) {
            table.deleteRow(pk);
          }
        case OptimisticChangeType.delete:
        case OptimisticChangeType.update:
          break;
      }
    }

    _mutationSyncer?.persistTableSnapshots(
      onlyTables: touchedKeysByTable.keys.toSet(),
    );
  }

  void _applyForeignOrRollback(
    ReducerResultMessage message,
    String effectiveRequestId,
    bool isCommitted,
    EventContext context,
  ) {
    final touchedKeysByTable = _applyReducerTables(
      message,
      context,
      reconcile: false,
    );

    if (isCommitted) {
      _optimisticState.confirmOrRollbackWithTouchedKeys(
        effectiveRequestId,
        touchedKeysByTable,
      );
    } else {
      _optimisticState.rollbackOptimisticChanges(effectiveRequestId);
    }

    _mutationSyncer?.persistTableSnapshots(
      onlyTables: touchedKeysByTable.keys.toSet(),
    );
  }

  Future<void> _sendSubscribeAndWait(
    int querySetId,
    List<String> queries,
  ) async {
    final message = SubscribeMessage(queries, querySetId: querySetId);
    _connection.send(message.encode());

    final waiter = _subscribeWaiters.putIfAbsent(
      querySetId,
      Completer<void>.new,
    );
    try {
      await waiter.future;
    } finally {
      if (identical(_subscribeWaiters[querySetId], waiter)) {
        _subscribeWaiters.remove(querySetId);
      }
    }
  }
}
