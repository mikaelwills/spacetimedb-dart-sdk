import 'dart:typed_data';

import 'package:fixnum/fixnum.dart';

import '../messages/update_status.dart';

/// Base sealed class for all transaction events.
///
/// - [ReducerEvent]: caller's own reducer call result (v2 `ReducerResult`).
/// - [SubscribeAppliedEvent]: initial subscription data being applied.
/// - [UnknownTransactionEvent]: remote-write `TransactionUpdate` broadcasts.
///
/// Under v2, `ReducerEvent` is only ever constructed on the caller side
/// (`ReducerResult` handler). Non-caller `TransactionUpdate` broadcasts
/// carry no reducer metadata on the wire (`v2.rs:302-306`) and surface as
/// `UnknownTransactionEvent`. Observe remote changes via row streams.
sealed class Event {}

class ReducerEvent extends Event {
  /// Server timestamp when the reducer started (microseconds since Unix epoch).
  final Int64 timestamp;

  final UpdateStatus status;

  /// Caller identity (32 bytes). On v2, known only locally.
  final Uint8List callerIdentity;

  /// Caller connection ID (16 bytes). On v2, known only locally.
  final Uint8List? callerConnectionId;

  final String reducerName;

  /// Strongly-typed reducer arguments, deserialized by the generator-registered
  /// `ReducerArgDecoder`. Type is `dynamic` due to heterogeneous storage; the
  /// runtime type is preserved.
  final dynamic reducerArgs;

  ReducerEvent({
    required this.timestamp,
    required this.status,
    required this.callerIdentity,
    required this.reducerName,
    required this.reducerArgs,
    this.callerConnectionId,
  });
}

class SubscribeAppliedEvent extends Event {}

class UnknownTransactionEvent extends Event {}

class OptimisticEvent extends Event {
  final String requestId;

  OptimisticEvent({required this.requestId});
}
