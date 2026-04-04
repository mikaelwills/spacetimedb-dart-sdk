import 'dart:typed_data';
import 'package:spacetimedb_dart_sdk/src/codec/bsatn_decoder.dart';

/// Metadata about which reducer caused a transaction
///
/// Maps to Rust ReducerCallInfo struct from websocket.rs
class ReducerInfo {
  /// The name of the reducer that was called
  final String reducerName;

  /// The numerical id of the reducer
  final int reducerId;

  /// Raw BSATN-encoded arguments that were passed to the reducer
  ///
  /// These bytes will be deserialized by the ReducerRegistry using
  /// the appropriate ReducerArgDecoder for this reducer.
  final Uint8List args;

  /// An identifier for a client request
  final int requestId;

  ReducerInfo({
    required this.reducerName,
    required this.reducerId,
    required this.args,
    required this.requestId,
  });

  /// Decode ReducerCallInfo from BSATN bytes
  /// Rust struct order: reducer_name, reducer_id, args (Vec<u8>), request_id
  static ReducerInfo decode(BsatnDecoder decoder) {
    final reducerName = decoder.readString();
    final reducerId = decoder.readU32();
    final argsLength = decoder.readU32();
    final args = decoder.readBytes(argsLength);
    final requestId = decoder.readU32();

    return ReducerInfo(
      reducerName: reducerName,
      reducerId: reducerId,
      args: args,
      requestId: requestId,
    );
  }

  @override
  String toString() =>
      'ReducerInfo(reducerName: $reducerName, reducerId: $reducerId, args: ${args.length} bytes, requestId: $requestId)';
}
