import 'dart:typed_data';
import 'event.dart';

/// Context information for a table change event
///
/// Wraps an [Event] with the current client's connection ID, providing
/// convenience methods and helpers for common operations.
///
/// The context allows event handlers to:
/// - Access transaction metadata (timestamp, reducer name, caller, etc.)
/// - Check if the transaction was initiated by the current client
///
/// Example:
/// ```dart
/// noteTable.insertEventStream.listen((event) {
///   final ctx = event.context;
///
///   if (ctx.isMyTransaction) {
///     print('I created this note!');
///   } else {
///     print('Someone else created this note');
///   }
///
///   // Access event metadata
///   if (ctx.event is ReducerEvent) {
///     final reducerEvent = ctx.event as ReducerEvent;
///     print('Reducer: ${reducerEvent.reducerName}');
///   }
/// });
/// ```
class EventContext {
  final Uint8List? _myConnectionId;
  final Event event;
  final bool isOptimistic;
  final String? pendingRequestId;

  EventContext({
    required Uint8List? myConnectionId,
    required this.event,
    this.isOptimistic = false,
    this.pendingRequestId,
  }) : _myConnectionId = myConnectionId;

  EventContext.optimistic({required String requestId})
    : _myConnectionId = null,
      event = OptimisticEvent(requestId: requestId),
      isOptimistic = true,
      pendingRequestId = requestId;

  /// 🌟 GOLD STANDARD: DX Helper - Check if this event was triggered by current client
  ///
  /// Returns true if this transaction was initiated by the current connection.
  /// This is a common check that would otherwise require verbose boilerplate.
  ///
  /// Returns false if:
  /// - Event is not a ReducerEvent
  /// - Either connection ID is null
  /// - Connection IDs don't match
  ///
  /// Example:
  /// ```dart
  /// noteTable.insertEventStream.listen((event) {
  ///   if (event.context.isMyTransaction) {
  ///     print('I created this note!');
  ///     // Maybe show a success toast
  ///   } else {
  ///     print('Someone else created this note');
  ///     // Maybe show a notification
  ///   }
  /// });
  /// ```
  bool get isMyTransaction {
    if (isOptimistic) return true;

    if (event is! ReducerEvent) return false;

    final reducerEvent = event as ReducerEvent;
    final callerConnectionId = reducerEvent.callerConnectionId;

    if (_myConnectionId == null || callerConnectionId == null) return false;

    return _bytesEqual(_myConnectionId, callerConnectionId);
  }

  /// Helper to compare two byte arrays for equality
  ///
  /// Returns true if both arrays are non-null and contain identical bytes
  /// in the same order. Returns false if either is null or lengths differ.
  static bool _bytesEqual(Uint8List? a, Uint8List? b) {
    if (a == null || b == null) return false;
    if (a.length != b.length) return false;

    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }

    return true;
  }
}
