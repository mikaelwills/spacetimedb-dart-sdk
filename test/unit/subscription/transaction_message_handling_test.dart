import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:spacetimedb_sdk/protocol.dart';

void main() {
  group('TransactionUpdate Message Handling', () {
    test('creates TransactionUpdateMessage with all required fields', () {
      // Setup: Create a TransactionUpdateMessage with all required fields
      const reducerName = 'create_note';
      final reducerArgs = Uint8List(0); // Empty args for simplicity

      final message = TransactionUpdateMessage(
        transactionOffset: 1,
        timestamp: Int64(123456),
        tableUpdates: [],
        status: Committed(),
        reducerCall: ReducerInfo(
          reducerName: reducerName,
          reducerId: 42,
          args: reducerArgs,
          requestId: 100,
        ),
        callerIdentity: Uint8List(32),
        callerConnectionId: Uint8List(16),
        energyQuantaUsed: 100,
        totalHostExecutionDuration: Int64(5000),
      );

      // Verify the message structure
      expect(message.reducerCall, isNotNull);
      expect(message.reducerCall.reducerName, equals(reducerName));
      expect(message.reducerCall.reducerId, equals(42));
      expect(message.status, isA<Committed>());
      expect(message.callerIdentity, isNotNull);
      expect(message.callerConnectionId, isNotNull);
      expect(message.energyQuantaUsed, equals(100));
    });

    test('handles Failed transaction status', () {
      final message = TransactionUpdateMessage(
        transactionOffset: 1,
        timestamp: Int64(123456),
        tableUpdates: [],
        status: Failed('Database error'),
        reducerCall: ReducerInfo(
          reducerName: 'test_reducer',
          reducerId: 1,
          args: Uint8List(0),
          requestId: 200,
        ),
        callerIdentity: Uint8List(32),
        callerConnectionId: Uint8List(16),
        energyQuantaUsed: 50,
        totalHostExecutionDuration: Int64(2000),
      );

      expect(message.status, isA<Failed>());
      final status = message.status;
      if (status is! Failed) {
        fail('Expected Failed status but got ${status.runtimeType}');
      }
      expect(status.message, equals('Database error'));
    });

    test('handles OutOfEnergy transaction status', () {
      final message = TransactionUpdateMessage(
        transactionOffset: 1,
        timestamp: Int64(123456),
        tableUpdates: [],
        status: OutOfEnergy('Budget exceeded: 1000/500'),
        reducerCall: ReducerInfo(
          reducerName: 'expensive_reducer',
          reducerId: 99,
          args: Uint8List(0),
          requestId: 300,
        ),
        callerIdentity: Uint8List(32),
        callerConnectionId: Uint8List(16),
        energyQuantaUsed: 1000,
        totalHostExecutionDuration: Int64(10000),
      );

      expect(message.status, isA<OutOfEnergy>());
      final status = message.status;
      if (status is! OutOfEnergy) {
        fail('Expected OutOfEnergy status but got ${status.runtimeType}');
      }
      expect(status.budgetInfo, equals('Budget exceeded: 1000/500'));
    });
  });

  group('EventContext Creation', () {
    test('EventContext wraps Event with client reference', () {
      final event = UnknownTransactionEvent();
      final context = EventContext(
        myConnectionId: null, // Can be null in tests
        event: event,
      );

      expect(context.event, equals(event));
      expect(context.event, isA<UnknownTransactionEvent>());
    });

    test('EventContext with ReducerEvent', () {
      final event = ReducerEvent(
        timestamp: Int64(123456),
        status: Committed(),
        callerIdentity: Uint8List(32),
        callerConnectionId: Uint8List.fromList([1, 2, 3, 4]),
        energyConsumed: 100,
        reducerName: 'test_reducer',
        reducerArgs: {'key': 'value'},
      );

      final context = EventContext(myConnectionId: null, event: event);

      expect(context.event, isA<ReducerEvent>());
      final contextEvent = context.event;
      if (contextEvent is! ReducerEvent) {
        fail('Expected ReducerEvent but got ${contextEvent.runtimeType}');
      }
      // After type guard, access fields directly from promoted type
      expect(contextEvent.reducerName, equals('test_reducer'));
      expect(contextEvent.timestamp, equals(Int64(123456)));
      expect(contextEvent.energyConsumed, equals(100));
    });
  });

  group('Event Type Creation from TransactionUpdateMessage', () {
    test('ReducerEvent preserves all metadata fields', () {
      final timestamp = Int64(987654321);
      final status = Committed();
      final callerIdentity = Uint8List(32);
      final callerConnectionId = Uint8List.fromList([5, 6, 7, 8]);
      const energyConsumed = 250;
      const reducerName = 'update_note';
      final reducerArgs = {'title': 'Updated Title'};

      final event = ReducerEvent(
        timestamp: timestamp,
        status: status,
        callerIdentity: callerIdentity,
        callerConnectionId: callerConnectionId,
        energyConsumed: energyConsumed,
        reducerName: reducerName,
        reducerArgs: reducerArgs,
      );

      // Verify all fields are preserved
      expect(event.timestamp, equals(timestamp));
      expect(event.status, equals(status));
      expect(event.callerIdentity, equals(callerIdentity));
      expect(event.callerConnectionId, equals(callerConnectionId));
      expect(event.energyConsumed, equals(energyConsumed));
      expect(event.reducerName, equals(reducerName));
      expect(event.reducerArgs, equals(reducerArgs));
    });

    test('handles null optional fields gracefully', () {
      final event = ReducerEvent(
        timestamp: Int64(123),
        status: Committed(),
        callerIdentity: Uint8List(32),
        callerConnectionId: null, // Optional
        energyConsumed: null, // Optional
        reducerName: 'test',
        reducerArgs: {},
      );

      expect(event.callerConnectionId, isNull);
      expect(event.energyConsumed, isNull);
    });
  });

  group('Backward Compatibility', () {
    test('ValueNotifier API types exist after v1.0.0 migration', () {
      expect(TableCache<String>, isNotNull);
    });
  });

  group('No as Casts Rule', () {
    test('uses type guards instead of as casts', () {
      final Event event = ReducerEvent(
        timestamp: Int64(123),
        status: Committed(),
        callerIdentity: Uint8List(32),
        reducerName: 'test',
        reducerArgs: {},
      );

      // ✅ Good: Using type guard
      if (event is! ReducerEvent) {
        fail('Should be ReducerEvent');
      }

      // After type guard, Dart automatically promotes the type
      expect(event.reducerName, equals('test'));

      // ❌ Bad: Using as cast (should never do this)
      // final reducerEvent = event as ReducerEvent;
    });
  });
}
