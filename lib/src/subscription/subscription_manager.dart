import 'dart:async';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:spacetimedb_dart_sdk/src/cache/client_cache.dart';
import 'package:spacetimedb_dart_sdk/src/utils/sdk_logger.dart';

import '../connection/spacetimedb_connection.dart';
import '../connection/connection_state.dart';
import '../messages/message_decoder.dart';
import '../messages/server_messages.dart';
import '../messages/shared_types.dart' show TableUpdate;
import '../messages/client_messages.dart';
import '../reducers/reducer_caller.dart';
import '../reducers/reducer_registry.dart';
import '../reducers/reducer_emitter.dart';
import '../reducers/transaction_result.dart';
import '../events/event.dart';
import '../events/event_context.dart';
import '../auth/identity.dart';
import '../offline/offline_storage.dart';
import '../offline/sync_state.dart';
import '../offline/pending_mutation.dart';
import '../offline/optimistic_state_manager.dart';
import '../offline/mutation_syncer.dart';
import '../messages/update_status.dart';

class SubscriptionManager {
  final SpacetimeDbConnection _connection;
  final ClientCache cache = ClientCache();
  late final ReducerCaller reducers;
  final ReducerRegistry reducerRegistry = ReducerRegistry();
  final ReducerEmitter reducerEmitter = ReducerEmitter();

  Identity? _identity;
  String? _address;
  Uint8List? _connectionId;

  final Set<String> _activeSubscriptionQueries = {};

  late final OptimisticStateManager _optimisticState;
  MutationSyncer? _mutationSyncer;
  bool _disposed = false;

  final _initialSubscriptionController =
      StreamController<InitialSubscriptionMessage>.broadcast();
  final _transactionUpdateController =
      StreamController<TransactionUpdateMessage>.broadcast();
  final _transactionUpdateLightController =
      StreamController<TransactionUpdateLightMessage>.broadcast();
  final _identityTokenController =
      StreamController<IdentityTokenMessage>.broadcast();
  final _oneOffQueryResponseController =
      StreamController<OneOffQueryResponse>.broadcast();
  final _subscribeAppliedController =
      StreamController<SubscribeApplied>.broadcast();
  final _unsubscribeAppliedController =
      StreamController<UnsubscribeApplied>.broadcast();
  final _subscriptionErrorController =
      StreamController<SubscriptionErrorMessage>.broadcast();
  final _subscribeMultiAppliedController =
      StreamController<SubscribeMultiApplied>.broadcast();
  final _unsubscribeMultiAppliedController =
      StreamController<UnsubscribeMultiApplied>.broadcast();
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
  Set<String> get activeSubscriptionQueries => _activeSubscriptionQueries;

  Stream<InitialSubscriptionMessage> get onInitialSubscription =>
      _initialSubscriptionController.stream;
  Stream<TransactionUpdateMessage> get onTransactionUpdate =>
      _transactionUpdateController.stream;
  Stream<TransactionUpdateLightMessage> get onTransactionUpdateLight =>
      _transactionUpdateLightController.stream;
  Stream<IdentityTokenMessage> get onIdentityToken =>
      _identityTokenController.stream;
  Stream<OneOffQueryResponse> get onOneOffQueryResponse =>
      _oneOffQueryResponseController.stream;
  Stream<SubscribeApplied> get onSubscribeApplied =>
      _subscribeAppliedController.stream;
  Stream<UnsubscribeApplied> get onUnsubscribeApplied =>
      _unsubscribeAppliedController.stream;
  Stream<SubscriptionErrorMessage> get onSubscriptionError =>
      _subscriptionErrorController.stream;
  Stream<SubscribeMultiApplied> get onSubscribeMultiApplied =>
      _subscribeMultiAppliedController.stream;
  Stream<UnsubscribeMultiApplied> get onUnsubscribeMultiApplied =>
      _unsubscribeMultiAppliedController.stream;
  Stream<ProcedureResultMessage> get onProcedureResult =>
      _procedureResultController.stream;

  Identity? get identity => _identity;
  String? get address => _address;

  // --- Connection Monitoring ---

  void _startConnectionMonitoring() {
    bool wasReconnecting = false;

    _connectionStatusSubscription = _connection.onStateChanged.listen((state) {
      if (state is Reconnecting) {
        wasReconnecting = true;
      } else if (state is Connected && wasReconnecting) {
        wasReconnecting = false;
        _mutationSyncer?.resetRetryAttempts();
        _onReconnected();
      } else if (state is Disconnected ||
          state is FatalError ||
          state is AuthError) {
        wasReconnecting = false;
        _mutationSyncer?.cancelRetry();
        reducers.failAllPendingRequests(state.displayName);
      }
    });
  }

  Future<void> _onReconnected() async {
    if (_activeSubscriptionQueries.isNotEmpty) {
      SdkLogger.i(
        'Re-subscribing to ${_activeSubscriptionQueries.length} queries...',
      );
      final message = SubscribeMessage(_activeSubscriptionQueries.toList());
      _connection.send(message.encode());
    } else if (_mutationSyncer != null) {
      SdkLogger.i(
        'No active subscriptions, syncing pending mutations directly...',
      );
      _mutationSyncer!.syncPendingMutations();
    }
  }

  // --- Message Handling ---

  void _startListening() {
    _messageSubscription = _connection.onMessage.listen(_handleMessage);
  }

  void _handleMessage(Uint8List bytes) {
    if (_disposed) return;
    try {
      final message = MessageDecoder.decode(bytes);
      _routeMessage(message);
    } catch (e) {
      SdkLogger.e('Error decoding message: $e');
    }
  }

  void _routeMessage(ServerMessage message) {
    if (_disposed) return;
    switch (message) {
      case IdentityTokenMessage():
        _identity = Identity(message.identity);
        _connectionId = message.connectionId;
        _address =
            message.connectionId
                .map((b) => b.toRadixString(16).padLeft(2, '0'))
                .join();
        _identityTokenController.add(message);
      case InitialSubscriptionMessage():
        _handleInitialSubscription(message).then((_) {
          if (_disposed) return;
          _initialSubscriptionController.add(message);
          SdkLogger.i(
            'Syncing pending mutations after initial subscription...',
          );
          _mutationSyncer?.syncPendingMutations();
        });
      case TransactionUpdateMessage():
        _handleTransactionUpdate(message);
        _transactionUpdateController.add(message);
      case TransactionUpdateLightMessage():
        _handleTransactionUpdateLight(message);
        _transactionUpdateLightController.add(message);
      case OneOffQueryResponse():
        _oneOffQueryResponseController.add(message);
      case SubscribeApplied():
        _subscribeAppliedController.add(message);
      case UnsubscribeApplied():
        _unsubscribeAppliedController.add(message);
      case SubscriptionErrorMessage():
        _handleSubscriptionError(message);
        _subscriptionErrorController.add(message);
      case SubscribeMultiApplied():
        _subscribeMultiAppliedController.add(message);
      case UnsubscribeMultiApplied():
        _unsubscribeMultiAppliedController.add(message);
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
    final badQuery = _activeSubscriptionQueries.firstWhere(
      (q) => RegExp('FROM\\s+$badTable', caseSensitive: false).hasMatch(q),
      orElse: () => '',
    );

    if (badQuery.isEmpty) {
      SdkLogger.e(
        'Subscription error for unknown table "$badTable": ${message.error}',
      );
      return;
    }

    _activeSubscriptionQueries.remove(badQuery);
    SdkLogger.w(
      'Subscription failed for table "$badTable", removed query. Resubscribing with ${_activeSubscriptionQueries.length} remaining queries...',
    );

    if (_activeSubscriptionQueries.isNotEmpty) {
      final resubscribe = SubscribeMessage(_activeSubscriptionQueries.toList());
      _connection.send(resubscribe.encode());
    }
  }

  // --- Transaction Processing ---

  Future<void> _handleInitialSubscription(
    InitialSubscriptionMessage message,
  ) async {
    SdkLogger.d(
      'Handling InitialSubscription with ${message.tableUpdates.length} table updates',
    );

    final event = SubscribeAppliedEvent();
    final context = EventContext(myConnectionId: _connectionId, event: event);

    final serverTableNames =
        message.tableUpdates.map((t) => t.tableName).toSet();
    for (final table in cache.allTables) {
      if (!serverTableNames.contains(table.tableName)) {
        _optimisticState.clearNonOptimisticRows(table.tableName);
      }
    }

    for (final tableUpdate in message.tableUpdates) {
      final table = cache.getTableByName(tableUpdate.tableName);
      if (table == null) continue;

      SdkLogger.d(
        '  Table "${tableUpdate.tableName}": ${tableUpdate.updates.length} updates',
      );

      _optimisticState.clearNonOptimisticRows(tableUpdate.tableName);

      for (final update in tableUpdate.updates) {
        final rows = update.update.inserts.getRows();
        SdkLogger.d('    Inserting ${rows.length} rows');
        table.applyInitialData(update.update.inserts, context);
      }
    }

    await _mutationSyncer?.persistTableSnapshots();
  }

  void _handleTransactionUpdate(TransactionUpdateMessage message) {
    final numericRequestId = message.reducerCall.requestId;

    final isEventOnly = message.tableUpdates.every(
      (tu) => cache.isEventTable(tu.tableName),
    );
    if (isEventOnly) {
      final result = TransactionResult.fromTransactionUpdate(message);
      reducers.completeRequest(numericRequestId, result);
      _applyEventOnlyUpdates(message.tableUpdates);
      return;
    }

    SdkLogger.d(
      'TXN_UPDATE: reducer=${message.reducerCall.reducerName}, tables=${message.tableUpdates.length}, status=${message.status}, requestId=$numericRequestId',
    );
    if (message.status is Failed) {
      SdkLogger.w('TXN_FAILED: ${(message.status as Failed).message}');
    }

    Event event;
    final reducerArgs = reducerRegistry.deserializeArgs(
      message.reducerCall.reducerName,
      message.reducerCall.args,
    );

    if (reducerArgs != null) {
      event = ReducerEvent(
        timestamp: message.timestamp,
        status: message.status,
        callerIdentity: message.callerIdentity,
        callerConnectionId: message.callerConnectionId,
        energyConsumed: message.energyQuantaUsed,
        reducerName: message.reducerCall.reducerName,
        reducerArgs: reducerArgs,
      );
    } else {
      event = UnknownTransactionEvent();
    }

    final context = EventContext(myConnectionId: _connectionId, event: event);

    if (event is ReducerEvent) {
      reducerEmitter.emit(event.reducerName, context);
    }

    _processTransaction(
      numericRequestId: numericRequestId,
      tableUpdates: message.tableUpdates,
      context: context,
      isCommitted: message.status is Committed,
      canRollbackOnFailure: true,
    );

    final result = TransactionResult.fromTransactionUpdate(message);
    reducers.completeRequest(numericRequestId, result);
  }

  void _handleTransactionUpdateLight(TransactionUpdateLightMessage message) {
    final numericRequestId = message.requestId;

    final isEventOnly = message.tableUpdates.every(
      (tu) => cache.isEventTable(tu.tableName),
    );
    if (isEventOnly) {
      final result = TransactionResult.fromTransactionUpdateLight(message);
      reducers.completeRequest(numericRequestId, result);
      _applyEventOnlyUpdates(message.tableUpdates);
      return;
    }

    SdkLogger.d(
      'TXN_LIGHT: requestId=$numericRequestId, tables=${message.tableUpdates.length}',
    );

    final context = EventContext(
      myConnectionId: _connectionId,
      event: UnknownTransactionEvent(),
    );

    _processTransaction(
      numericRequestId: numericRequestId,
      tableUpdates: message.tableUpdates,
      context: context,
      isCommitted: true,
      canRollbackOnFailure: false,
    );

    final result = TransactionResult.fromTransactionUpdateLight(message);
    reducers.completeRequest(numericRequestId, result);
  }

  void _applyEventOnlyUpdates(List<TableUpdate> tableUpdates) {
    final context = EventContext(
      myConnectionId: _connectionId,
      event: UnknownTransactionEvent(),
    );
    for (final tableUpdate in tableUpdates) {
      final table = cache.getTableByName(tableUpdate.tableName);
      if (table == null) continue;
      for (final update in tableUpdate.updates) {
        table.applyTransactionUpdate(
          update.update.deletes,
          update.update.inserts,
          context,
        );
      }
    }
  }

  void _processTransaction({
    required int numericRequestId,
    required List<TableUpdate> tableUpdates,
    required EventContext context,
    required bool isCommitted,
    required bool canRollbackOnFailure,
  }) {
    final uuidRequestId = reducers.getUuidForRequest(numericRequestId);
    final effectiveRequestId = uuidRequestId ?? numericRequestId.toString();
    final isOurTransaction = uuidRequestId != null;
    final hasOptimistic = _optimisticState.hasOptimisticChange(
      effectiveRequestId,
    );

    SdkLogger.d(
      'TXN: requestId=$numericRequestId, uuid=$uuidRequestId, ours=$isOurTransaction, committed=$isCommitted, optimistic=$hasOptimistic',
    );

    if (isOurTransaction && isCommitted && hasOptimistic) {
      _optimisticState.confirmOptimisticChange(effectiveRequestId);
      _mutationSyncer?.persistTableSnapshots(
        onlyTables: tableUpdates.map((tu) => tu.tableName).toSet(),
      );
      return;
    }

    final touchedKeysByTable = <String, Set<dynamic>>{};
    for (final tableUpdate in tableUpdates) {
      final table = cache.getTableByName(tableUpdate.tableName);
      if (table == null) continue;

      final touchedKeys = <dynamic>{};
      for (final update in tableUpdate.updates) {
        final keys = table.applyTransactionUpdateAndCollectKeys(
          update.update.deletes,
          update.update.inserts,
          context,
        );
        touchedKeys.addAll(keys);
      }
      touchedKeysByTable[tableUpdate.tableName] = touchedKeys;
    }

    if (isCommitted) {
      _optimisticState.confirmOrRollbackWithTouchedKeys(
        effectiveRequestId,
        touchedKeysByTable,
      );
    } else if (canRollbackOnFailure) {
      _optimisticState.rollbackOptimisticChanges(effectiveRequestId);
    }

    _mutationSyncer?.persistTableSnapshots(
      onlyTables: tableUpdates.map((tu) => tu.tableName).toSet(),
    );
  }

  // --- Subscription API ---

  Future<void> subscribe(List<String> queries) async {
    _activeSubscriptionQueries.addAll(queries);

    final message = SubscribeMessage(queries);
    _connection.send(message.encode());

    await onInitialSubscription.first;
  }

  void subscribeSingle(String query, {int requestId = 0, int queryId = 0}) {
    final message = SubscribeSingleMessage(
      query,
      requestId: requestId,
      queryId: queryId,
    );
    _connection.send(message.encode());
  }

  void subscribeMulti(
    List<String> queries, {
    int requestId = 0,
    int queryId = 0,
  }) {
    final message = SubscribeMultiMessage(
      queries,
      requestId: requestId,
      queryId: queryId,
    );
    _connection.send(message.encode());
  }

  void oneOffQuery(Uint8List messageId, String query) {
    final message = OneOffQueryMessage(
      messageId: messageId,
      queryString: query,
    );
    _connection.send(message.encode());
  }

  void unsubscribe(int queryId, {int requestId = 0}) {
    final message = UnsubscribeMessage(queryId: queryId, requestId: requestId);
    _connection.send(message.encode());
  }

  void unsubscribeMulti(int queryId, {int requestId = 0}) {
    final message = UnsubscribeMultiMessage(
      queryId: queryId,
      requestId: requestId,
    );
    _connection.send(message.encode());
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
    _initialSubscriptionController.close();
    _transactionUpdateController.close();
    _transactionUpdateLightController.close();
    _identityTokenController.close();
    _oneOffQueryResponseController.close();
    _subscribeAppliedController.close();
    _unsubscribeAppliedController.close();
    _subscriptionErrorController.close();
    _subscribeMultiAppliedController.close();
    _unsubscribeMultiAppliedController.close();
    _procedureResultController.close();
    reducerEmitter.dispose();
    await _mutationSyncer?.dispose();
  }
}
