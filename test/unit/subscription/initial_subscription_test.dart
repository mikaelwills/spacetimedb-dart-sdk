import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:spacetimedb_sdk/codegen.dart';
import 'package:spacetimedb_sdk/protocol.dart';

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
      table = TableCache<String>(tableName: 'test', decoder: MockDecoder());
    });

    test('applyInitialData accepts EventContext parameter', () {
      final event = SubscribeAppliedEvent();
      final context = EventContext(myConnectionId: null, event: event);

      final encoder = BsatnEncoder();
      encoder.writeString('test');
      final inserts = BsatnRowList(
        sizeHint: RowSizeHint.fixedSize(encoder.toBytes().length),
        rowsData: encoder.toBytes(),
      );

      expect(() => table.applyInitialData(inserts, context), returnsNormally);
    });

    test(
      'applyInitialData emits events with SubscribeAppliedEvent context',
      () {
        final subscribeEvent = SubscribeAppliedEvent();
        final context = EventContext(
          myConnectionId: null,
          event: subscribeEvent,
        );

        final encoder = BsatnEncoder();
        encoder.writeString('test');
        final inserts = BsatnRowList(
          sizeHint: RowSizeHint.fixedSize(encoder.toBytes().length),
          rowsData: encoder.toBytes(),
        );
        table.applyInitialData(inserts, context);

        final batch = table.lastBatch.value;
        expect(batch, isNotNull);
        expect(batch!.length, equals(1));
        expect(batch.events.first, isA<TableInsertEvent<String>>());
        expect(batch.context.event, isA<SubscribeAppliedEvent>());
      },
    );

    test('users can distinguish initial data from reducer updates', () {
      bool sawInitial = false;
      bool sawReducer = false;

      table.lastBatch.addListener(() {
        final batch = table.lastBatch.value;
        if (batch == null) return;
        for (final event in batch.events) {
          if (event is TableInsertEvent<String>) {
            if (event.context.event is SubscribeAppliedEvent) {
              sawInitial = true;
            } else if (event.context.event is ReducerEvent) {
              sawReducer = true;
            }
          }
        }
      });

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

      expect(sawInitial, isTrue);
      expect(sawReducer, isTrue);
    });

    test(
      'multiple rows in initial subscription all have SubscribeAppliedEvent',
      () {
        final capturedEvents = <Event>[];

        table.lastBatch.addListener(() {
          final batch = table.lastBatch.value;
          if (batch == null) return;
          for (final event in batch.events) {
            if (event is TableInsertEvent<String>) {
              capturedEvents.add(event.context.event);
            }
          }
        });

        final subscribeContext = EventContext(
          myConnectionId: null,
          event: SubscribeAppliedEvent(),
        );

        final encodedRows = <Uint8List>[];
        for (var i = 0; i < 3; i++) {
          final encoder = BsatnEncoder();
          encoder.writeString('row_$i');
          encodedRows.add(encoder.toBytes());
        }

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

        expect(capturedEvents.length, equals(3));
        for (final event in capturedEvents) {
          expect(event, isA<SubscribeAppliedEvent>());
        }
      },
    );

    test('unified lastBatch receives SubscribeAppliedEvent inserts', () {
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

      final batch = table.lastBatch.value;
      expect(batch, isNotNull);
      expect(batch!.events.first, isA<TableInsertEvent<String>>());
      expect(batch.context.event, isA<SubscribeAppliedEvent>());
    });

    test('pattern matching distinguishes event types', () {
      bool sawInitial = false;
      bool sawRealtime = false;

      table.lastBatch.addListener(() {
        final batch = table.lastBatch.value;
        if (batch == null) return;
        for (final event in batch.events) {
          if (event is TableInsertEvent<String>) {
            switch (event.context.event) {
              case SubscribeAppliedEvent():
                sawInitial = true;
              case ReducerEvent():
                sawRealtime = true;
              case UnknownTransactionEvent():
              case OptimisticEvent():
                break;
            }
          }
        }
      });

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

      expect(sawInitial, isTrue);
      expect(sawRealtime, isTrue);
    });
  });

  group('Phase 6: Integration Patterns', () {
    test('convenience filter: only initial data', () {
      final table = TableCache<String>(
        tableName: 'test',
        decoder: MockDecoder(),
      );

      var initialDataCount = 0;

      table.lastBatch.addListener(() {
        final batch = table.lastBatch.value;
        if (batch == null) return;
        for (final event in batch.events) {
          if (event is TableInsertEvent<String> &&
              event.context.event is SubscribeAppliedEvent) {
            initialDataCount++;
          }
        }
      });

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

      expect(initialDataCount, equals(1));
    });

    test('convenience filter: skip initial data load', () {
      final table = TableCache<String>(
        tableName: 'test',
        decoder: MockDecoder(),
      );

      var realtimeCount = 0;

      table.lastBatch.addListener(() {
        final batch = table.lastBatch.value;
        if (batch == null) return;
        for (final event in batch.events) {
          if (event is TableInsertEvent<String> &&
              event.context.event is! SubscribeAppliedEvent) {
            realtimeCount++;
          }
        }
      });

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

      expect(realtimeCount, equals(1));
    });
  });
}
