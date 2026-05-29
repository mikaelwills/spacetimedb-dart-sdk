import 'dart:async';
import 'dart:typed_data';

import 'package:meta/meta.dart';
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

  SubscriptionManager(this._connection, {OfflineStorage? offlineStorage}) {
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
      );
      caller = ReducerCaller(
        _connection,
        offlineStorage: offlineStorage,
        mutationHandler: _mutationSyncer,
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

  @visibleForTesting
  Map<int, List<String>> get subscriptionsByQuerySetId =>
      _subscriptionsByQuerySetId;

  /// All currently-subscribed query strings across every active `QuerySetId`.
  @visibleForTesting
  Set<String> get activeSubscriptionQueries =>
      _subscriptionsByQuerySetId.values.expand((q) => q).toSet();

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
  Future<int> subscribe(List<String> queries) async {
    final querySetId = _nextQuerySetId++;
    _subscriptionsByQuerySetId[querySetId] = List.of(queries);

    final message = SubscribeMessage(queries, querySetId: querySetId);
    _connection.send(message.encode());

    await onSubscribeApplied.firstWhere((m) => m.querySetId == querySetId);
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

  // --- Lifecycle ---

  Future<void> dispose() async {
    _disposed = true;
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
    await _mutationSyncer?.dispose();
  }

  void _startConnectionMonitoring() {
    bool hasConnectedBefore = false;

    _connectionStatusSubscription = _connection.onStateChanged.listen((state) {
      if (state is Connected) {
        if (hasConnectedBefore) {
          _mutationSyncer?.resetRetryAttempts();
          _onReconnected();
        }
        hasConnectedBefore = true;
      } else if (state is Disconnected ||
          state is FatalError ||
          state is AuthError) {
        _mutationSyncer?.cancelRetry();
        reducers.failAllPendingRequests(state.displayName);
      }
    });
  }

  Future<void> _onReconnected() async {
    if (_subscriptionsByQuerySetId.isNotEmpty) {
      SdkLogger.i(
        'Re-subscribing to ${_subscriptionsByQuerySetId.length} query sets...',
      );
      for (final entry in _subscriptionsByQuerySetId.entries) {
        final message = SubscribeMessage(entry.value, querySetId: entry.key);
        _connection.send(message.encode());
      }
    } else if (_mutationSyncer != null) {
      SdkLogger.i(
        'No active subscriptions, syncing pending mutations directly...',
      );
      _mutationSyncer!.syncPendingMutations();
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
        _handleSubscribeApplied(message).then((_) {
          if (_disposed) return;
          _subscribeAppliedController.add(message);
          SdkLogger.i('Syncing pending mutations after SubscribeApplied...');
          _mutationSyncer?.syncPendingMutations();
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
      return;
    }

    final badTable = tableNameMatch.group(1)!;
    final queries = _subscriptionsByQuerySetId[message.querySetId];
    if (queries == null) {
      SdkLogger.e(
        'Subscription error for unknown querySetId ${message.querySetId}: ${message.error}',
      );
      return;
    }

    final badQuery = queries.firstWhere(
      (q) => RegExp('FROM\\s+$badTable', caseSensitive: false).hasMatch(q),
      orElse: () => '',
    );

    if (badQuery.isEmpty) {
      SdkLogger.e(
        'Subscription error for unknown table "$badTable": ${message.error}',
      );
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

    final serverTableNames =
        message.rows.tables.map((t) => t.tableName).toSet();
    for (final table in cache.allTables) {
      if (!serverTableNames.contains(table.tableName)) {
        _optimisticState.clearNonOptimisticRows(table.tableName);
      }
    }

    for (final single in message.rows.tables) {
      final table = cache.getTableByName(single.tableName);
      if (table == null) continue;

      SdkLogger.d('  Table "${single.tableName}": applying initial rows');
      _optimisticState.clearNonOptimisticRows(single.tableName);
      table.applyInitialData(single.rows, context);
      table.markSubscribed();
    }

    // Server omits tables with zero matching rows from `tables`. Parse
    // FROM <table> out of the active queries in this set and mark those
    // tables subscribed too, so `client.<table>.subscribed` resolves for
    // empty initial results instead of hanging forever.
    final fromRegex = RegExp(r'FROM\s+(\w+)', caseSensitive: false);
    final queries = _subscriptionsByQuerySetId[message.querySetId] ?? const [];
    for (final query in queries) {
      for (final match in fromRegex.allMatches(query)) {
        final tableName = match.group(1)!;
        final table = cache.getTableByName(tableName);
        table?.markSubscribed();
      }
    }

    await _mutationSyncer?.persistTableSnapshots();
  }

  /// Apply the optional dropped-rows payload on `UnsubscribeApplied` as
  /// deletes against the local cache (slice 5). When `rows` is null, the
  /// server honoured `UnsubscribeFlags::Default` — no delete events fire.
  void _handleUnsubscribeApplied(UnsubscribeApplied message) {
    _subscriptionsByQuerySetId.remove(message.querySetId);

    final rows = message.rows;
    if (rows == null) return;

    final context = EventContext(
      myConnectionId: _connectionId,
      event: UnknownTransactionEvent(),
    );

    for (final single in rows.tables) {
      final table = cache.getTableByName(single.tableName);
      if (table == null) continue;
      table.applyTransactionUpdate(single.rows, BsatnRowList.empty(), context);
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

    final tableUpdates = message.querySets
        .expand((qs) => qs.tables)
        .toList(growable: false);

    for (final tableUpdate in tableUpdates) {
      final table = cache.getTableByName(tableUpdate.tableName);
      if (table == null) continue;

      for (final rowGroup in tableUpdate.rows) {
        if (rowGroup is PersistentTableRows) {
          table.applyTransactionUpdate(
            rowGroup.deletes,
            rowGroup.inserts,
            context,
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

    _mutationSyncer?.persistTableSnapshots(
      onlyTables: tableUpdates.map((tu) => tu.tableName).toSet(),
    );
  }

  /// Caller's own reducer result (v2 `ReducerResult`).
  ///
  /// **Ordering invariant (skeptical I5):** the optimistic-state lookup by
  /// numeric request id must run BEFORE `reducers.completeRequest(...)`, which
  /// removes the entry from `_pendingRequests`. Flipping the order
  /// double-applies optimistic inserts on commit and skips rollback on failure.
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
    final context = EventContext(myConnectionId: _connectionId, event: event);

    // Short-circuit for self-initiated commits with optimistic state in flight:
    // confirm, persist only the touched tables, done.
    if (isOurTransaction && isCommitted && hasOptimistic) {
      _optimisticState.confirmOptimisticChange(effectiveRequestId);
      _mutationSyncer?.persistTableSnapshots(
        onlyTables:
            message.querySets
                .expand((qs) => qs.tables)
                .map((tu) => tu.tableName)
                .toSet(),
      );
      reducers.completeRequest(numericRequestId, result);
      if (event is ReducerEvent) {
        reducerEmitter.emit(event.reducerName, context);
      }
      return;
    }

    // Dispatch the nested TransactionUpdate tables to the cache.
    final tableUpdates = message.querySets
        .expand((qs) => qs.tables)
        .toList(growable: false);

    final touchedKeysByTable = <String, Set<dynamic>>{};
    for (final tableUpdate in tableUpdates) {
      final table = cache.getTableByName(tableUpdate.tableName);
      if (table == null) continue;

      final touchedKeys = <dynamic>{};
      for (final rowGroup in tableUpdate.rows) {
        if (rowGroup is PersistentTableRows) {
          final keys = table.applyTransactionUpdateAndCollectKeys(
            rowGroup.deletes,
            rowGroup.inserts,
            context,
          );
          touchedKeys.addAll(keys);
        } else if (rowGroup is EventTableRows) {
          final keys = table.applyTransactionUpdateAndCollectKeys(
            BsatnRowList.empty(),
            rowGroup.events,
            context,
          );
          touchedKeys.addAll(keys);
        }
      }
      touchedKeysByTable[tableUpdate.tableName] = touchedKeys;
    }

    if (isCommitted) {
      _optimisticState.confirmOrRollbackWithTouchedKeys(
        effectiveRequestId,
        touchedKeysByTable,
      );
    } else {
      _optimisticState.rollbackOptimisticChanges(effectiveRequestId);
    }

    _mutationSyncer?.persistTableSnapshots(
      onlyTables: tableUpdates.map((tu) => tu.tableName).toSet(),
    );

    reducers.completeRequest(numericRequestId, result);

    if (event is ReducerEvent) {
      reducerEmitter.emit(event.reducerName, context);
    }
  }
}
