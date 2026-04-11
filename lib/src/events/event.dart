import 'dart:typed_data';

import 'package:fixnum/fixnum.dart';

import '../messages/update_status.dart';

/// Base sealed class for all transaction events
///
/// Represents different types of events that can trigger database changes:
/// - [ReducerEvent]: A reducer call caused the transaction
/// - [SubscribeAppliedEvent]: Initial subscription data being applied
/// - [UnknownTransactionEvent]: Transaction source is unknown
///
/// The sealed class pattern enables exhaustive pattern matching:
/// ```dart
/// void handleEvent(Event event) {
///   switch (event) {
///     case ReducerEvent(:final reducerName):
///       print('Reducer: $reducerName');
///     case SubscribeAppliedEvent():
///       print('Subscription applied');
///     case UnknownTransactionEvent():
///       print('Unknown transaction');
///   }
/// }
/// ```
sealed class Event {}

/// Event triggered by a reducer execution
///
/// Contains all metadata about the reducer call that caused a transaction,
/// including the reducer name, arguments, caller information, and execution status.
class ReducerEvent extends Event {
  /// Server timestamp when the transaction occurred (microseconds since epoch)
  final Int64 timestamp;

  /// Status of the transaction (Committed, Failed, or OutOfEnergy)
  final UpdateStatus status;

  /// Identity of the client that called the reducer (32 bytes)
  final Uint8List callerIdentity;

  /// Connection ID of the client that called the reducer (16 bytes, optional)
  final Uint8List? callerConnectionId;

  /// Energy consumed by the reducer execution (optional)
  final int? energyConsumed;

  /// Name of the reducer that was called
  final String reducerName;

  /// Strongly-typed reducer arguments object
  ///
  /// This is the actual args class (e.g., CreateNoteArgs, UpdateNoteArgs)
  /// deserialized by the ReducerArgDecoder. Type is dynamic due to
  /// heterogeneous storage, but the actual runtime type is preserved.
  ///
  /// Generator knows the concrete type when creating listeners.
  ///
  /// Example:
  /// ```dart
  /// if (event.reducerName == 'create_note') {
  ///   final args = event.reducerArgs as CreateNoteArgs;
  ///   print('Title: ${args.title}');
  /// }
  /// ```
  final dynamic reducerArgs;

  ReducerEvent({
    required this.timestamp,
    required this.status,
    required this.callerIdentity,
    required this.reducerName,
    required this.reducerArgs,
    this.callerConnectionId,
    this.energyConsumed,
  });
}

/// Event triggered by a subscription being applied
///
/// This event occurs when initial subscription data is loaded into the cache.
/// It represents the "baseline" data state before any transactions occur.
class SubscribeAppliedEvent extends Event {}

class UnknownTransactionEvent extends Event {}

class OptimisticEvent extends Event {
  final String requestId;

  OptimisticEvent({required this.requestId});
}
