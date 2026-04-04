import 'dart:typed_data';
import '../codec/bsatn_encoder.dart';

/// Client message type tags (Client -> Server)
enum ClientMessageType {
  callReducer(0),
  subscribe(1),
  oneOffQuery(2),
  subscribeSingle(3),
  subscribeMulti(4),
  unsubscribe(5),
  unsubscribeMulti(6),
  callProcedure(7);

  final int tag;
  const ClientMessageType(this.tag);
}

abstract class ClientMessage {
  ClientMessageType get messageType;

  /// Encode this message to BSATN bytes (including tag)
  Uint8List encode();
}

/// Client message to subscribe to tables via SQL queries
class SubscribeMessage implements ClientMessage {
  final List<String> queries;
  final int requestId;

  SubscribeMessage(this.queries, {this.requestId = 0});

  @override
  ClientMessageType get messageType => ClientMessageType.subscribe;

  @override
  Uint8List encode() {
    final encoder = BsatnEncoder();
    encoder.writeU8(messageType.tag);
    encoder.writeList(queries, (query) => encoder.writeString(query));
    encoder.writeU32(requestId);
    return encoder.toBytes();
  }
}

/// Subscribe to a single query (newer API, returns SubscribeApplied)
class SubscribeSingleMessage implements ClientMessage {
  final String query;
  final int requestId;
  final int queryId;

  SubscribeSingleMessage(this.query, {this.requestId = 0, this.queryId = 0});

  @override
  ClientMessageType get messageType => ClientMessageType.subscribeSingle;

  @override
  Uint8List encode() {
    final encoder = BsatnEncoder();
    encoder.writeU8(messageType.tag);
    encoder.writeString(query);
    encoder.writeU32(requestId);
    encoder.writeU32(queryId);
    return encoder.toBytes();
  }
}

/// Client message for subscribing to multiple queries at once
class SubscribeMultiMessage implements ClientMessage {
  final List<String> queries;
  final int requestId;
  final int queryId;

  SubscribeMultiMessage(this.queries, {this.requestId = 0, this.queryId = 0});

  @override
  ClientMessageType get messageType => ClientMessageType.subscribeMulti;

  @override
  Uint8List encode() {
    final encoder = BsatnEncoder();
    encoder.writeU8(messageType.tag);
    encoder.writeU32(queries.length);
    for (final query in queries) {
      encoder.writeString(query);
    }
    encoder.writeU32(requestId);
    encoder.writeU32(queryId);
    return encoder.toBytes();
  }
}

/// Client message for unsubscribing from multiple queries
class UnsubscribeMultiMessage implements ClientMessage {
  final int requestId;
  final int queryId;

  UnsubscribeMultiMessage({required this.queryId, this.requestId = 0});

  @override
  ClientMessageType get messageType => ClientMessageType.unsubscribeMulti;

  @override
  Uint8List encode() {
    final encoder = BsatnEncoder();
    encoder.writeU8(messageType.tag);
    encoder.writeU32(requestId);
    encoder.writeU32(queryId);
    return encoder.toBytes();
  }
}

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
    encoder.writeString(reducerName);
    // Args field is of type Bytes in the product type, needs length prefix
    encoder.writeU32(args.length);
    encoder.writeBytes(args);
    encoder.writeU32(requestId);
    encoder.writeU8(0); // CallReducerFlags::FullUpdate
    return encoder.toBytes();
  }
}

/// Client message for calling a procedure
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
    encoder.writeString(procedureName);
    // Args field is of type Bytes in the product type, needs length prefix
    encoder.writeU32(args.length);
    encoder.writeBytes(args);
    encoder.writeU32(requestId);
    encoder.writeU8(0); // CallReducerFlags::FullUpdate
    return encoder.toBytes();
  }
}

/// Client message for one-off SQL query
class OneOffQueryMessage implements ClientMessage {
  final Uint8List messageId;
  final String queryString;

  OneOffQueryMessage({required this.messageId, required this.queryString});

  @override
  ClientMessageType get messageType => ClientMessageType.oneOffQuery;

  @override
  Uint8List encode() {
    final encoder = BsatnEncoder();
    encoder.writeU8(messageType.tag);
    encoder.writeU32(messageId.length);
    encoder.writeBytes(messageId);
    encoder.writeString(queryString);
    return encoder.toBytes();
  }
}

/// Client message to unsubscribe from a query
class UnsubscribeMessage implements ClientMessage {
  final int queryId;
  final int requestId;

  UnsubscribeMessage({required this.queryId, this.requestId = 0});

  @override
  ClientMessageType get messageType => ClientMessageType.unsubscribe;

  @override
  Uint8List encode() {
    final encoder = BsatnEncoder();
    encoder.writeU8(messageType.tag);
    encoder.writeU32(requestId);
    encoder.writeU32(queryId);
    return encoder.toBytes();
  }
}
