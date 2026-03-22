import 'dart:async';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:spacetimedb_dart_sdk/src/cache/client_cache.dart';
import 'package:spacetimedb_dart_sdk/src/utils/sdk_logger.dart';

import '../connection/spacetimedb_connection.dart';
import '../connection/connection_status.dart';
import '../messages/message_decoder.dart';
import '../messages/server_messages.dart';
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
import '../messages/update_status.dart';

/// Manages table subscriptions and processes real-time updates from SpacetimeDB
///
/// The SubscriptionManager handles:
/// - SQL subscription management (subscribe/unsubscribe)
/// - Real-time database updates via WebSocket
/// - Client-side caching of subscribed data
/// - Reducer and procedure calls
///
/// Example:
/// ```dart
/// final connection = SpacetimeDbConnection(
///   host: 'localhost:3000',
///   database: 'mydb',
/// );
///
/// final subscriptionManager = SubscriptionManager(connection);
///
/// // Register table decoder
/// subscriptionManager.cache.registerDecoder<Note>('note', NoteDecoder());
///
/// await connection.connect();
///
/// // Subscribe to updates (this activates the table)
/// await subscriptionManager.subscribe(['SELECT * FROM note']);
///
/// // Listen for initial data
/// await subscriptionManager.onInitialSubscription.first;
///
/// // Access cached data
/// final noteTable = subscriptionManager.cache.getTable<Note>(4096);
/// for (final note in noteTable.iter()) {
///   print(note.title);
/// }
///
/// // Call a reducer
/// await subscriptionManager.reducers.callWith('create_note', (encoder) {
///   encoder.writeString('My Note');
///   encoder.writeString('Content here');
/// });
/// ```
class SubscriptionManager {
  final SpacetimeDbConnection _connection;
  final ClientCache cache = ClientCache();
  late final ReducerCaller reducers;
  final ReducerRegistry reducerRegistry = ReducerRegistry();
  final ReducerEmitter reducerEmitter = ReducerEmitter();

  Identity? _identity;
  String? _address;
  Uint8List? _connectionId;

  List<String> _pendingTableNames = [];
  final Set<String> _activeSubscriptionQueries = {};

  final OfflineStorage? _offlineStorage;
  late final OptimisticStateManager _optimisticState;
  bool _offlineStorageInitialized = false;
  bool _disposed = false;
  bool _initialSubscriptionReceived = false;
  final StreamController<SyncState> _syncStateController =
      StreamController<SyncState>.broadcast();
  final StreamController<MutationSyncResult> _mutationSyncResultController =
      StreamController<MutationSyncResult>.broadcast();
  SyncState _currentSyncState = const SyncState();
  int _cachedPendingCount = 0;

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
  StreamSubscription<ConnectionStatus>? _connectionStatusSubscription;

  Timer? _retryTimer;
  int _retryAttempt = 0;
  static const Duration _initialRetryDelay = Duration(seconds: 5);
  static const Duration _maxRetryDelay = Duration(seconds: 60);

  SubscriptionManager(this._connection, {OfflineStorage? offlineStorage})
      : _offlineStorage = offlineStorage {
    _optimisticState = OptimisticStateManager(cache);
    reducers = ReducerCaller(_connection, offlineStorage: offlineStorage);
    reducers.onMutationQueued = _onMutationQueued;
    reducers.onOptimisticChanges = _onOptimisticChanges;
    reducers.onRollbackOptimistic = _onRollbackOptimistic;
    reducers.onTrySyncNow = _trySyncNow;
    _startListening();
    _startConnectionMonitoring();
  }

  bool _isSyncing = false;

  void _trySyncNow() {
    if (_isSyncing) {
      SdkLogger.d('Sync already in progress, skipping duplicate trigger');
      return;
    }
    SdkLogger.i('Immediate sync triggered by reducer call');
    syncPendingMutations();
  }

  void _onMutationQueued(String requestId, List<OptimisticChange>? changes) {
    SdkLogger.d('_onMutationQueued called: requestId=$requestId, changes=${changes?.length ?? 0}');
    _cachedPendingCount++;
    _updateSyncState(_currentSyncState.copyWith(
      pendingCount: _cachedPendingCount,
    ));
  }

  void _onOptimisticChanges(String requestId, List<OptimisticChange>? changes) {
    _optimisticState.applyOptimisticChanges(requestId, changes);
    _persistTableSnapshots();
  }

  void _onRollbackOptimistic(String requestId) {
    SdkLogger.w('Rolling back optimistic changes for request $requestId due to timeout/failure');
    _optimisticState.rollbackOptimisticChanges(requestId);
    _persistTableSnapshots();
  }

  void _startConnectionMonitoring() {
    if (_offlineStorage == null) return;

    ConnectionStatus? previousStatus;

    _connectionStatusSubscription =
        _connection.connectionStatus.listen((status) {
      if (status == ConnectionStatus.connected &&
          previousStatus == ConnectionStatus.reconnecting) {
        _retryAttempt = 0;
        _onReconnected();
      } else if (status == ConnectionStatus.disconnected) {
        _cancelRetry();
        _initialSubscriptionReceived = false;
      }

      previousStatus = status;
    });
  }

  Future<void> _onReconnected() async {
    if (_activeSubscriptionQueries.isNotEmpty) {
      SdkLogger.i('Re-subscribing to ${_activeSubscriptionQueries.length} queries...');
      final message = SubscribeMessage(_activeSubscriptionQueries.toList());
      _connection.send(message.encode());
    } else {
      SdkLogger.i('No active subscriptions, syncing pending mutations directly...');
      syncPendingMutations();
    }
  }

  Stream<SyncState> get onSyncStateChanged => _syncStateController.stream;
  Stream<MutationSyncResult> get onMutationSyncResult => _mutationSyncResultController.stream;
  SyncState get syncState => _currentSyncState;
  bool get hasOfflineStorage => _offlineStorage != null;

  @visibleForTesting
  Set<String> get activeSubscriptionQueries => _activeSubscriptionQueries;

  void _updateSyncState(SyncState state) {
    if (_disposed) return;
    final prev = _currentSyncState;
    if (prev.status != state.status || prev.pendingCount != state.pendingCount) {
      SdkLogger.d('SyncState: ${prev.status}(${prev.pendingCount}) -> ${state.status}(${state.pendingCount})');
    }
    _currentSyncState = state;
    _syncStateController.add(state);
  }

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

  /// Current user identity (32-byte public key hash)
  ///
  /// Available after connection is established and IdentityToken message is received.
  /// Use `identity?.toHexString` for ownership checks or `identity?.toAbbreviated` for UI display.
  Identity? get identity => _identity;

  /// Current connection address (16-byte connection ID as hex string)
  ///
  /// Available after connection is established and IdentityToken message is received.
  String? get address => _address;

  void _startListening() {
    _messageSubscription = _connection.onMessage.listen(_handleMessage);
  }

  /// Handle incoming binary messages
  void _handleMessage(Uint8List bytes) {
    if (_disposed) return;
    try {
      final message = MessageDecoder.decode(bytes);
      _routeMessage(message);
    } catch (e) {
      SdkLogger.e('Error decoding message: $e');
    }
  }

  /// Route decoded messages to appropriate streams
  void _routeMessage(ServerMessage message) {
    if (_disposed) return;
    switch (message) {
      case IdentityTokenMessage():
        // Store identity and address for public access
        _identity = Identity(message.identity);
        _connectionId = message.connectionId;
        _address = message.connectionId
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join();
        _identityTokenController.add(message);
      case InitialSubscriptionMessage():
        _handleInitialSubscription(message).then((_) {
          if (_disposed) return;
          _initialSubscriptionReceived = true;
          _initialSubscriptionController.add(message);
          SdkLogger.i('Syncing pending mutations after initial subscription...');
          syncPendingMutations();
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
    final tableNameMatch = RegExp(r'`(\w+)` is not a valid table').firstMatch(message.error);
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
      SdkLogger.e('Subscription error for unknown table "$badTable": ${message.error}');
      return;
    }

    _activeSubscriptionQueries.remove(badQuery);
    SdkLogger.w('Subscription failed for table "$badTable", removed query. Resubscribing with ${_activeSubscriptionQueries.length} remaining queries...');

    if (_activeSubscriptionQueries.isNotEmpty) {
      _pendingTableNames = _extractTableNames(_activeSubscriptionQueries.toList());
      final resubscribe = SubscribeMessage(_activeSubscriptionQueries.toList());
      _connection.send(resubscribe.encode());
    }
  }

  Future<void> _handleInitialSubscription(InitialSubscriptionMessage message) async {
    SdkLogger.i('Handling InitialSubscription with ${message.tableUpdates.length} table updates');

    // Phase 1: Link tables to server IDs (preserving existing TableCache instances from offline cache)
    for (final tableUpdate in message.tableUpdates) {
      SdkLogger.i('  Linking table "${tableUpdate.tableName}" to ID ${tableUpdate.tableId}');
      cache.linkTableId(tableUpdate.tableId, tableUpdate.tableName);
    }

    // Phase 1.5: Activate empty tables that weren't included in tableUpdates
    // The server doesn't include tables with 0 rows in the InitialSubscription
    final activatedTableNames = message.tableUpdates.map((t) => t.tableName).toSet();
    for (final tableName in _pendingTableNames) {
      if (!activatedTableNames.contains(tableName)) {
        // Table was subscribed but has no rows - activate it as empty
        if (cache.activateEmptyTable(tableName)) {
          SdkLogger.i('  Activating empty table "$tableName"');
        }
      }
    }
    // Clear pending table names
    _pendingTableNames = [];

    // Phase 2: Create EventContext with SubscribeAppliedEvent
    final event = SubscribeAppliedEvent();
    final context = EventContext(
      myConnectionId: _connectionId,
      event: event,
    );

    // Phase 3: Clear zombie rows from ALL cached tables
    // Tables not in server response are empty - clear them too
    final serverTableNames = message.tableUpdates.map((t) => t.tableName).toSet();
    for (final table in cache.allTables) {
      if (!serverTableNames.contains(table.tableName)) {
        _optimisticState.clearNonOptimisticRows(table.tableName);
      }
    }

    // Phase 4: Process the data with context
    for (final tableUpdate in message.tableUpdates) {
      if (!cache.hasTable(tableUpdate.tableId)) {
        continue;
      }

      final table = cache.getTable(tableUpdate.tableId);
      SdkLogger.i('  Table ${tableUpdate.tableId} ("${tableUpdate.tableName}"): ${tableUpdate.updates.length} updates');

      _optimisticState.clearNonOptimisticRows(tableUpdate.tableName);

      for (final update in tableUpdate.updates) {
        final rows = update.update.inserts.getRows();
        SdkLogger.i('    Inserting ${rows.length} rows');
        table.applyInitialData(update.update.inserts, context);
      }
    }

    await _persistTableSnapshots();
  }

  Future<void> _persistTableSnapshots() async {
    final storage = _offlineStorage;
    if (storage == null || _disposed) return;
    try {
      for (final tableName in cache.activatedTableNames) {
        if (cache.isEventTable(tableName)) continue;
        final table = cache.getTableByName(tableName);
        if (table != null && table.decoder.supportsJsonSerialization) {
          final rows = table.toSerializable();
          await storage.saveTableSnapshot(tableName, rows);
          await storage.setLastSyncTime(tableName, DateTime.now());
        }
      }
    } catch (e) {
      SdkLogger.e('Error persisting table snapshots: $e');
    }
  }

  void _handleTransactionUpdate(TransactionUpdateMessage message) {
    final isEventOnly = message.tableUpdates.every((tu) => cache.isEventTable(tu.tableName));

    if (isEventOnly) {
      final numericRequestId = message.reducerCall.requestId;
      final result = TransactionResult.fromTransactionUpdate(message);
      reducers.completeRequest(numericRequestId, result);

      final context = EventContext(
        myConnectionId: _connectionId,
        event: UnknownTransactionEvent(),
      );
      for (final tableUpdate in message.tableUpdates) {
        final table = cache.linkTableId(tableUpdate.tableId, tableUpdate.tableName);
        if (table == null) continue;
        for (final update in tableUpdate.updates) {
          table.applyTransactionUpdate(
            update.update.deletes,
            update.update.inserts,
            context,
          );
        }
      }
      return;
    }

    SdkLogger.i('TXN_UPDATE: reducer=${message.reducerCall.reducerName}, tables=${message.tableUpdates.length}, status=${message.status}, requestId=${message.reducerCall.requestId}');
    for (final tu in message.tableUpdates) {
      SdkLogger.i('  TABLE: ${tu.tableName}, updates=${tu.updates.length}');
    }
    if (message.status is Failed) {
      SdkLogger.w('TXN_FAILED: ${(message.status as Failed).message}');
    }

    final numericRequestId = message.reducerCall.requestId;
    final uuidRequestId = reducers.getUuidForRequest(numericRequestId);
    final effectiveRequestId = uuidRequestId ?? numericRequestId.toString();

    final result = TransactionResult.fromTransactionUpdate(message);
    reducers.completeRequest(numericRequestId, result);

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

      SdkLogger.i('Transaction caused by reducer: ${message.reducerCall.reducerName}');
      SdkLogger.i('Arguments: $reducerArgs');
      SdkLogger.i('Status: ${message.status}');
    } else {
      event = UnknownTransactionEvent();
      SdkLogger.i('Failed to deserialize reducer args for: ${message.reducerCall.reducerName}');
    }

    final context = EventContext(
      myConnectionId: _connectionId,
      event: event,
    );

    if (event is ReducerEvent) {
      reducerEmitter.emit(event.reducerName, context);
      SdkLogger.i('Emitted reducer completion event for: ${event.reducerName}');
    }

    final isOurTransaction = uuidRequestId != null;
    final isCommitted = message.status is Committed;
    final hasOptimistic = _optimisticState.hasOptimisticChange(effectiveRequestId);

    SdkLogger.d('TXN: numericRequestId=$numericRequestId, uuidRequestId=$uuidRequestId');
    SdkLogger.d('TXN: isOurTransaction=$isOurTransaction, isCommitted=$isCommitted, hasOptimistic=$hasOptimistic');

    if (isOurTransaction && isCommitted && hasOptimistic) {
      SdkLogger.i('Our transaction confirmed - keeping optimistic state');
      _optimisticState.confirmOptimisticChange(effectiveRequestId);
      _persistTableSnapshots();
      return;
    }

    final touchedKeysByTable = <String, Set<dynamic>>{};
    for (final tableUpdate in message.tableUpdates) {
      final table = cache.linkTableId(tableUpdate.tableId, tableUpdate.tableName);
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
      _optimisticState.confirmOrRollbackWithTouchedKeys(effectiveRequestId, touchedKeysByTable);
    } else {
      _optimisticState.rollbackOptimisticChanges(effectiveRequestId);
    }

    _persistTableSnapshots();
  }

  void _handleTransactionUpdateLight(TransactionUpdateLightMessage message) {
    final isEventOnly = message.tableUpdates.every((tu) => cache.isEventTable(tu.tableName));

    if (isEventOnly) {
      reducers.completeRequest(message.requestId, TransactionResult.fromTransactionUpdateLight(message));

      final context = EventContext(
        myConnectionId: _connectionId,
        event: UnknownTransactionEvent(),
      );
      for (final tableUpdate in message.tableUpdates) {
        final table = cache.linkTableId(tableUpdate.tableId, tableUpdate.tableName);
        if (table == null) continue;
        for (final update in tableUpdate.updates) {
          table.applyTransactionUpdate(
            update.update.deletes,
            update.update.inserts,
            context,
          );
        }
      }
      return;
    }

    SdkLogger.i('TXN_LIGHT: requestId=${message.requestId}, tables=${message.tableUpdates.length}');

    final numericRequestId = message.requestId;
    final uuidRequestId = reducers.getUuidForRequest(numericRequestId);
    final effectiveRequestId = uuidRequestId ?? numericRequestId.toString();

    final isOurTransaction = uuidRequestId != null;
    final hasOptimistic = _optimisticState.hasOptimisticChange(effectiveRequestId);

    SdkLogger.d('TXN-LIGHT: isOurTransaction=$isOurTransaction, hasOptimistic=$hasOptimistic');

    final result = TransactionResult.fromTransactionUpdateLight(message);
    reducers.completeRequest(numericRequestId, result);

    if (isOurTransaction && hasOptimistic) {
      SdkLogger.i('Our light transaction confirmed - keeping optimistic state');
      _optimisticState.confirmOptimisticChange(effectiveRequestId);
      _persistTableSnapshots();
      return;
    }

    final event = UnknownTransactionEvent();
    final context = EventContext(
      myConnectionId: _connectionId,
      event: event,
    );

    final touchedKeysByTable = <String, Set<dynamic>>{};
    for (final tableUpdate in message.tableUpdates) {
      final table = cache.linkTableId(tableUpdate.tableId, tableUpdate.tableName);
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

    _optimisticState.confirmOrRollbackWithTouchedKeys(effectiveRequestId, touchedKeysByTable);
    _persistTableSnapshots();
  }

  /// Subscribes to tables using SQL queries
  ///
  /// Returns a Future that completes when the initial subscription data
  /// has been received and cached. This ensures data is available
  /// immediately after the Future completes.
  ///
  /// Example:
  /// ```dart
  /// await subscriptionManager.subscribe(['SELECT * FROM note', 'SELECT * FROM user']);
  /// // Data is now available in cache
  /// ```
  Future<void> subscribe(List<String> queries) async {
    _activeSubscriptionQueries.addAll(queries);
    _pendingTableNames = _extractTableNames(queries);

    final message = SubscribeMessage(queries);
    _connection.send(message.encode());

    await onInitialSubscription.first;
  }

  /// Extract table names from SQL subscription queries
  ///
  /// Parses simple SELECT statements to find table names.
  /// Supports: "SELECT * FROM tablename" and "SELECT * FROM tablename WHERE ..."
  List<String> _extractTableNames(List<String> queries) {
    final tableNames = <String>[];
    // Regex to find "FROM tablename" (case insensitive)
    final regex = RegExp(r'FROM\s+([a-zA-Z_][a-zA-Z0-9_]*)', caseSensitive: false);

    for (final query in queries) {
      final match = regex.firstMatch(query);
      if (match != null) {
        tableNames.add(match.group(1)!);
      }
    }
    return tableNames;
  }

  /// Subscribes to a single SQL query
  ///
  /// Returns a [SubscribeApplied] message on success.
  ///
  /// Example:
  /// ```dart
  /// subscriptionManager.subscribeSingle('SELECT * FROM note WHERE id > 100', queryId: 1);
  ///
  /// // Listen for confirmation
  /// await subscriptionManager.onSubscribeApplied.first;
  /// ```
  void subscribeSingle(String query, {int requestId = 0, int queryId = 0}) {
    final message =
        SubscribeSingleMessage(query, requestId: requestId, queryId: queryId);
    _connection.send(message.encode());
  }

  /// Subscribes to multiple SQL queries at once
  ///
  /// Returns a [SubscribeMultiApplied] message on success.
  ///
  /// Example:
  /// ```dart
  /// subscriptionManager.subscribeMulti([
  ///   'SELECT * FROM note',
  ///   'SELECT * FROM user WHERE active = true'
  /// ], queryId: 1);
  ///
  /// // Listen for confirmation
  /// await subscriptionManager.onSubscribeMultiApplied.first;
  /// ```
  void subscribeMulti(List<String> queries,
      {int requestId = 0, int queryId = 0}) {
    final message =
        SubscribeMultiMessage(queries, requestId: requestId, queryId: queryId);
    _connection.send(message.encode());
  }

  /// Executes a one-off SQL query without creating a subscription
  ///
  /// Use this for queries that don't need real-time updates.
  /// Results are delivered via [onOneOffQueryResponse] stream.
  ///
  /// Example:
  /// ```dart
  /// final messageId = Uint8List.fromList([1, 2, 3, 4]);
  /// subscriptionManager.oneOffQuery(messageId, 'SELECT COUNT(*) FROM note');
  ///
  /// final response = await subscriptionManager.onOneOffQueryResponse.first;
  /// print('Result: ${response.tables}');
  /// ```
  void oneOffQuery(Uint8List messageId, String query) {
    final message = OneOffQueryMessage(
      messageId: messageId,
      queryString: query,
    );
    _connection.send(message.encode());
  }

  /// Unsubscribes from a query by its queryId
  ///
  /// Stops receiving real-time updates for the specified query.
  ///
  /// Example:
  /// ```dart
  /// subscriptionManager.unsubscribe(1);
  ///
  /// // Listen for confirmation
  /// await subscriptionManager.onUnsubscribeApplied.first;
  /// ```
  void unsubscribe(int queryId, {int requestId = 0}) {
    final message = UnsubscribeMessage(
      queryId: queryId,
      requestId: requestId,
    );
    _connection.send(message.encode());
  }

  /// Unsubscribes from multiple queries
  ///
  /// Returns a [UnsubscribeMultiApplied] message on success.
  ///
  /// Example:
  /// ```dart
  /// subscriptionManager.unsubscribeMulti(1);
  ///
  /// // Listen for confirmation
  /// await subscriptionManager.onUnsubscribeMultiApplied.first;
  /// ```
  void unsubscribeMulti(int queryId, {int requestId = 0}) {
    final message = UnsubscribeMultiMessage(
      queryId: queryId,
      requestId: requestId,
    );
    _connection.send(message.encode());
  }

  /// Calls a read-only procedure on the server
  ///
  /// Procedures are read-only operations that don't modify database state.
  /// For state-modifying operations, use [reducers] instead.
  ///
  /// Returns a [ProcedureResultMessage] with the result.
  ///
  /// Example:
  /// ```dart
  /// final encoder = BsatnEncoder();
  /// encoder.writeU32(10);
  /// encoder.writeU32(20);
  ///
  /// subscriptionManager.callProcedure('add_numbers', encoder.toBytes());
  ///
  /// final result = await subscriptionManager.onProcedureResult.first;
  /// if (result.status.type == ProcedureStatusType.returned) {
  ///   print('Success!');
  /// }
  /// ```
  void callProcedure(String procedureName, Uint8List args,
      {int requestId = 0}) {
    final message = CallProcedureMessage(
      procedureName: procedureName,
      args: args,
      requestId: requestId,
    );
    _connection.send(message.encode());
  }

  Future<void> _ensureOfflineStorageInitialized() async {
    if (_offlineStorageInitialized) return;
    final storage = _offlineStorage;
    if (storage == null) return;
    await storage.initialize();
    _offlineStorageInitialized = true;
  }

  Future<void> loadFromOfflineCache() async {
    final storage = _offlineStorage;
    if (storage == null) return;

    try {
      await _ensureOfflineStorageInitialized();

      for (final tableName in cache.registeredTableNames) {
        cache.activateEmptyTable(tableName);
        if (cache.isEventTable(tableName)) continue;
        final rows = await storage.loadTableSnapshot(tableName);
        if (rows != null && rows.isNotEmpty) {
          final table = cache.getTableByName(tableName);
          if (table != null && table.decoder.supportsJsonSerialization) {
            table.loadFromSerializable(rows);
            SdkLogger.i('Loaded ${rows.length} rows from offline cache for "$tableName"');
          }
        }
      }

      final pending = await storage.getPendingMutations();
      for (final mutation in pending) {
        _optimisticState.applyOptimisticChanges(mutation.requestId, mutation.optimisticChanges);
      }

      await _updatePendingCount();
    } catch (e) {
      SdkLogger.e('Error loading from offline cache: $e');
    }
  }


  Future<void> _updatePendingCount() async {
    final storage = _offlineStorage;
    if (storage == null) return;
    final pending = await storage.getPendingMutations();
    _cachedPendingCount = pending.length;
    _updateSyncState(_currentSyncState.copyWith(
      pendingCount: _cachedPendingCount,
    ));
  }

  void _decrementPendingCount() {
    _cachedPendingCount = (_cachedPendingCount - 1).clamp(0, _cachedPendingCount);
    _updateSyncState(_currentSyncState.copyWith(
      pendingCount: _cachedPendingCount,
    ));
  }

  Future<void> syncPendingMutations() async {
    final storage = _offlineStorage;
    if (storage == null) return;
    if (_disposed) return;
    if (_isSyncing) {
      SdkLogger.d('Sync already in progress, skipping');
      return;
    }
    if (_connection.status != ConnectionStatus.connected) {
      SdkLogger.d('syncPendingMutations: not connected, skipping');
      return;
    }

    SdkLogger.d('syncPendingMutations: starting');
    _isSyncing = true;

    try {
      await _ensureOfflineStorageInitialized();

      final pending = await storage.getPendingMutations();
      if (pending.isEmpty) {
        SdkLogger.d('syncPendingMutations: no pending mutations, setting idle');
        _cachedPendingCount = 0;
        _updateSyncState(_currentSyncState.copyWith(
          status: SyncStatus.idle,
          pendingCount: 0,
        ));
        return;
      }

      _cachedPendingCount = pending.length;
      _updateSyncState(_currentSyncState.copyWith(
        status: SyncStatus.syncing,
        pendingCount: _cachedPendingCount,
      ));

      SdkLogger.i('Syncing ${pending.length} pending mutations');

      for (final mutation in pending) {
        if (_disposed) return;
        if (_connection.status != ConnectionStatus.connected) {
          SdkLogger.i('Connection lost during sync. Pausing queue.');
          break;
        }

        try {
          SdkLogger.d('SYNC_SEND: ${mutation.reducerName}, uuidRequestId=${mutation.requestId}, argsLen=${mutation.encodedArgs.length}');
          final result = await reducers.callWithBytes(
            mutation.reducerName,
            mutation.encodedArgs,
            requestId: mutation.requestId,
          );

          if (_disposed) return;

          if (result.isSuccess) {
            await storage.dequeueMutation(mutation.requestId);
            _decrementPendingCount();
            SdkLogger.i('Synced mutation: ${mutation.reducerName}');
            if (!_disposed) {
              _mutationSyncResultController.add(MutationSyncResult(
                requestId: mutation.requestId,
                reducerName: mutation.reducerName,
                success: true,
              ));
            }
          } else {
            final errorMsg = result.errorMessage ?? 'Unknown error';
            _optimisticState.rollbackOptimisticChanges(mutation.requestId);
            await storage.dequeueMutation(mutation.requestId);
            _decrementPendingCount();
            SdkLogger.e('Server rejected mutation: ${mutation.reducerName} - $errorMsg');
            if (!_disposed) {
              _mutationSyncResultController.add(MutationSyncResult(
                requestId: mutation.requestId,
                reducerName: mutation.reducerName,
                success: false,
                error: errorMsg,
              ));
            }
          }
        } on ReducerException catch (e) {
          _optimisticState.rollbackOptimisticChanges(mutation.requestId);
          await storage.dequeueMutation(mutation.requestId);
          _decrementPendingCount();
          SdkLogger.e('Server rejected mutation: ${mutation.reducerName} - ${e.message}');
          if (!_disposed) {
            _mutationSyncResultController.add(MutationSyncResult(
              requestId: mutation.requestId,
              reducerName: mutation.reducerName,
              success: false,
              error: e.message,
            ));
          }
        } on TimeoutException catch (e) {
          SdkLogger.w('Timeout syncing ${mutation.reducerName}: $e. Keeping in queue for retry.');
          break;
        } catch (e) {
          SdkLogger.w('Network error syncing ${mutation.reducerName}: $e. Pausing queue.');
          break;
        }
      }
    } finally {
      _isSyncing = false;
      SdkLogger.d('syncPendingMutations: finished (isSyncing=false)');
    }

    if (_disposed) {
      SdkLogger.d('syncPendingMutations: disposed, skipping final state update');
      return;
    }

    final remaining = await storage.getPendingMutations();
    _cachedPendingCount = remaining.length;
    SdkLogger.d('syncPendingMutations: remaining=$_cachedPendingCount, setting idle');
    _updateSyncState(_currentSyncState.copyWith(
      status: SyncStatus.idle,
      pendingCount: _cachedPendingCount,
      lastSyncTime: DateTime.now(),
    ));

    if (remaining.isNotEmpty && _connection.status == ConnectionStatus.connected) {
      _scheduleRetry();
    } else if (remaining.isEmpty) {
      _cancelRetry();
      _retryAttempt = 0;
    }
  }

  void _scheduleRetry() {
    if (_disposed) return;
    _retryTimer?.cancel();

    final delay = Duration(
      milliseconds: (_initialRetryDelay.inMilliseconds * (1 << _retryAttempt))
          .clamp(0, _maxRetryDelay.inMilliseconds),
    );
    _retryAttempt++;

    SdkLogger.i('Scheduling sync retry in ${delay.inSeconds}s (attempt $_retryAttempt)');

    _retryTimer = Timer(delay, () {
      if (_disposed) return;
      if (_connection.status == ConnectionStatus.connected) {
        SdkLogger.i('Auto-retry: syncing pending mutations');
        syncPendingMutations();
      }
    });
  }

  void _cancelRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  Future<List<PendingMutation>> getPendingMutations() async {
    final storage = _offlineStorage;
    if (storage == null) return [];
    return storage.getPendingMutations();
  }

  Future<void> clearPendingMutation(String requestId) async {
    final storage = _offlineStorage;
    if (storage == null) return;
    await storage.dequeueMutation(requestId);
    await _updatePendingCount();
  }

  Future<void> clearAllPendingMutations() async {
    final storage = _offlineStorage;
    if (storage == null) return;
    await storage.clearMutationQueue();
    await _updatePendingCount();
  }

  Future<void> dispose() async {
    _disposed = true;
    _cancelRetry();
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
    _syncStateController.close();
    _mutationSyncResultController.close();
    reducerEmitter.dispose();
    await _offlineStorage?.dispose();
  }
}
