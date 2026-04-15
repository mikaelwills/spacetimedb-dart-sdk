import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:spacetimedb_sdk/codegen.dart';

void main() {
  group('Event sealed class', () {
    test('ReducerEvent can be created', () {
      final event = ReducerEvent(
        timestamp: Int64(123456),
        status: Committed(),
        callerIdentity: Uint8List(32),
        callerConnectionId: Uint8List.fromList([1, 2, 3, 4]),
        energyConsumed: 100,
        reducerName: 'create_note',
        reducerArgs: {'title': 'Test', 'content': 'Content'},
      );

      expect(event.timestamp, equals(Int64(123456)));
      expect(event.reducerName, equals('create_note'));
      expect(event.status, isA<Committed>());
    });

    test('SubscribeAppliedEvent can be created', () {
      final event = SubscribeAppliedEvent();
      expect(event, isA<Event>());
      expect(event, isA<SubscribeAppliedEvent>());
    });

    test('UnknownTransactionEvent can be created', () {
      final event = UnknownTransactionEvent();
      expect(event, isA<Event>());
      expect(event, isA<UnknownTransactionEvent>());
    });

    test('pattern matching works on Event sealed class', () {
      void testEvent(Event event) {
        switch (event) {
          case ReducerEvent():
            return;
          case SubscribeAppliedEvent():
            return;
          case UnknownTransactionEvent():
            return;
          case OptimisticEvent():
            return;
        }
      }

      // Should compile and run without errors
      testEvent(
        ReducerEvent(
          timestamp: Int64.ZERO,
          status: Committed(),
          callerIdentity: Uint8List(32),
          reducerName: 'test',
          reducerArgs: {},
        ),
      );
      testEvent(SubscribeAppliedEvent());
      testEvent(UnknownTransactionEvent());
      testEvent(OptimisticEvent(requestId: 'test-123'));
    });
  });

  group('UpdateStatus sealed class', () {
    test('Committed has correct toString', () {
      final status = Committed();
      expect(status.toString(), equals('Committed()'));
    });

    test('Failed has correct toString', () {
      final status = Failed('Database error');
      expect(status.toString(), equals('Failed(message: Database error)'));
    });

    test('OutOfEnergy has correct toString', () {
      final status = OutOfEnergy('Budget: 1000/500');
      expect(
        status.toString(),
        equals('OutOfEnergy(budgetInfo: Budget: 1000/500)'),
      );
    });

    test('pattern matching works on UpdateStatus', () {
      String handleStatus(UpdateStatus status) {
        return switch (status) {
          Committed() => 'success',
          Failed(:final message) => 'failed: $message',
          OutOfEnergy(:final budgetInfo) => 'out of energy: $budgetInfo',
          Pending() => 'pending',
          Dropped() => 'dropped',
        };
      }

      expect(handleStatus(Committed()), equals('success'));
      expect(handleStatus(Failed('error')), equals('failed: error'));
      expect(handleStatus(Pending()), equals('pending'));
      expect(
        handleStatus(OutOfEnergy('budget')),
        equals('out of energy: budget'),
      );
    });
  });

  group('EventContext', () {
    test('creates with myConnectionId and event', () {
      final connectionId = Uint8List.fromList([1, 2, 3, 4]);
      final event = UnknownTransactionEvent();
      final ctx = EventContext(myConnectionId: connectionId, event: event);

      expect(ctx.event, equals(event));
    });

    test('isMyTransaction returns false for non-ReducerEvent', () {
      final connectionId = Uint8List.fromList([1, 2, 3, 4]);
      final event = SubscribeAppliedEvent();
      final ctx = EventContext(myConnectionId: connectionId, event: event);

      expect(ctx.isMyTransaction, isFalse);
    });

    test('isMyTransaction returns true for matching connection IDs', () {
      final myConnectionId = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);

      final event = ReducerEvent(
        timestamp: Int64(123),
        status: Committed(),
        callerIdentity: Uint8List(32),
        callerConnectionId: myConnectionId,
        energyConsumed: 100,
        reducerName: 'test',
        reducerArgs: {},
      );

      final ctx = EventContext(myConnectionId: myConnectionId, event: event);
      expect(ctx.isMyTransaction, isTrue);
    });

    test('isMyTransaction returns false for different connection IDs', () {
      final myConnectionId = Uint8List.fromList([1, 2, 3, 4]);
      final otherConnectionId = Uint8List.fromList([5, 6, 7, 8]);

      final event = ReducerEvent(
        timestamp: Int64(123),
        status: Committed(),
        callerIdentity: Uint8List(32),
        callerConnectionId: otherConnectionId,
        energyConsumed: 100,
        reducerName: 'test',
        reducerArgs: {},
      );

      final ctx = EventContext(myConnectionId: myConnectionId, event: event);
      expect(ctx.isMyTransaction, isFalse);
    });

    test('isMyTransaction returns false when myConnectionId is null', () {
      final event = ReducerEvent(
        timestamp: Int64(123),
        status: Committed(),
        callerIdentity: Uint8List(32),
        callerConnectionId: Uint8List.fromList([1, 2, 3, 4]),
        energyConsumed: 100,
        reducerName: 'test',
        reducerArgs: {},
      );

      final ctx = EventContext(myConnectionId: null, event: event);
      expect(ctx.isMyTransaction, isFalse);
    });

    test('isMyTransaction returns false when caller connectionId is null', () {
      final myConnectionId = Uint8List.fromList([1, 2, 3, 4]);

      final event = ReducerEvent(
        timestamp: Int64(123),
        status: Committed(),
        callerIdentity: Uint8List(32),
        callerConnectionId: null,
        energyConsumed: 100,
        reducerName: 'test',
        reducerArgs: {},
      );

      final ctx = EventContext(myConnectionId: myConnectionId, event: event);
      expect(ctx.isMyTransaction, isFalse);
    });

    test('byte comparison works correctly for different length arrays', () {
      final myConnectionId = Uint8List.fromList([1, 2, 3]);
      final otherConnectionId = Uint8List.fromList([1, 2, 3, 4]);

      final event = ReducerEvent(
        timestamp: Int64(123),
        status: Committed(),
        callerIdentity: Uint8List(32),
        callerConnectionId: otherConnectionId,
        energyConsumed: 100,
        reducerName: 'test',
        reducerArgs: {},
      );

      final ctx = EventContext(myConnectionId: myConnectionId, event: event);
      // Should return false because lengths don't match
      expect(ctx.isMyTransaction, isFalse);
    });
  });

  group('TableEvent sealed class', () {
    late EventContext mockContext;

    setUp(() {
      final event = UnknownTransactionEvent();
      mockContext = EventContext(myConnectionId: null, event: event);
    });

    test('TableInsertEvent can be created', () {
      final event = TableInsertEvent<String>(mockContext, 'test row');

      expect(event.context, equals(mockContext));
      expect(event.row, equals('test row'));
      expect(event, isA<TableEvent<String>>());
    });

    test('TableUpdateEvent can be created', () {
      final event = TableUpdateEvent<String>(mockContext, 'old row', 'new row');

      expect(event.context, equals(mockContext));
      expect(event.oldRow, equals('old row'));
      expect(event.newRow, equals('new row'));
      expect(event, isA<TableEvent<String>>());
    });

    test('TableDeleteEvent can be created', () {
      final event = TableDeleteEvent<String>(mockContext, 'deleted row');

      expect(event.context, equals(mockContext));
      expect(event.row, equals('deleted row'));
      expect(event, isA<TableEvent<String>>());
    });

    test('pattern matching works with generic handler', () {
      void handleTableEvent<T>(TableEvent<T> event) {
        switch (event) {
          case TableInsertEvent(:final row, :final context):
            expect(row, isNotNull);
            expect(context, isNotNull);
          case TableUpdateEvent(:final oldRow, :final newRow):
            expect(oldRow, isNotNull);
            expect(newRow, isNotNull);
          case TableDeleteEvent(:final row):
            expect(row, isNotNull);
        }
      }

      // Should compile and run without errors
      handleTableEvent(TableInsertEvent<String>(mockContext, 'test'));
      handleTableEvent(TableUpdateEvent<String>(mockContext, 'old', 'new'));
      handleTableEvent(TableDeleteEvent<String>(mockContext, 'test'));
    });

    test('generic types are preserved', () {
      final insertEvent = TableInsertEvent<int>(mockContext, 42);
      final updateEvent = TableUpdateEvent<bool>(mockContext, true, false);
      final deleteEvent = TableDeleteEvent<double>(mockContext, 3.14);

      expect(insertEvent, isA<TableEvent<int>>());
      expect(insertEvent.row, isA<int>());

      expect(updateEvent, isA<TableEvent<bool>>());
      expect(updateEvent.oldRow, isA<bool>());
      expect(updateEvent.newRow, isA<bool>());

      expect(deleteEvent, isA<TableEvent<double>>());
      expect(deleteEvent.row, isA<double>());
    });
  });
}
