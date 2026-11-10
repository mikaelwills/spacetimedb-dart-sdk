import 'dart:async';
import 'dart:typed_data';

import 'package:spacetimedb_sdk/src/codec/bsatn_decoder.dart';
import 'package:spacetimedb_sdk/src/connection/connection_state.dart';
import 'package:spacetimedb_sdk/src/connection/spacetimedb_connection.dart';
import 'package:spacetimedb_sdk/src/exceptions.dart';
import 'package:spacetimedb_sdk/src/messages/client_messages.dart';
import 'package:spacetimedb_sdk/src/messages/server_messages.dart';

typedef ProcedureReturnDecoder<T> = T Function(BsatnDecoder decoder);

class _PendingProcedure {
  final String procedureName;
  final void Function(ProcedureResultMessage result) onResult;
  final void Function(Object error) onError;
  final Timer? timer;

  _PendingProcedure({
    required this.procedureName,
    required this.onResult,
    required this.onError,
    this.timer,
  });
}

class ProcedureCaller {
  final SpacetimeDbConnection _connection;
  int _nextRequestId = 1;
  final Map<int, _PendingProcedure> _pending = {};

  ProcedureCaller(this._connection);

  Future<T> call<T>(
    String procedureName,
    Uint8List args,
    ProcedureReturnDecoder<T> decode, {
    Duration? timeout,
  }) {
    if (_connection.state is! Connected) {
      return Future.error(
        SpacetimeDbConnectionException(
          'Cannot call procedure "$procedureName": '
          'connection is ${_connection.state.displayName}',
          lastKnownState: _connection.state,
        ),
      );
    }

    final requestId = _allocateRequestId();
    final completer = Completer<T>();

    Timer? timer;
    if (timeout != null) {
      timer = Timer(timeout, () {
        if (_pending.remove(requestId) == null) return;
        completer.completeError(
          SpacetimeDbTimeoutException(
            'Procedure "$procedureName" timed out after ${timeout.inSeconds}s',
            elapsed: timeout,
          ),
        );
      });
    }

    _pending[requestId] = _PendingProcedure(
      procedureName: procedureName,
      timer: timer,
      onError: completer.completeError,
      onResult: (result) =>
          _completeFromResult(completer, procedureName, result.status, decode),
    );

    _connection.send(
      CallProcedureMessage(
        procedureName: procedureName,
        args: args,
        requestId: requestId,
      ).encode(),
    );

    return completer.future;
  }

  bool handleResult(ProcedureResultMessage result) {
    final pending = _pending.remove(result.requestId);
    if (pending == null) return false;
    pending.timer?.cancel();
    pending.onResult(result);
    return true;
  }

  void failAllPending(String reason) {
    final entries = _pending.values.toList();
    _pending.clear();
    for (final pending in entries) {
      pending.timer?.cancel();
      pending.onError(
        SpacetimeDbConnectionException(
          'Connection lost during procedure "${pending.procedureName}": $reason',
        ),
      );
    }
  }

  void dispose() {
    for (final pending in _pending.values) {
      pending.timer?.cancel();
    }
    _pending.clear();
  }

  void _completeFromResult<T>(
    Completer<T> completer,
    String procedureName,
    ProcedureStatus status,
    ProcedureReturnDecoder<T> decode,
  ) {
    if (status.type == ProcedureStatusType.internalError) {
      completer.completeError(
        SpacetimeDbProcedureException(
          procedureName: procedureName,
          message: status.errorMessage ?? 'Unknown error',
        ),
      );
      return;
    }
    try {
      final bytes = status.returnedData ?? Uint8List(0);
      completer.complete(decode(BsatnDecoder(bytes)));
    } catch (e, st) {
      completer.completeError(
        SpacetimeDbProcedureException(
          procedureName: procedureName,
          message: 'Failed to decode return value: $e',
        ),
        st,
      );
    }
  }

  int _allocateRequestId() {
    var id = _nextRequestId;
    while (id == 0 || _pending.containsKey(id)) {
      id = (id + 1) & 0xFFFFFFFF;
    }
    _nextRequestId = (id + 1) & 0xFFFFFFFF;
    return id;
  }
}
