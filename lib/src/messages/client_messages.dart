import 'dart:typed_data';
import '../codec/bsatn_encoder.dart';

/// v2 `ClientMessage` tag order (v2.rs:18-29).
enum ClientMessageType {
  subscribe(0),
  unsubscribe(1),
  oneOffQuery(2),
  callReducer(3),
  callProcedure(4);

  final int tag;
  const ClientMessageType(this.tag);
}

sealed class ClientMessage {
  ClientMessageType get messageType;

  Uint8List encode();
}

/// Flags on `Unsubscribe`. Wire: `v2.rs:86-93`.
enum UnsubscribeFlags {
  defaultFlag(0),
  sendDroppedRows(1);

  final int value;
  const UnsubscribeFlags(this.value);
}

/// v2 `Subscribe`. Wire: `v2.rs:53-67`.
/// `{ request_id: u32, query_set_id: u32, query_strings: Box<[Box<str>]> }`.
class SubscribeMessage implements ClientMessage {
  final List<String> queries;
  final int requestId;
  final int querySetId;

  SubscribeMessage(
    this.queries, {
    required this.querySetId,
    this.requestId = 0,
  });

  @override
  ClientMessageType get messageType => ClientMessageType.subscribe;

  @override
  Uint8List encode() {
    final encoder = BsatnEncoder();
    encoder.writeU8(messageType.tag);
    encoder.writeU32(requestId);
    encoder.writeU32(querySetId);
    encoder.writeU32(queries.length);
    for (final query in queries) {
      encoder.writeString(query);
    }
    return encoder.toBytes();
  }
}

/// v2 `Unsubscribe`. Wire: `v2.rs:74-93`.
/// `{ request_id: u32, query_set_id: u32, flags: UnsubscribeFlags(u8) }`.
class UnsubscribeMessage implements ClientMessage {
  final int querySetId;
  final int requestId;
  final UnsubscribeFlags flags;

  UnsubscribeMessage({
    required this.querySetId,
    this.requestId = 0,
    this.flags = UnsubscribeFlags.defaultFlag,
  });

  @override
  ClientMessageType get messageType => ClientMessageType.unsubscribe;

  @override
  Uint8List encode() {
    final encoder = BsatnEncoder();
    encoder.writeU8(messageType.tag);
    encoder.writeU32(requestId);
    encoder.writeU32(querySetId);
    encoder.writeU8(flags.value);
    return encoder.toBytes();
  }
}

/// v2 `OneOffQuery`. Wire: `v2.rs:101-109`.
/// `{ request_id: u32, query_string: Box<str> }`.
class OneOffQueryMessage implements ClientMessage {
  final String queryString;
  final int requestId;

  OneOffQueryMessage({required this.queryString, this.requestId = 0});

  @override
  ClientMessageType get messageType => ClientMessageType.oneOffQuery;

  @override
  Uint8List encode() {
    final encoder = BsatnEncoder();
    encoder.writeU8(messageType.tag);
    encoder.writeU32(requestId);
    encoder.writeString(queryString);
    return encoder.toBytes();
  }
}

/// v2 `CallReducer`. Wire: `v2.rs:115-131`.
/// `{ request_id: u32, flags: CallReducerFlags(u8), reducer: Box<str>, args: Bytes }`.
class CallReducerMessage implements ClientMessage {
  final String reducerName;
  final Uint8List args;
  final int requestId;

  CallReducerMessage({
    required this.reducerName,
    required this.args,
    this.requestId = 0,
  });

  @override
  ClientMessageType get messageType => ClientMessageType.callReducer;

  @override
  Uint8List encode() {
    final encoder = BsatnEncoder();
    encoder.writeU8(messageType.tag);
    encoder.writeU32(requestId);
    encoder.writeU8(0); // CallReducerFlags::Default
    encoder.writeString(reducerName);
    encoder.writeU32(args.length);
    encoder.writeBytes(args);
    return encoder.toBytes();
  }
}

/// v2 `CallProcedure`. Wire: `v2.rs:150-166`.
/// `{ request_id: u32, flags: CallProcedureFlags(u8), procedure: Box<str>, args: Bytes }`.
class CallProcedureMessage implements ClientMessage {
  final String procedureName;
  final Uint8List args;
  final int requestId;

  CallProcedureMessage({
    required this.procedureName,
    required this.args,
    this.requestId = 0,
  });

  @override
  ClientMessageType get messageType => ClientMessageType.callProcedure;

  @override
  Uint8List encode() {
    final encoder = BsatnEncoder();
    encoder.writeU8(messageType.tag);
    encoder.writeU32(requestId);
    encoder.writeU8(0); // CallProcedureFlags::Default
    encoder.writeString(procedureName);
    encoder.writeU32(args.length);
    encoder.writeBytes(args);
    return encoder.toBytes();
  }
}
