import 'dart:typed_data';

import 'package:fixnum/fixnum.dart';

import '../codec/bsatn_decoder.dart';
import 'shared_types.dart';
import 'update_status.dart';

/// Server message type tags (Server -> Client).
/// Based on v2 websocket.rs ServerMessage enum order (v2.rs:175-196).
enum ServerMessageType {
  initialConnection(0),
  subscribeApplied(1),
  unsubscribeApplied(2),
  subscriptionError(3),
  transactionUpdate(4),
  oneOffQueryResult(5),
  reducerResult(6),
  procedureResult(7);

  final int tag;
  const ServerMessageType(this.tag);

  static ServerMessageType fromTag(int tag) {
    return ServerMessageType.values.firstWhere(
      (type) => type.tag == tag,
      orElse: () => throw ArgumentError('Unknown server message type: $tag'),
    );
  }
}

sealed class ServerMessage {
  ServerMessageType get messageType;
}

/// v2 `TransactionUpdate` — non-caller broadcast.
/// Wire: `v2.rs:302-306` — `{ query_sets: Box<[QuerySetUpdate]> }`.
class TransactionUpdateMessage implements ServerMessage {
  final List<QuerySetUpdate> querySets;

  TransactionUpdateMessage({required this.querySets});

  @override
  ServerMessageType get messageType => ServerMessageType.transactionUpdate;

  static TransactionUpdateMessage decode(BsatnDecoder decoder) {
    final querySets = decoder.readList(() => QuerySetUpdate.decode(decoder));
    return TransactionUpdateMessage(querySets: querySets);
  }
}

/// v2 `InitialConnection` — handshake payload.
/// Wire: `v2.rs:198-204` — `{ identity, connection_id, token }`.
class InitialConnectionMessage implements ServerMessage {
  final Uint8List identity;
  final Uint8List connectionId;
  final String token;

  InitialConnectionMessage({
    required this.identity,
    required this.connectionId,
    required this.token,
  });

  @override
  ServerMessageType get messageType => ServerMessageType.initialConnection;

  static InitialConnectionMessage decode(BsatnDecoder decoder) {
    final identity = decoder.readBytes(32);
    final connectionId = decoder.readBytes(16);
    final token = decoder.readString();

    return InitialConnectionMessage(
      identity: identity,
      connectionId: connectionId,
      token: token,
    );
  }
}

/// v2 `OneOffQueryResult`.
/// Wire: `v2.rs:358-367` — `{ request_id: u32, result: Result<QueryRows, Box<str>> }`.
/// `Result<T,E>` sum: tag 0 = Ok, tag 1 = Err (verified `sats/ser/impls.rs:120-123`).
class OneOffQueryResult implements ServerMessage {
  final int requestId;
  final QueryRows? rows;
  final String? error;

  OneOffQueryResult({required this.requestId, this.rows, this.error});

  @override
  ServerMessageType get messageType => ServerMessageType.oneOffQueryResult;

  static OneOffQueryResult decode(BsatnDecoder decoder) {
    final requestId = decoder.readU32();
    final tag = decoder.readU8();
    if (tag == 0) {
      return OneOffQueryResult(
        requestId: requestId,
        rows: QueryRows.decode(decoder),
      );
    } else if (tag == 1) {
      return OneOffQueryResult(
        requestId: requestId,
        error: decoder.readString(),
      );
    }
    throw ArgumentError('Unknown OneOffQueryResult Result tag: $tag');
  }
}

/// v2 `SubscribeApplied` — initial-data delivery for a query set.
/// Wire: `v2.rs:206-221` — `{ request_id: u32, query_set_id: u32, rows: QueryRows }`.
class SubscribeApplied implements ServerMessage {
  final int requestId;
  final int querySetId;
  final QueryRows rows;

  SubscribeApplied({
    required this.requestId,
    required this.querySetId,
    required this.rows,
  });

  @override
  ServerMessageType get messageType => ServerMessageType.subscribeApplied;

  static SubscribeApplied decode(BsatnDecoder decoder) {
    final requestId = decoder.readU32();
    final querySetId = decoder.readU32();
    final rows = QueryRows.decode(decoder);

    return SubscribeApplied(
      requestId: requestId,
      querySetId: querySetId,
      rows: rows,
    );
  }
}

/// v2 `UnsubscribeApplied`.
/// Wire: `v2.rs:245-254` — `{ request_id: u32, query_set_id: u32, rows: Option<QueryRows> }`.
/// `rows` populated only when the matching `Unsubscribe` set `SendDroppedRows`.
class UnsubscribeApplied implements ServerMessage {
  final int requestId;
  final int querySetId;
  final QueryRows? rows;

  UnsubscribeApplied({
    required this.requestId,
    required this.querySetId,
    this.rows,
  });

  @override
  ServerMessageType get messageType => ServerMessageType.unsubscribeApplied;

  static UnsubscribeApplied decode(BsatnDecoder decoder) {
    final requestId = decoder.readU32();
    final querySetId = decoder.readU32();
    final rows = decoder.readOption(() => QueryRows.decode(decoder));

    return UnsubscribeApplied(
      requestId: requestId,
      querySetId: querySetId,
      rows: rows,
    );
  }
}

/// v2 `SubscriptionError`.
/// Wire: `v2.rs:271-291` — `{ request_id: Option<u32>, query_set_id: QuerySetId, error: Box<str> }`.
class SubscriptionErrorMessage implements ServerMessage {
  final int? requestId;
  final int querySetId;
  final String error;

  SubscriptionErrorMessage({
    required this.requestId,
    required this.querySetId,
    required this.error,
  });

  @override
  ServerMessageType get messageType => ServerMessageType.subscriptionError;

  static SubscriptionErrorMessage decode(BsatnDecoder decoder) {
    final requestId = decoder.readOption(() => decoder.readU32());
    final querySetId = decoder.readU32();
    final error = decoder.readString();

    return SubscriptionErrorMessage(
      requestId: requestId,
      querySetId: querySetId,
      error: error,
    );
  }
}

/// v2 `ReducerResult` — caller's `CallReducer` outcome.
/// Wire: `v2.rs:371-381` — `{ request_id: u32, timestamp: Timestamp(i64 µs), result: ReducerOutcome }`.
/// `Timestamp` on v2 wire is microseconds (canonical `sats/src/timestamp.rs:11-14`,
/// stale `v2.rs:378` doc comment notwithstanding).
class ReducerResultMessage implements ServerMessage {
  final int requestId;
  final Int64 timestamp;
  final UpdateStatus status;
  final Uint8List? retValue;
  final List<QuerySetUpdate> querySets;

  ReducerResultMessage({
    required this.requestId,
    required this.timestamp,
    required this.status,
    required this.querySets,
    this.retValue,
  });

  @override
  ServerMessageType get messageType => ServerMessageType.reducerResult;

  static ReducerResultMessage decode(BsatnDecoder decoder) {
    final requestId = decoder.readU32();
    final timestamp = decoder.readU64();
    final outcomeTag = decoder.readU8();

    UpdateStatus status;
    Uint8List? retValue;
    List<QuerySetUpdate> querySets;

    if (outcomeTag == 0) {
      // Ok(ReducerOk { ret_value: Bytes, transaction_update: TransactionUpdate })
      final retLen = decoder.readU32();
      final retBytes = decoder.readBytes(retLen);
      retValue = retLen == 0 ? null : retBytes;
      querySets = decoder.readList(() => QuerySetUpdate.decode(decoder));
      status = Committed();
    } else if (outcomeTag == 1) {
      // OkEmpty — unit; zero ret, zero query_sets.
      retValue = null;
      querySets = const [];
      status = Committed();
    } else if (outcomeTag == 2) {
      // Err(Bytes)
      final errLen = decoder.readU32();
      final errBytes = decoder.readBytes(errLen);
      retValue = null;
      querySets = const [];
      status = Failed(errBytes);
    } else if (outcomeTag == 3) {
      // InternalError(Box<str>)
      final message = decoder.readString();
      retValue = null;
      querySets = const [];
      status = InternalError(message);
    } else {
      throw ArgumentError('Unknown ReducerOutcome tag: $outcomeTag');
    }

    return ReducerResultMessage(
      requestId: requestId,
      timestamp: timestamp,
      status: status,
      retValue: retValue,
      querySets: querySets,
    );
  }
}

/// v2 `ProcedureResult` — procedure invocation outcome.
class ProcedureResultMessage implements ServerMessage {
  final ProcedureStatus status;
  final Int64 timestamp;
  final Int64 totalHostExecutionDurationMicros;
  final int requestId;

  ProcedureResultMessage({
    required this.status,
    required this.timestamp,
    required this.totalHostExecutionDurationMicros,
    required this.requestId,
  });

  @override
  ServerMessageType get messageType => ServerMessageType.procedureResult;

  static ProcedureResultMessage decode(BsatnDecoder decoder) {
    final status = ProcedureStatus.decode(decoder);
    final timestamp = decoder.readU64();
    final duration = decoder.readU64();
    final requestId = decoder.readU32();

    return ProcedureResultMessage(
      status: status,
      timestamp: timestamp,
      totalHostExecutionDurationMicros: duration,
      requestId: requestId,
    );
  }
}

/// v2 `ProcedureStatus` two-variant sum.
/// Wire: tag 0 `Returned(Bytes)` — u32 length + bytes; tag 1 `InternalError(Box<str>)`.
/// Front-loaded to slice 2 (was a v1-shape collision with unit `OutOfEnergy` at tag 1).
class ProcedureStatus {
  final ProcedureStatusType type;
  final Uint8List? returnedData;
  final String? errorMessage;

  ProcedureStatus({required this.type, this.returnedData, this.errorMessage});

  static ProcedureStatus decode(BsatnDecoder decoder) {
    final tag = decoder.readU8();

    if (tag == 0) {
      final dataLength = decoder.readU32();
      final data = decoder.readBytes(dataLength);
      return ProcedureStatus(
        type: ProcedureStatusType.returned,
        returnedData: data,
      );
    } else if (tag == 1) {
      final error = decoder.readString();
      return ProcedureStatus(
        type: ProcedureStatusType.internalError,
        errorMessage: error,
      );
    }

    throw ArgumentError('Unknown ProcedureStatus tag: $tag');
  }
}

enum ProcedureStatusType { returned, internalError }
