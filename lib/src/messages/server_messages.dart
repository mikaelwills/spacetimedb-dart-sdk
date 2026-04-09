import 'dart:typed_data';

import 'package:fixnum/fixnum.dart';

import '../codec/bsatn_decoder.dart';
import 'shared_types.dart';
import 'reducer_info.dart';
import 'update_status.dart';

/// Server message type tags (Server -> Client)
/// Based on websocket.rs ServerMessage enum order
enum ServerMessageType {
  initialSubscription(0),
  transactionUpdate(1),
  transactionUpdateLight(2),
  identityToken(3),
  oneOffQueryResponse(4),
  subscribeApplied(5),
  unsubscribeApplied(6),
  subscriptionError(7),
  subscribeMultiApplied(8),
  unsubscribeMultiApplied(9),
  procedureResult(10);

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

/// Initial subscription response with all matching rows
class InitialSubscriptionMessage implements ServerMessage {
  final List<TableUpdate> tableUpdates;
  final int requestId;
  final Int64 totalHostExecutionDurationMicros;

  InitialSubscriptionMessage({
    required this.tableUpdates,
    required this.requestId,
    required this.totalHostExecutionDurationMicros,
  });

  @override
  ServerMessageType get messageType => ServerMessageType.initialSubscription;

  static InitialSubscriptionMessage decode(BsatnDecoder decoder) {
    final tableUpdates = decoder.readList(() => TableUpdate.decode(decoder));
    final requestId = decoder.readU32();
    final duration = decoder.readU64();

    return InitialSubscriptionMessage(
      tableUpdates: tableUpdates,
      requestId: requestId,
      totalHostExecutionDurationMicros: duration,
    );
  }
}

class TransactionUpdateMessage implements ServerMessage {
  final int transactionOffset;
  final Int64 timestamp;
  final List<TableUpdate> tableUpdates;

  // Transaction metadata fields (from Rust TransactionUpdate struct)
  final UpdateStatus status;
  final Uint8List callerIdentity; // Identity: 32 bytes, NOT Option
  final Uint8List
  callerConnectionId; // ConnectionId: u128 (16 bytes), NOT Option
  final ReducerInfo reducerCall; // ReducerCallInfo struct
  final int
  energyQuantaUsed; // EnergyQuanta: u128 - stored as int (will lose precision for huge values)
  final Int64 totalHostExecutionDuration; // TimeDuration: i64 microseconds

  TransactionUpdateMessage({
    required this.transactionOffset,
    required this.timestamp,
    required this.tableUpdates,
    required this.status,
    required this.callerIdentity,
    required this.callerConnectionId,
    required this.reducerCall,
    required this.energyQuantaUsed,
    required this.totalHostExecutionDuration,
  });

  @override
  ServerMessageType get messageType => ServerMessageType.transactionUpdate;

  static TransactionUpdateMessage decode(BsatnDecoder decoder) {
    // 1. Read UpdateStatus (algebraic enum with table updates inside Committed variant)
    final statusTag = decoder.readU8();

    UpdateStatus status;
    final List<TableUpdate> tableUpdates;

    if (statusTag == 0) {
      // Committed
      status = Committed();
      tableUpdates = decoder.readList(() => TableUpdate.decode(decoder));
    } else if (statusTag == 1) {
      // Failed
      final errorMessage = decoder.readString();
      status = Failed(errorMessage);
      tableUpdates = [];
    } else if (statusTag == 2) {
      // OutOfEnergy
      final budgetInfo = decoder.readString();
      status = OutOfEnergy(budgetInfo);
      tableUpdates = [];
    } else {
      throw ArgumentError('Unknown UpdateStatus tag: $statusTag');
    }

    // 2. Read timestamp (i64, serializes as u64)
    final timestamp = decoder.readU64();

    // 3. Read caller_identity (Identity: 32 bytes, NOT Option)
    final callerIdentity = decoder.readBytes(32);

    // 4. Read caller_connection_id (ConnectionId: u128 = 16 bytes, NOT Option)
    final callerConnectionId = decoder.readBytes(16);

    // 5. Read reducer_call (ReducerCallInfo struct)
    final reducerCall = ReducerInfo.decode(decoder);

    // 6. Read energy_quanta_used (EnergyQuanta: u128 = 16 bytes)
    final energyBytes = decoder.readBytes(16);
    // Convert to int (will lose precision for very large values, but acceptable)
    final energyQuantaUsed =
        energyBytes[0] |
        (energyBytes[1] << 8) |
        (energyBytes[2] << 16) |
        (energyBytes[3] << 24);

    // 7. Read total_host_execution_duration (TimeDuration: i64 microseconds)
    final totalHostExecutionDuration =
        decoder.readU64(); // i64 serializes as u64

    return TransactionUpdateMessage(
      transactionOffset: 0, // Not in wire protocol
      timestamp: timestamp,
      tableUpdates: tableUpdates,
      status: status,
      callerIdentity: callerIdentity,
      callerConnectionId: callerConnectionId,
      reducerCall: reducerCall,
      energyQuantaUsed: energyQuantaUsed,
      totalHostExecutionDuration: totalHostExecutionDuration,
    );
  }
}

/// Lightweight transaction update with minimal metadata
class TransactionUpdateLightMessage implements ServerMessage {
  final int requestId;
  final List<TableUpdate> tableUpdates;

  TransactionUpdateLightMessage({
    required this.requestId,
    required this.tableUpdates,
  });

  @override
  ServerMessageType get messageType => ServerMessageType.transactionUpdateLight;

  static TransactionUpdateLightMessage decode(BsatnDecoder decoder) {
    final requestId = decoder.readU32();
    final tableUpdates = decoder.readList(() => TableUpdate.decode(decoder));

    return TransactionUpdateLightMessage(
      requestId: requestId,
      tableUpdates: tableUpdates,
    );
  }
}

class IdentityTokenMessage implements ServerMessage {
  final Uint8List identity;
  final String token;
  final Uint8List connectionId;

  IdentityTokenMessage({
    required this.identity,
    required this.token,
    required this.connectionId,
  });

  @override
  ServerMessageType get messageType => ServerMessageType.identityToken;

  static IdentityTokenMessage decode(BsatnDecoder decoder) {
    final identity = decoder.readBytes(32);
    final token = decoder.readString();
    final connectionId = decoder.readBytes(16);

    return IdentityTokenMessage(
      identity: identity,
      token: token,
      connectionId: connectionId,
    );
  }
}

/// One-off query response from server
class OneOffQueryResponse implements ServerMessage {
  final Uint8List messageId;
  final int requestId;
  final String? error;
  final List<OneOffTable> tables;
  final Int64 totalHostExecutionDurationMicros;

  OneOffQueryResponse({
    required this.messageId,
    required this.requestId,
    this.error,
    required this.tables,
    required this.totalHostExecutionDurationMicros,
  });

  @override
  ServerMessageType get messageType => ServerMessageType.oneOffQueryResponse;

  static OneOffQueryResponse decode(BsatnDecoder decoder) {
    final messageIdLength = decoder.readU32();
    final messageId = decoder.readBytes(messageIdLength);

    // error is Option<String>
    // DISCOVERED: SpacetimeDB uses INVERTED Option encoding: 0x00 = Some, 0x01 = None
    // This is opposite of Rust's standard Option discriminant
    final errorTag = decoder.readU8();
    final error = (errorTag == 0) ? decoder.readString() : null;

    // tables is Vec<OneOffTable>
    final tables = decoder.readList(() => OneOffTable.decode(decoder));

    final duration = decoder.readU64();

    return OneOffQueryResponse(
      messageId: messageId,
      requestId: 0, // Not in wire format, using placeholder
      error: error,
      tables: tables,
      totalHostExecutionDurationMicros: duration,
    );
  }
}

class OneOffTable {
  final String tableName;
  final BsatnRowList rows;

  OneOffTable({required this.tableName, required this.rows});

  static OneOffTable decode(BsatnDecoder decoder) {
    final tableName = decoder.readString();
    final rows = BsatnRowList.decode(decoder);
    return OneOffTable(tableName: tableName, rows: rows);
  }
}

/// Response to Subscribe containing initial matching rows
class SubscribeApplied implements ServerMessage {
  final int requestId;
  final Int64 totalHostExecutionDurationMicros;
  final int queryId;
  final SubscribeRows rows;

  SubscribeApplied({
    required this.requestId,
    required this.totalHostExecutionDurationMicros,
    required this.queryId,
    required this.rows,
  });

  @override
  ServerMessageType get messageType => ServerMessageType.subscribeApplied;

  static SubscribeApplied decode(BsatnDecoder decoder) {
    final requestId = decoder.readU32();
    final duration = decoder.readU64();
    final queryId = decoder.readU32();
    final rows = SubscribeRows.decode(decoder);

    return SubscribeApplied(
      requestId: requestId,
      totalHostExecutionDurationMicros: duration,
      queryId: queryId,
      rows: rows,
    );
  }
}

class SubscribeRows {
  final int tableId;
  final String tableName;
  final TableUpdate tableUpdate;

  SubscribeRows({
    required this.tableId,
    required this.tableName,
    required this.tableUpdate,
  });

  static SubscribeRows decode(BsatnDecoder decoder) {
    final tableId = decoder.readU32();
    final tableName = decoder.readString();
    final tableUpdate = TableUpdate.decode(decoder);

    return SubscribeRows(
      tableId: tableId,
      tableName: tableName,
      tableUpdate: tableUpdate,
    );
  }
}

/// Response to Unsubscribe
class UnsubscribeApplied implements ServerMessage {
  final int requestId;
  final Int64 totalHostExecutionDurationMicros;
  final int queryId;
  final SubscribeRows rows;

  UnsubscribeApplied({
    required this.requestId,
    required this.totalHostExecutionDurationMicros,
    required this.queryId,
    required this.rows,
  });

  @override
  ServerMessageType get messageType => ServerMessageType.unsubscribeApplied;

  static UnsubscribeApplied decode(BsatnDecoder decoder) {
    final requestId = decoder.readU32();
    final duration = decoder.readU64();
    final queryId = decoder.readU32();
    final rows = SubscribeRows.decode(decoder);

    return UnsubscribeApplied(
      requestId: requestId,
      totalHostExecutionDurationMicros: duration,
      queryId: queryId,
      rows: rows,
    );
  }
}

/// Subscription error from server
class SubscriptionErrorMessage implements ServerMessage {
  final Int64 totalHostExecutionDurationMicros;
  final int requestId;
  final int queryId;
  final int tableId;
  final String error;

  SubscriptionErrorMessage({
    required this.totalHostExecutionDurationMicros,
    required this.requestId,
    required this.queryId,
    required this.tableId,
    required this.error,
  });

  @override
  ServerMessageType get messageType => ServerMessageType.subscriptionError;

  static SubscriptionErrorMessage decode(BsatnDecoder decoder) {
    final duration = decoder.readU64();
    decoder.readOption(() => decoder.readU32());
    final requestId = decoder.readU32();
    decoder.readOption(() => decoder.readU32());
    final queryId = decoder.readU32();
    final error = decoder.readOption(() => decoder.readString()) ?? '';

    return SubscriptionErrorMessage(
      totalHostExecutionDurationMicros: duration,
      requestId: requestId,
      queryId: queryId,
      tableId: 0,
      error: error,
    );
  }
}

/// Response to SubscribeMulti containing initial matching rows
class SubscribeMultiApplied implements ServerMessage {
  final int requestId;
  final Int64 totalHostExecutionDurationMicros;
  final int queryId;
  final List<TableUpdate> tableUpdates;

  SubscribeMultiApplied({
    required this.requestId,
    required this.totalHostExecutionDurationMicros,
    required this.queryId,
    required this.tableUpdates,
  });

  @override
  ServerMessageType get messageType => ServerMessageType.subscribeMultiApplied;

  static SubscribeMultiApplied decode(BsatnDecoder decoder) {
    final requestId = decoder.readU32();
    final duration = decoder.readU64();
    final queryId = decoder.readU32();

    final tableUpdates = decoder.readList(() => TableUpdate.decode(decoder));

    return SubscribeMultiApplied(
      requestId: requestId,
      totalHostExecutionDurationMicros: duration,
      queryId: queryId,
      tableUpdates: tableUpdates,
    );
  }
}

/// Response to UnsubscribeMulti
class UnsubscribeMultiApplied implements ServerMessage {
  final int requestId;
  final Int64 totalHostExecutionDurationMicros;
  final int queryId;
  final List<TableUpdate> tableUpdates;

  UnsubscribeMultiApplied({
    required this.requestId,
    required this.totalHostExecutionDurationMicros,
    required this.queryId,
    required this.tableUpdates,
  });

  @override
  ServerMessageType get messageType =>
      ServerMessageType.unsubscribeMultiApplied;

  static UnsubscribeMultiApplied decode(BsatnDecoder decoder) {
    final requestId = decoder.readU32();
    final duration = decoder.readU64();
    final queryId = decoder.readU32();

    final tableUpdates = decoder.readList(() => TableUpdate.decode(decoder));

    return UnsubscribeMultiApplied(
      requestId: requestId,
      totalHostExecutionDurationMicros: duration,
      queryId: queryId,
      tableUpdates: tableUpdates,
    );
  }
}

/// Result of a procedure/reducer call
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

/// Status of a procedure execution
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
      return ProcedureStatus(type: ProcedureStatusType.outOfEnergy);
    } else if (tag == 2) {
      final error = decoder.readString();
      return ProcedureStatus(
        type: ProcedureStatusType.internalError,
        errorMessage: error,
      );
    }

    throw ArgumentError('Unknown ProcedureStatus tag: $tag');
  }
}

enum ProcedureStatusType { returned, outOfEnergy, internalError }
