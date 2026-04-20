import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:spacetimedb_sdk/codegen.dart';

import '../mocks/mock_connection.dart';

void main() {
  group('ReducerCaller - Unit Tests (Deterministic)', () {
    late MockConnection mockConnection;
    late SubscriptionManager subscriptionManager;
    late ReducerCaller reducerCaller;

    setUp(() {
      mockConnection = MockConnection();
      subscriptionManager = SubscriptionManager(mockConnection);
      reducerCaller = subscriptionManager.reducers;
    });

    tearDown(() async {
      await subscriptionManager.dispose();
    });

    group('Test A: ID Correlation Lock', () {
      test('Completes future only when matching request_id returns', () async {
        final future = reducerCaller.call('my_reducer', Uint8List(0));

        expect(mockConnection.sentMessages.length, 1);
        final requestId = mockConnection.getLastSentRequestId();
        expect(requestId, isNotNull);
        expect(requestId, greaterThan(0));

        final wrongIdResponse = _createReducerResult(
          requestId: requestId + 999,
          outcome: _ReducerOutcome.okEmpty,
        );
        expect(
          () => mockConnection.simulateIncoming(wrongIdResponse),
          returnsNormally,
        );

        bool completed = false;
        unawaited(future.then((_) => completed = true));
        await Future.delayed(const Duration(milliseconds: 50));
        expect(completed, isFalse);

        final correctIdResponse = _createReducerResult(
          requestId: requestId,
          outcome: _ReducerOutcome.okEmpty,
        );
        mockConnection.simulateIncoming(correctIdResponse);

        final result = await future;
        expect(result.isSuccess, isTrue);
        expect(result.reducerName, equals('my_reducer'));
      });

      test('Ignores server-initiated reducers (unknown request_id)', () async {
        final serverInitiated = _createReducerResult(
          requestId: 99999,
          outcome: _ReducerOutcome.okEmpty,
        );
        expect(
          () => mockConnection.simulateIncoming(serverInitiated),
          returnsNormally,
        );
      });
    });

    group('Test B: True Concurrency', () {
      test('Handles concurrent requests out of order', () async {
        final futureSlow = reducerCaller.call('slow_reducer', Uint8List(0));
        final futureFast = reducerCaller.call('fast_reducer', Uint8List(0));

        expect(mockConnection.sentMessages.length, 2);
        final idSlow = mockConnection.getSentRequestId(0);
        final idFast = mockConnection.getSentRequestId(1);
        expect(idSlow, isNot(equals(idFast)));

        mockConnection.simulateIncoming(
          _createReducerResult(
            requestId: idFast,
            outcome: _ReducerOutcome.okEmpty,
          ),
        );

        final fastResult = await futureFast;
        expect(fastResult.reducerName, equals('fast_reducer'));

        bool slowDone = false;
        unawaited(futureSlow.then((_) => slowDone = true));
        await Future.delayed(const Duration(milliseconds: 10));
        expect(slowDone, isFalse);

        mockConnection.simulateIncoming(
          _createReducerResult(
            requestId: idSlow,
            outcome: _ReducerOutcome.okEmpty,
          ),
        );

        final slowResult = await futureSlow;
        expect(slowResult.reducerName, equals('slow_reducer'));
      });

      test(
        'Handles 10 concurrent requests with reverse completion order',
        () async {
          final futures = <Future<TransactionResult>>[];
          final expectedIds = <int>[];

          for (int i = 0; i < 10; i++) {
            futures.add(reducerCaller.call('reducer_$i', Uint8List(0)));
            expectedIds.add(mockConnection.getSentRequestId(i));
          }

          for (int i = 9; i >= 0; i--) {
            mockConnection.simulateIncoming(
              _createReducerResult(
                requestId: expectedIds[i],
                outcome: _ReducerOutcome.okEmpty,
              ),
            );
          }

          final results = await Future.wait(futures);
          expect(results.length, 10);
          for (int i = 0; i < 10; i++) {
            expect(results[i].reducerName, equals('reducer_$i'));
          }
        },
      );
    });

    group('Test C: retValue plumbing', () {
      test('Ok(ret_value) surfaces retValue on TransactionResult', () async {
        final future = reducerCaller.call('with_return', Uint8List(0));
        final requestId = mockConnection.getLastSentRequestId();

        final payload = Uint8List.fromList([0xDE, 0xAD, 0xBE, 0xEF]);
        mockConnection.simulateIncoming(
          _createReducerResult(
            requestId: requestId,
            outcome: _ReducerOutcome.okWithReturn,
            retValue: payload,
          ),
        );

        final result = await future;
        expect(result.isSuccess, isTrue);
        expect(result.retValue, equals(payload));
      });

      test('OkEmpty collapses to null retValue', () async {
        final future = reducerCaller.call('unit_return', Uint8List(0));
        final requestId = mockConnection.getLastSentRequestId();

        mockConnection.simulateIncoming(
          _createReducerResult(
            requestId: requestId,
            outcome: _ReducerOutcome.okEmpty,
          ),
        );

        final result = await future;
        expect(result.isSuccess, isTrue);
        expect(result.retValue, isNull);
      });

      test('Ok with zero-length ret_value collapses to null', () async {
        final future = reducerCaller.call('empty_return', Uint8List(0));
        final requestId = mockConnection.getLastSentRequestId();

        mockConnection.simulateIncoming(
          _createReducerResult(
            requestId: requestId,
            outcome: _ReducerOutcome.okWithReturn,
            retValue: Uint8List(0),
          ),
        );

        final result = await future;
        expect(result.isSuccess, isTrue);
        expect(result.retValue, isNull);
      });
    });

    group('Test D: Timeout & Memory Leak Prevention', () {
      test('Times out and cleans up memory', () async {
        final future = reducerCaller.call(
          'timeout_test',
          Uint8List(0),
          timeout: const Duration(milliseconds: 100),
        );

        final requestId = mockConnection.getLastSentRequestId();

        await expectLater(future, throwsA(isA<SpacetimeDbTimeoutException>()));

        final lateResponse = _createReducerResult(
          requestId: requestId,
          outcome: _ReducerOutcome.okEmpty,
        );
        expect(
          () => mockConnection.simulateIncoming(lateResponse),
          returnsNormally,
        );
        await Future.delayed(const Duration(milliseconds: 50));
      });

      test('Timeout includes reducer name in error message', () async {
        final future = reducerCaller.call(
          'specific_reducer_name',
          Uint8List(0),
          timeout: const Duration(milliseconds: 50),
        );
        try {
          await future;
          fail('Should have thrown TimeoutException');
        } on SpacetimeDbTimeoutException catch (e) {
          expect(e.message, contains('specific_reducer_name'));
          expect(e.message, contains('timed out'));
        }
      });

      test('Custom timeout overrides default', () async {
        final future = reducerCaller.call(
          'custom_timeout',
          Uint8List(0),
          timeout: const Duration(seconds: 999),
        );
        final requestId = mockConnection.getLastSentRequestId();
        mockConnection.simulateIncoming(
          _createReducerResult(
            requestId: requestId,
            outcome: _ReducerOutcome.okEmpty,
          ),
        );
        await expectLater(future, completes);
      });
    });

    group('Test E: Connection Loss', () {
      test('Fails all pending requests on connection loss', () async {
        final future1 = reducerCaller.call('req1', Uint8List(0));
        final future2 = reducerCaller.call('req2', Uint8List(0));
        final future3 = reducerCaller.call('req3', Uint8List(0));

        reducerCaller.failAllPendingRequests('WebSocket closed unexpectedly');

        await expectLater(
          future1,
          throwsA(isA<SpacetimeDbConnectionException>()),
        );
        await expectLater(
          future2,
          throwsA(isA<SpacetimeDbConnectionException>()),
        );
        await expectLater(
          future3,
          throwsA(isA<SpacetimeDbConnectionException>()),
        );
      });

      test('Connection loss includes reason in error', () async {
        final future = reducerCaller.call('test', Uint8List(0));
        reducerCaller.failAllPendingRequests('Server returned 502 Bad Gateway');
        try {
          await future;
          fail('Should have thrown SpacetimeDbConnectionException');
        } on SpacetimeDbConnectionException catch (e) {
          expect(e.message, contains('502 Bad Gateway'));
        }
      });
    });

    group('Test F: Error Propagation', () {
      test('Err(Bytes) throws SpacetimeDbReducerException', () async {
        final future = reducerCaller.call('failing_reducer', Uint8List(0));
        final requestId = mockConnection.getLastSentRequestId();

        mockConnection.simulateIncoming(
          _createReducerResult(
            requestId: requestId,
            outcome: _ReducerOutcome.err,
            errBytes: Uint8List.fromList(
              'Validation error: Title too short'.codeUnits,
            ),
          ),
        );

        try {
          await future;
          fail('Should have thrown SpacetimeDbReducerException');
        } on SpacetimeDbReducerException catch (e) {
          expect(e.reducerName, equals('failing_reducer'));
          expect(e.message, contains('Validation error'));
          expect(e.result.isFailed, isTrue);
        }
      });

      test('InternalError throws SpacetimeDbReducerException', () async {
        final future = reducerCaller.call('panicking_reducer', Uint8List(0));
        final requestId = mockConnection.getLastSentRequestId();

        mockConnection.simulateIncoming(
          _createReducerResult(
            requestId: requestId,
            outcome: _ReducerOutcome.internalError,
            errorMessage: 'db panic',
          ),
        );

        try {
          await future;
          fail('Should have thrown SpacetimeDbReducerException');
        } on SpacetimeDbReducerException catch (e) {
          expect(e.reducerName, equals('panicking_reducer'));
          expect(e.message, contains('db panic'));
          expect(e.result.isInternalError, isTrue);
        }
      });
    });

    group('Test G: Race Condition Safety', () {
      test('Timeout and response arriving simultaneously', () async {
        final future = reducerCaller.call(
          'race_test',
          Uint8List(0),
          timeout: const Duration(milliseconds: 100),
        );

        final requestId = mockConnection.getLastSentRequestId();

        await Future.delayed(const Duration(milliseconds: 95));

        mockConnection.simulateIncoming(
          _createReducerResult(
            requestId: requestId,
            outcome: _ReducerOutcome.okEmpty,
          ),
        );

        try {
          final result = await future;
          expect(result.isSuccess, isTrue);
        } on SpacetimeDbTimeoutException {
          // Timeout won — also valid
        }
      });
    });
  });
}

enum _ReducerOutcome { okWithReturn, okEmpty, err, internalError }

/// Encode a v2 `ReducerResult` frame: compression(0) + server tag(6) +
/// requestId(u32) + timestamp(u64) + outcome tag + payload.
Uint8List _createReducerResult({
  required int requestId,
  required _ReducerOutcome outcome,
  Uint8List? retValue,
  Uint8List? errBytes,
  String? errorMessage,
}) {
  final encoder = BsatnEncoder();

  encoder.writeU8(0); // compression: none
  encoder.writeU8(6); // ServerMessageType.reducerResult (v2.rs:175-196)
  encoder.writeU32(requestId);
  encoder.writeU64(Int64(DateTime.now().microsecondsSinceEpoch));

  switch (outcome) {
    case _ReducerOutcome.okWithReturn:
      encoder.writeU8(0); // Ok(ReducerOk)
      final bytes = retValue ?? Uint8List(0);
      encoder.writeU32(bytes.length);
      encoder.writeBytes(bytes);
      encoder.writeU32(0); // empty query_sets
    case _ReducerOutcome.okEmpty:
      encoder.writeU8(1); // OkEmpty (unit)
    case _ReducerOutcome.err:
      encoder.writeU8(2); // Err(Bytes)
      final bytes = errBytes ?? Uint8List(0);
      encoder.writeU32(bytes.length);
      encoder.writeBytes(bytes);
    case _ReducerOutcome.internalError:
      encoder.writeU8(3); // InternalError(Box<str>)
      encoder.writeString(errorMessage ?? 'internal');
  }

  return encoder.toBytes();
}
