import 'dart:async';
import 'dart:typed_data';

import 'package:spacetimedb_dart_sdk/src/connection/spacetimedb_connection.dart';
import 'package:spacetimedb_dart_sdk/src/connection/connection_state.dart';
import 'package:spacetimedb_dart_sdk/src/messages/client_messages.dart';
import 'package:spacetimedb_dart_sdk/src/reducers/transaction_result.dart';
import 'package:spacetimedb_dart_sdk/src/offline/offline_storage.dart';
import 'package:spacetimedb_dart_sdk/src/offline/pending_mutation.dart';
import 'package:spacetimedb_dart_sdk/src/utils/sdk_logger.dart';

import 'package:spacetimedb_dart_sdk/src/reducers/mutation_handler.dart';
export 'package:spacetimedb_dart_sdk/src/offline/optimistic_change.dart';
import 'package:uuid/uuid.dart';

class _PendingRequest {
  final Completer<TransactionResult> completer;
  final Timer timeout;
  final String reducerName;
  final String? uuidRequestId;
  final bool hasOptimisticChanges;

  _PendingRequest({
    required this.completer,
    required this.timeout,
    required this.reducerName,
    this.uuidRequestId,
    this.hasOptimisticChanges = false,
  });

  void dispose() {
    timeout.cancel();
  }
}

class ReducerCaller {
  final SpacetimeDbConnection _connection;
  final OfflineStorage? _offlineStorage;
  final MutationHandler? _mutationHandler;
  int _nextRequestId = 1;
  final _uuid = const Uuid();

  final Map<int, _PendingRequest> _pendingRequests = {};
  final Map<String, int> _requestIdByUuid = {};

  Duration defaultTimeout = const Duration(seconds: 10);

  ReducerCaller(
    this._connection, {
    OfflineStorage? offlineStorage,
    MutationHandler? mutationHandler,
  }) : _offlineStorage = offlineStorage,
       _mutationHandler = mutationHandler;

  Future<TransactionResult> call(
    String reducerName,
    Uint8List args, {
    Duration? timeout,
    bool queueIfOffline = true,
    bool isEventTable = false,
    List<OptimisticChange>? optimisticChanges,
  }) async {
    if (isEventTable) {
      if (!_isOnline) {
        return TransactionResult.dropped(reducerName: reducerName);
      }
      return _sendDirectly(reducerName, args, timeout, optimisticChanges);
    }

    SdkLogger.d(
      '$reducerName: state=${_connection.state.displayName}, isOnline=$_isOnline, hasOfflineStorage=${_offlineStorage != null}',
    );

    if (_offlineStorage != null) {
      SdkLogger.d('OFFLINE-FIRST: Always queue first, then sync');
      return _queueAndMaybeSync(reducerName, args, optimisticChanges);
    }

    SdkLogger.d('NO OFFLINE STORAGE: Direct send (legacy path)');
    return _sendDirectly(reducerName, args, timeout, optimisticChanges);
  }

  Future<TransactionResult> callWithBytes(
    String reducerName,
    Uint8List args, {
    Duration? timeout,
    String? requestId,
  }) async {
    final numericRequestId = _nextRequestId++;
    SdkLogger.d(
      'callWithBytes: $reducerName, numericId=$numericRequestId, uuidId=$requestId',
    );
    if (requestId != null) {
      _requestIdByUuid[requestId] = numericRequestId;
    }

    final completer = Completer<TransactionResult>();
    final effectiveTimeout = timeout ?? defaultTimeout;

    final timer = Timer(effectiveTimeout, () {
      _timeoutRequest(numericRequestId, reducerName, effectiveTimeout);
    });

    _pendingRequests[numericRequestId] = _PendingRequest(
      completer: completer,
      timeout: timer,
      reducerName: reducerName,
      uuidRequestId: requestId,
    );

    final message = CallReducerMessage(
      reducerName: reducerName,
      args: args,
      requestId: numericRequestId,
    );
    _connection.send(message.encode());

    return completer.future;
  }

  String? getUuidForRequest(int requestId) {
    return _pendingRequests[requestId]?.uuidRequestId;
  }

  void completeRequest(int requestId, TransactionResult result) {
    final pending = _pendingRequests.remove(requestId);
    if (pending == null) {
      return;
    }

    pending.dispose();
    if (pending.uuidRequestId != null) {
      _requestIdByUuid.remove(pending.uuidRequestId);
    }

    if (result.isSuccess) {
      pending.completer.complete(result);
    } else {
      pending.completer.completeError(
        ReducerException(
          reducerName: pending.reducerName,
          message: result.errorMessage ?? 'Unknown error',
          result: result,
        ),
      );
    }
  }

  void failAllPendingRequests(String reason) {
    final entries = _pendingRequests.entries.toList();
    for (var entry in entries) {
      final requestId = entry.key;
      final pending = entry.value;
      pending.dispose();
      if (pending.hasOptimisticChanges) {
        _mutationHandler?.onRollbackOptimistic(requestId.toString());
      }
      pending.completer.completeError(
        ConnectionException('Connection lost during reducer call: $reason'),
      );
    }
    _pendingRequests.clear();
    _requestIdByUuid.clear();
  }

  void dispose() {
    for (var pending in _pendingRequests.values) {
      pending.dispose();
    }
    _pendingRequests.clear();
    _requestIdByUuid.clear();
  }

  bool get _isOnline => _connection.state is Connected;

  Future<TransactionResult> _queueAndMaybeSync(
    String reducerName,
    Uint8List args,
    List<OptimisticChange>? optimisticChanges,
  ) async {
    final requestId = _uuid.v4();

    if (optimisticChanges != null && optimisticChanges.isNotEmpty) {
      SdkLogger.d('Applying optimistic changes immediately...');
      _mutationHandler?.onOptimisticChanges(requestId, optimisticChanges);
    }

    SdkLogger.d('Queuing $reducerName to disk (requestId=$requestId)');
    final mutation = PendingMutation(
      requestId: requestId,
      reducerName: reducerName,
      encodedArgs: args,
      createdAt: DateTime.now(),
      optimisticChanges: optimisticChanges,
    );

    await _offlineStorage!.enqueueMutation(mutation);
    _mutationHandler?.onMutationQueued(requestId, optimisticChanges);

    if (_isOnline) {
      SdkLogger.d('Online, triggering immediate sync...');
      _mutationHandler?.trySyncNow();
    } else {
      SdkLogger.d('Offline, mutation queued for later sync');
    }

    return TransactionResult.pending(
      reducerName: reducerName,
      requestId: requestId,
    );
  }

  Future<TransactionResult> _sendDirectly(
    String reducerName,
    Uint8List args,
    Duration? timeout,
    List<OptimisticChange>? optimisticChanges,
  ) async {
    final requestId = _nextRequestId++;
    final completer = Completer<TransactionResult>();
    final effectiveTimeout = timeout ?? defaultTimeout;

    final timer = Timer(effectiveTimeout, () {
      _timeoutRequest(requestId, reducerName, effectiveTimeout);
    });

    final hasOptimistic =
        optimisticChanges != null && optimisticChanges.isNotEmpty;

    _pendingRequests[requestId] = _PendingRequest(
      completer: completer,
      timeout: timer,
      reducerName: reducerName,
      hasOptimisticChanges: hasOptimistic,
    );

    if (hasOptimistic) {
      SdkLogger.d('Applying optimistic changes: ${optimisticChanges.length}');
      _mutationHandler?.onOptimisticChanges(
        requestId.toString(),
        optimisticChanges,
      );
    }

    final message = CallReducerMessage(
      reducerName: reducerName,
      args: args,
      requestId: requestId,
    );
    _connection.send(message.encode());

    return completer.future;
  }

  void _timeoutRequest(int requestId, String reducerName, Duration timeout) {
    final pending = _pendingRequests.remove(requestId);
    if (pending != null) {
      if (pending.uuidRequestId != null) {
        _requestIdByUuid.remove(pending.uuidRequestId);
      }
      if (pending.hasOptimisticChanges) {
        _mutationHandler?.onRollbackOptimistic(requestId.toString());
      }
      pending.completer.completeError(
        TimeoutException(
          'Reducer "$reducerName" timed out after ${timeout.inSeconds}s',
          timeout,
        ),
      );
    }
  }
}

class ReducerException implements Exception {
  final String reducerName;
  final String message;
  final TransactionResult result;

  ReducerException({
    required this.reducerName,
    required this.message,
    required this.result,
  });

  @override
  String toString() => 'ReducerException($reducerName): $message';
}

class ConnectionException implements Exception {
  final String message;

  ConnectionException(this.message);

  @override
  String toString() => 'ConnectionException: $message';
}
