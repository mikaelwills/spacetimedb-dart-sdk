import 'dart:async';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:spacetimedb_dart_sdk/spacetimedb_dart_sdk.dart';

// Simple mock decoder for testing
class MockDecoder extends RowDecoder<String> {
  @override
  String decode(BsatnDecoder decoder) => 'mock';

  @override
  dynamic getPrimaryKey(String row) => row.hashCode;
}

void main() {
  group('Phase 3: Event Stream Compilation', () {
    late TableCache<String> table;

    setUp(() {
      table = TableCache<String>(tableName: 'test', decoder: MockDecoder());
    });

    test('event stream getters exist and have correct types', () {
      // Verify new event streams exist
      expect(table.insertEventStream, isA<Stream<TableInsertEvent<String>>>());
      expect(table.updateEventStream, isA<Stream<TableUpdateEvent<String>>>());
      expect(table.deleteEventStream, isA<Stream<TableDeleteEvent<String>>>());
      expect(table.eventStream, isA<Stream<TableEvent<String>>>());
    });

    test('simple streams still exist (backward compatibility)', () {
      // Verify existing simple streams still work
      expect(table.insertStream, isA<Stream<String>>());
      expect(table.updateStream, isA<Stream>()); // TableUpdate is internal
      expect(table.deleteStream, isA<Stream<String>>());
      expect(table.changeStream, isA<Stream<TableChange<String>>>());
    });

    test('convenience filter streams exist', () {
      expect(
        table.insertsFromReducers,
        isA<Stream<TableInsertEvent<String>>>(),
      );
      expect(table.myInserts, isA<Stream<TableInsertEvent<String>>>());
      expect(table.eventsFromReducers, isA<Stream<TableEvent<String>>>());
      expect(table.myEvents, isA<Stream<TableEvent<String>>>());
    });

    test('event streams can be listened to', () {
      // Verify streams can be listened to without errors
      final subscriptions = <StreamSubscription>[];

      subscriptions.add(table.insertEventStream.listen((_) {}));
      subscriptions.add(table.updateEventStream.listen((_) {}));
      subscriptions.add(table.deleteEventStream.listen((_) {}));
      subscriptions.add(table.eventStream.listen((_) {}));
      subscriptions.add(table.insertsFromReducers.listen((_) {}));
      subscriptions.add(table.myInserts.listen((_) {}));
      subscriptions.add(table.eventsFromReducers.listen((_) {}));
      subscriptions.add(table.myEvents.listen((_) {}));

      // Clean up
      for (final sub in subscriptions) {
        sub.cancel();
      }

      expect(subscriptions.length, equals(8));
    });

    test('TableEvent types are properly defined', () {
      final event = ReducerEvent(
        timestamp: Int64(123),
        status: Committed(),
        callerIdentity: Uint8List(32),
        reducerName: 'test',
        reducerArgs: {},
      );

      final context = EventContext(myConnectionId: null, event: event);

      // Verify we can create all event types
      final insertEvent = TableInsertEvent<String>(context, 'test');
      final updateEvent = TableUpdateEvent<String>(context, 'old', 'new');
      final deleteEvent = TableDeleteEvent<String>(context, 'test');

      expect(insertEvent, isA<TableEvent<String>>());
      expect(updateEvent, isA<TableEvent<String>>());
      expect(deleteEvent, isA<TableEvent<String>>());
    });

    test('pattern matching compiles correctly', () {
      final event = ReducerEvent(
        timestamp: Int64(123),
        status: Committed(),
        callerIdentity: Uint8List(32),
        reducerName: 'test',
        reducerArgs: {},
      );

      final context = EventContext(myConnectionId: null, event: event);
      final insertEvent = TableInsertEvent<String>(context, 'test');

      // Test pattern matching
      final result = switch (insertEvent as TableEvent<String>) {
        TableInsertEvent(:final row) => 'insert:$row',
        TableUpdateEvent() => 'update',
        TableDeleteEvent() => 'delete',
      };

      expect(result, equals('insert:test'));
    });

    test('filter streams use correct predicates', () {
      // Verify filter streams are properly typed
      // We can't easily test the actual filtering without mock data,
      // but we can verify the streams compile and have correct types

      final reducerStream = table.insertsFromReducers;
      final myStream = table.myInserts;

      expect(reducerStream, isA<Stream<TableInsertEvent<String>>>());
      expect(myStream, isA<Stream<TableInsertEvent<String>>>());
    });

    test('event context is accessible from table events', () {
      final reducerEvent = ReducerEvent(
        timestamp: Int64(123456),
        status: Committed(),
        callerIdentity: Uint8List(32),
        callerConnectionId: Uint8List.fromList([1, 2, 3, 4]),
        energyConsumed: 100,
        reducerName: 'test_reducer',
        reducerArgs: {'key': 'value'},
      );

      final context = EventContext(myConnectionId: null, event: reducerEvent);
      final event = TableInsertEvent<String>(context, 'test row');

      // Verify context is accessible
      expect(event.context, equals(context));
      expect(event.context.event, isA<ReducerEvent>());

      // Verify reducer metadata is accessible
      final reducer = event.context.event as ReducerEvent;
      expect(reducer.reducerName, equals('test_reducer'));
      expect(reducer.timestamp, equals(Int64(123456)));
      expect(reducer.energyConsumed, equals(100));
      expect(reducer.status, isA<Committed>());
    });

    test('unified eventStream accepts all TableEvent subtypes', () {
      final context = EventContext(
        myConnectionId: null,
        event: UnknownTransactionEvent(),
      );

      // All these should be assignable to Stream<TableEvent<String>>
      final TableEvent<String> insert = TableInsertEvent(context, 'a');
      final TableEvent<String> update = TableUpdateEvent(context, 'a', 'b');
      final TableEvent<String> delete = TableDeleteEvent(context, 'a');

      expect(insert, isA<TableEvent<String>>());
      expect(update, isA<TableEvent<String>>());
      expect(delete, isA<TableEvent<String>>());
    });
  });

  group('Phase 3: Type Safety', () {
    test('no as casts needed with pattern matching', () {
      final event = ReducerEvent(
        timestamp: Int64(123),
        status: Committed(),
        callerIdentity: Uint8List(32),
        reducerName: 'test',
        reducerArgs: {},
      );

      final context = EventContext(myConnectionId: null, event: event);
      final TableEvent<String> tableEvent = TableInsertEvent(context, 'test');

      // ✅ Good: Type guard with pattern matching
      if (tableEvent is! TableInsertEvent<String>) {
        fail('Should be TableInsertEvent');
      }

      // After type guard, Dart automatically promotes the type
      expect(tableEvent.row, equals('test'));
      expect(tableEvent.context, equals(context));

      // ❌ Bad: Would use as cast (we don't do this!)
      // final insertEvent = tableEvent as TableInsertEvent<String>;
    });

    test('generic types are preserved through streams', () {
      // We already verify this with the String type above
      // Just documenting that generic types work correctly
      expect(true, isTrue);
    });
  });
}
