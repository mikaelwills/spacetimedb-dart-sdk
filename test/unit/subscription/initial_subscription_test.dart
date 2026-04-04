import 'dart:async';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:spacetimedb_dart_sdk/spacetimedb_dart_sdk.dart';

// Simple mock decoder for testing
class MockDecoder extends RowDecoder<String> {
  @override
  String decode(BsatnDecoder decoder) => 'mock_row';

  @override
  dynamic getPrimaryKey(String row) => row.hashCode;
}

void main() {
  group('Phase 6: Initial Subscription Handling', () {
    late TableCache<String> table;

    setUp(() {
      table = TableCache<String>(
        tableId: 1,
        tableName: 'test',
        decoder: MockDecoder(),
      );
    });

    test('applyInitialData accepts EventContext parameter', () {
      // Create SubscribeAppliedEvent context
      final event = SubscribeAppliedEvent();
      final context = EventContext(myConnectionId: null, event: event);

      // Create mock insert data
      final encoder = BsatnEncoder();
      encoder.writeString('test');
      final inserts = BsatnRowList(
        sizeHint: RowSizeHint.fixedSize(encoder.toBytes().length),
        rowsData: encoder.toBytes(),
      );

      // Should not throw
      expect(() => table.applyInitialData(inserts, context), returnsNormally);
    });

    test(
      'applyInitialData emits events with SubscribeAppliedEvent context',
      () async {
        final completer = Completer<EventContext>();

        // Listen to insert event stream
        final subscription = table.insertEventStream.listen((event) {
          if (!completer.isCompleted) {
            completer.complete(event.context);
          }
        });

        // Create SubscribeAppliedEvent context
        final subscribeEvent = SubscribeAppliedEvent();
        final context = EventContext(
          myConnectionId: null,
          event: subscribeEvent,
        );

        // Apply initial data
        final encoder = BsatnEncoder();
        encoder.writeString('test');
        final inserts = BsatnRowList(
          sizeHint: RowSizeHint.fixedSize(encoder.toBytes().length),
          rowsData: encoder.toBytes(),
        );
        table.applyInitialData(inserts, context);

        // Wait for event
        final capturedContext = await completer.future.timeout(
          const Duration(seconds: 2),
        );

        // Verify event was emitted
        expect(capturedContext, isNotNull);
        expect(capturedContext.event, isA<SubscribeAppliedEvent>());

        await subscription.cancel();
      },
    );

    test('users can distinguish initial data from reducer updates', () async {
      final initialCompleter = Completer<void>();
      final reducerCompleter = Completer<void>();

      // Listen and filter by event type
      final subscription = table.insertEventStream.listen((event) {
        if (event.context.event is SubscribeAppliedEvent) {
          if (!initialCompleter.isCompleted) {
            initialCompleter.complete();
          }
        } else if (event.context.event is ReducerEvent) {
          if (!reducerCompleter.isCompleted) {
            reducerCompleter.complete();
          }
        }
      });

      // Simulate initial subscription data
      final subscribeContext = EventContext(
        myConnectionId: null,
        event: SubscribeAppliedEvent(),
      );

      final encoder1 = BsatnEncoder();
      encoder1.writeString('initial_row');
      final inserts1 = BsatnRowList(
        sizeHint: RowSizeHint.fixedSize(encoder1.toBytes().length),
        rowsData: encoder1.toBytes(),
      );
      table.applyInitialData(inserts1, subscribeContext);

      // Simulate reducer update
      final reducerContext = EventContext(
        myConnectionId: null,
        event: ReducerEvent(
          timestamp: Int64(123),
          status: Committed(),
          callerIdentity: Uint8List(32),
          reducerName: 'test_reducer',
          reducerArgs: {},
        ),
      );

      final encoder2 = BsatnEncoder();
      encoder2.writeString('reducer_row');
      final inserts2 = BsatnRowList(
        sizeHint: RowSizeHint.fixedSize(encoder2.toBytes().length),
        rowsData: encoder2.toBytes(),
      );
      table.applyTransactionUpdate(
        BsatnRowList.empty(),
        inserts2,
        reducerContext,
      );

      // Wait for both events
      await Future.wait([
        initialCompleter.future.timeout(const Duration(seconds: 2)),
        reducerCompleter.future.timeout(const Duration(seconds: 2)),
      ]);

      await subscription.cancel();
    });

    test(
      'multiple rows in initial subscription all have SubscribeAppliedEvent',
      () async {
        final completer = Completer<List<Event>>();
        final capturedEvents = <Event>[];

        final subscription = table.insertEventStream.listen((event) {
          capturedEvents.add(event.context.event);
          if (capturedEvents.length == 3 && !completer.isCompleted) {
            completer.complete(capturedEvents);
          }
        });

        // Create initial data with multiple rows
        final subscribeContext = EventContext(
          myConnectionId: null,
          event: SubscribeAppliedEvent(),
        );

        // Encode each row individually and track offsets
        final encodedRows = <Uint8List>[];
        for (var i = 0; i < 3; i++) {
          final encoder = BsatnEncoder();
          encoder.writeString('row_$i');
          encodedRows.add(encoder.toBytes());
        }

        // Concatenate all rows and build offset list
        final allData = <int>[];
        final offsets = <int>[];
        for (final row in encodedRows) {
          offsets.add(allData.length);
          allData.addAll(row);
        }

        final inserts = BsatnRowList(
          sizeHint: RowSizeHint.rowOffsets(offsets),
          rowsData: Uint8List.fromList(allData),
        );
        table.applyInitialData(inserts, subscribeContext);

        // Wait for all 3 events
        final events = await completer.future.timeout(
          const Duration(seconds: 2),
        );

        // All events should be SubscribeAppliedEvent
        expect(events.length, equals(3));
        for (final event in events) {
          expect(event, isA<SubscribeAppliedEvent>());
        }

        await subscription.cancel();
      },
    );

    test(
      'unified eventStream receives SubscribeAppliedEvent inserts',
      () async {
        final completer = Completer<TableEvent<String>>();

        final subscription = table.eventStream.listen((event) {
          if (!completer.isCompleted) {
            completer.complete(event);
          }
        });

        final subscribeContext = EventContext(
          myConnectionId: null,
          event: SubscribeAppliedEvent(),
        );

        final encoder = BsatnEncoder();
        encoder.writeString('test_row');
        final inserts = BsatnRowList(
          sizeHint: RowSizeHint.fixedSize(encoder.toBytes().length),
          rowsData: encoder.toBytes(),
        );
        table.applyInitialData(inserts, subscribeContext);

        // Wait for event
        final capturedEvent = await completer.future.timeout(
          const Duration(seconds: 2),
        );

        expect(capturedEvent, isA<TableInsertEvent<String>>());
        expect(capturedEvent.context.event, isA<SubscribeAppliedEvent>());

        await subscription.cancel();
      },
    );

    test('pattern matching distinguishes event types', () async {
      final initialCompleter = Completer<void>();
      final realtimeCompleter = Completer<void>();

      final subscription = table.insertEventStream.listen((event) {
        switch (event.context.event) {
          case SubscribeAppliedEvent():
            if (!initialCompleter.isCompleted) {
              initialCompleter.complete();
            }
          case ReducerEvent():
            if (!realtimeCompleter.isCompleted) {
              realtimeCompleter.complete();
            }
          case UnknownTransactionEvent():
          case OptimisticEvent():
            break;
        }
      });

      // Initial data
      final subscribeContext = EventContext(
        myConnectionId: null,
        event: SubscribeAppliedEvent(),
      );
      final encoder1 = BsatnEncoder();
      encoder1.writeString('initial');
      final inserts1 = BsatnRowList(
        sizeHint: RowSizeHint.fixedSize(encoder1.toBytes().length),
        rowsData: encoder1.toBytes(),
      );
      table.applyInitialData(inserts1, subscribeContext);

      // Reducer update
      final reducerContext = EventContext(
        myConnectionId: null,
        event: ReducerEvent(
          timestamp: Int64(123),
          status: Committed(),
          callerIdentity: Uint8List(32),
          reducerName: 'test',
          reducerArgs: {},
        ),
      );
      final encoder2 = BsatnEncoder();
      encoder2.writeString('realtime');
      final inserts2 = BsatnRowList(
        sizeHint: RowSizeHint.fixedSize(encoder2.toBytes().length),
        rowsData: encoder2.toBytes(),
      );
      table.applyTransactionUpdate(
        BsatnRowList.empty(),
        inserts2,
        reducerContext,
      );

      // Wait for both events
      await Future.wait([
        initialCompleter.future.timeout(const Duration(seconds: 2)),
        realtimeCompleter.future.timeout(const Duration(seconds: 2)),
      ]);

      await subscription.cancel();
    });
  });

  group('Phase 6: Integration Patterns', () {
    test('convenience filter: only initial data', () async {
      final table = TableCache<String>(
        tableId: 1,
        tableName: 'test',
        decoder: MockDecoder(),
      );

      final completer = Completer<void>();
      var initialDataCount = 0;

      // Filter to only SubscribeAppliedEvent
      final subscription = table.insertEventStream
          .where((e) => e.context.event is SubscribeAppliedEvent)
          .listen((_) {
            initialDataCount++;
            if (!completer.isCompleted) {
              completer.complete();
            }
          });

      // Send both types
      final subscribeContext = EventContext(
        myConnectionId: null,
        event: SubscribeAppliedEvent(),
      );
      final encoder1 = BsatnEncoder();
      encoder1.writeString('initial');
      table.applyInitialData(
        BsatnRowList(
          sizeHint: RowSizeHint.fixedSize(encoder1.toBytes().length),
          rowsData: encoder1.toBytes(),
        ),
        subscribeContext,
      );

      final reducerContext = EventContext(
        myConnectionId: null,
        event: ReducerEvent(
          timestamp: Int64(123),
          status: Committed(),
          callerIdentity: Uint8List(32),
          reducerName: 'test',
          reducerArgs: {},
        ),
      );
      final encoder2 = BsatnEncoder();
      encoder2.writeString('reducer');
      table.applyTransactionUpdate(
        BsatnRowList.empty(),
        BsatnRowList(
          sizeHint: RowSizeHint.fixedSize(encoder2.toBytes().length),
          rowsData: encoder2.toBytes(),
        ),
        reducerContext,
      );

      // Wait for filtered event
      await completer.future.timeout(const Duration(seconds: 2));

      // Only initial data should be counted
      expect(initialDataCount, equals(1));

      await subscription.cancel();
    });

    test('convenience filter: skip initial data load', () async {
      final table = TableCache<String>(
        tableId: 1,
        tableName: 'test',
        decoder: MockDecoder(),
      );

      final completer = Completer<void>();
      var realtimeCount = 0;

      // Skip SubscribeAppliedEvent
      final subscription = table.insertEventStream
          .where((e) => e.context.event is! SubscribeAppliedEvent)
          .listen((_) {
            realtimeCount++;
            if (!completer.isCompleted) {
              completer.complete();
            }
          });

      // Send both types
      final subscribeContext = EventContext(
        myConnectionId: null,
        event: SubscribeAppliedEvent(),
      );
      final encoder1 = BsatnEncoder();
      encoder1.writeString('initial');
      table.applyInitialData(
        BsatnRowList(
          sizeHint: RowSizeHint.fixedSize(encoder1.toBytes().length),
          rowsData: encoder1.toBytes(),
        ),
        subscribeContext,
      );

      final reducerContext = EventContext(
        myConnectionId: null,
        event: ReducerEvent(
          timestamp: Int64(123),
          status: Committed(),
          callerIdentity: Uint8List(32),
          reducerName: 'test',
          reducerArgs: {},
        ),
      );
      final encoder2 = BsatnEncoder();
      encoder2.writeString('reducer');
      table.applyTransactionUpdate(
        BsatnRowList.empty(),
        BsatnRowList(
          sizeHint: RowSizeHint.fixedSize(encoder2.toBytes().length),
          rowsData: encoder2.toBytes(),
        ),
        reducerContext,
      );

      // Wait for filtered event
      await completer.future.timeout(const Duration(seconds: 2));

      // Only realtime updates should be counted
      expect(realtimeCount, equals(1));

      await subscription.cancel();
    });
  });
}
