import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:spacetimedb_sdk/protocol.dart';

void main() {
  group('v2 TransactionUpdateMessage', () {
    test('carries only querySets (no reducer metadata)', () {
      final message = TransactionUpdateMessage(querySets: const []);
      expect(message.querySets, isEmpty);
      expect(message.messageType, equals(ServerMessageType.transactionUpdate));
    });

    test('can carry multiple query sets', () {
      final message = TransactionUpdateMessage(
        querySets: [
          QuerySetUpdate(
            querySetId: 1,
            tables: [TableUpdate(tableName: 'notes', rows: const [])],
          ),
          QuerySetUpdate(
            querySetId: 2,
            tables: [TableUpdate(tableName: 'tags', rows: const [])],
          ),
        ],
      );
      expect(message.querySets, hasLength(2));
      expect(message.querySets[0].querySetId, equals(1));
      expect(message.querySets[1].tables.first.tableName, equals('tags'));
    });
  });

  group('v2 ReducerResultMessage status shapes', () {
    test('Committed status', () {
      final message = ReducerResultMessage(
        requestId: 42,
        timestamp: Int64(1_700_000_000_000_000),
        status: Committed(),
        retValue: null,
        querySets: const [],
      );
      expect(message.status, isA<Committed>());
      expect(message.retValue, isNull);
    });

    test('Failed carries UTF-8 error bytes with decoded getter', () {
      final bytes = Uint8List.fromList('boom'.codeUnits);
      final failed = Failed(bytes);
      expect(failed.errorBytes, equals(bytes));
      expect(failed.errorMessage, equals('boom'));
    });

    test('InternalError carries decoded string', () {
      final err = InternalError('db panic');
      expect(err.message, equals('db panic'));
    });
  });

  group('EventContext', () {
    test('wraps UnknownTransactionEvent (v2 remote broadcast)', () {
      final event = UnknownTransactionEvent();
      final context = EventContext(myConnectionId: null, event: event);
      expect(context.event, isA<UnknownTransactionEvent>());
    });

    test('wraps ReducerEvent for caller-side commits', () {
      final event = ReducerEvent(
        timestamp: Int64(123456),
        status: Committed(),
        callerIdentity: Uint8List(32),
        callerConnectionId: Uint8List.fromList([1, 2, 3, 4]),
        reducerName: 'test_reducer',
        reducerArgs: {'key': 'value'},
      );
      final context = EventContext(myConnectionId: null, event: event);
      expect(context.event, isA<ReducerEvent>());
      final ctxEvent = context.event;
      if (ctxEvent is! ReducerEvent) {
        fail('Expected ReducerEvent but got ${ctxEvent.runtimeType}');
      }
      expect(ctxEvent.reducerName, equals('test_reducer'));
      expect(ctxEvent.timestamp, equals(Int64(123456)));
    });
  });

  group('ReducerEvent', () {
    test('preserves identity, args, reducer name', () {
      final callerIdentity = Uint8List(32);
      final event = ReducerEvent(
        timestamp: Int64(987654321),
        status: Committed(),
        callerIdentity: callerIdentity,
        callerConnectionId: Uint8List.fromList([5, 6, 7, 8]),
        reducerName: 'update_note',
        reducerArgs: {'title': 'Updated'},
      );
      expect(event.timestamp, equals(Int64(987654321)));
      expect(event.callerIdentity, equals(callerIdentity));
      expect(event.reducerName, equals('update_note'));
      expect(event.reducerArgs, equals({'title': 'Updated'}));
    });

    test('callerConnectionId is optional', () {
      final event = ReducerEvent(
        timestamp: Int64(123),
        status: Committed(),
        callerIdentity: Uint8List(32),
        callerConnectionId: null,
        reducerName: 'test',
        reducerArgs: {},
      );
      expect(event.callerConnectionId, isNull);
    });
  });

  group('TableCache API exists', () {
    test('TableCache<T> is a live type', () {
      expect(TableCache<String>, isNotNull);
    });
  });
}
