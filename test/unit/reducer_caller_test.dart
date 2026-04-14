import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:spacetimedb_dart_sdk/codegen.dart';

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

    group('Test A: ID Correlation Lock', () {
      test('Completes future only when matching request_id returns', () async {
        // 1. Start the call
        final future = reducerCaller.call('my_reducer', Uint8List(0));

        // 2. Verify Request ID in outgoing message
        expect(mockConnection.sentMessages.length, 1);
        final requestId = mockConnection.getLastSentRequestId();
        expect(requestId, isNotNull, reason: 'Must generate a request ID');
        expect(requestId, greaterThan(0), reason: 'ID should be positive');

        // 3. Simulate a response with a WRONG ID (off by 999)
        final wrongIdResponse = _createTransactionUpdate(
          requestId: requestId + 999, // Wrong ID
          status: Committed(),
          reducerName: 'my_reducer',
        );

        // This should NOT crash the SubscriptionManager - just be ignored
        expect(
          () => mockConnection.simulateIncoming(wrongIdResponse),
          returnsNormally,
          reason: 'SubscriptionManager should handle mismatched IDs gracefully',
        );

        // 4. Verify Future is STILL pending (no false positive)
        bool completed = false;
        unawaited(future.then((_) => completed = true));
        await Future.delayed(const Duration(milliseconds: 50));
        expect(
          completed,
          isFalse,
          reason: 'Should ignore mismatched request_id',
        );

        // 5. Simulate response with CORRECT ID
        final correctIdResponse = _createTransactionUpdate(
          requestId: requestId, // Correct ID
          status: Committed(),
          reducerName: 'my_reducer',
        );
        mockConnection.simulateIncoming(correctIdResponse);

        // 6. Verify Completion with correct result
        final result = await future;
        expect(result.isSuccess, isTrue);
        expect(result.reducerName, equals('my_reducer'));
      });

      test('Ignores server-initiated reducers (unknown request_id)', () async {
        // Server sends a TransactionUpdate for a reducer we didn't call
        final serverInitiated = _createTransactionUpdate(
          requestId: 99999, // ID we never sent
          status: Committed(),
          reducerName: 'scheduled_cleanup',
        );

        // Should not throw - just ignore silently
        expect(
          () => mockConnection.simulateIncoming(serverInitiated),
          returnsNormally,
        );
      });
    });

    group('Test B: True Concurrency (Map Logic)', () {
      test('Handles concurrent requests out of order', () async {
        // 1. Fire two requests in quick succession
        final futureSlow = reducerCaller.call('slow_reducer', Uint8List(0));
        final futureFast = reducerCaller.call('fast_reducer', Uint8List(0));

        expect(mockConnection.sentMessages.length, 2);

        final idSlow = mockConnection.getSentRequestId(0);
        final idFast = mockConnection.getSentRequestId(1);

        expect(idSlow, isNot(equals(idFast)), reason: 'IDs must be unique');

        // 2. Complete FAST one first (simulating server reordering)
        final fastResponse = _createTransactionUpdate(
          requestId: idFast,
          status: Committed(),
          reducerName: 'fast_reducer',
        );
        mockConnection.simulateIncoming(fastResponse);

        // 3. Verify Fast is done, Slow is still pending
        final fastResult = await futureFast;
        expect(fastResult.reducerName, equals('fast_reducer'));

        // Check Slow is still waiting
        bool slowDone = false;
        unawaited(futureSlow.then((_) => slowDone = true));
        await Future.delayed(const Duration(milliseconds: 10));
        expect(slowDone, isFalse, reason: 'Slow should still be pending');

        // 4. Complete SLOW one later
        final slowResponse = _createTransactionUpdate(
          requestId: idSlow,
          status: Committed(),
          reducerName: 'slow_reducer',
        );
        mockConnection.simulateIncoming(slowResponse);

        final slowResult = await futureSlow;
        expect(slowResult.reducerName, equals('slow_reducer'));
      });

      test(
        'Handles 10 concurrent requests with random completion order',
        () async {
          // Fire 10 requests
          final futures = <Future<TransactionResult>>[];
          final expectedIds = <int>[];

          for (int i = 0; i < 10; i++) {
            futures.add(reducerCaller.call('reducer_$i', Uint8List(0)));
            expectedIds.add(mockConnection.getSentRequestId(i));
          }

          // Complete them in reverse order (worst case for FIFO)
          for (int i = 9; i >= 0; i--) {
            final response = _createTransactionUpdate(
              requestId: expectedIds[i],
              status: Committed(),
              reducerName: 'reducer_$i',
            );
            mockConnection.simulateIncoming(response);
          }

          // All should complete successfully
          final results = await Future.wait(futures);
          expect(results.length, 10);
          for (int i = 0; i < 10; i++) {
            expect(results[i].reducerName, equals('reducer_$i'));
          }
        },
      );
    });

    group('Test C: Light Update Handling', () {
      test('Handles TransactionUpdateLight correctly', () async {
        final future = reducerCaller.call('test_reducer', Uint8List(0));
        final requestId = mockConnection.getLastSentRequestId();

        // Simulate LIGHT update (minimal data, no reducer metadata)
        final lightResponse = _createTransactionUpdateLight(
          requestId: requestId,
        );
        mockConnection.simulateIncoming(lightResponse);

        final result = await future;

        // Verify light update characteristics
        expect(result.isSuccess, isTrue, reason: 'Light = Committed');
        expect(result.isLightUpdate, isTrue);

        // KEY CHECK: Nullable fields must be null (not 0 or empty)
        expect(
          result.energyConsumed,
          isNull,
          reason: 'Light updates do not provide energy data',
        );
        expect(
          result.executionDuration,
          isNull,
          reason: 'Light updates do not provide duration data',
        );
        expect(
          result.reducerName,
          isNull,
          reason: 'Light updates do not provide reducer metadata',
        );
        expect(result.reducerId, isNull);

        // Timestamp should still be present (approximated client-side)
        expect(result.timestamp, isNotNull);
      });

      test('Mixes full and light updates for different requests', () async {
        final future1 = reducerCaller.call('full_reducer', Uint8List(0));
        final future2 = reducerCaller.call('light_reducer', Uint8List(0));

        final id1 = mockConnection.getSentRequestId(0);
        final id2 = mockConnection.getSentRequestId(1);

        // Respond with LIGHT for first, FULL for second
        mockConnection.simulateIncoming(
          _createTransactionUpdateLight(requestId: id1),
        );
        mockConnection.simulateIncoming(
          _createTransactionUpdate(
            requestId: id2,
            status: Committed(),
            reducerName: 'light_reducer',
            energyConsumed: 42,
            executionDurationMicros: 1500,
          ),
        );

        final result1 = await future1;
        final result2 = await future2;

        // Result1 (light): null fields
        expect(result1.isLightUpdate, isTrue);
        expect(result1.energyConsumed, isNull);

        // Result2 (full): populated fields
        expect(result2.isLightUpdate, isFalse);
        expect(result2.energyConsumed, equals(42));
        expect(result2.executionDuration?.inMicroseconds, equals(1500));
      });
    });

    group('Test D: Timeout & Memory Leak Prevention', () {
      test('Times out and cleans up memory', () async {
        // 1. Call with short timeout
        final future = reducerCaller.call(
          'timeout_test',
          Uint8List(0),
          timeout: const Duration(milliseconds: 100),
        );

        final requestId = mockConnection.getLastSentRequestId();

        // 2. Wait for timeout to fire
        await expectLater(future, throwsA(isA<SpacetimeDbTimeoutException>()));

        // 3. MEMORY CHECK: Send response AFTER timeout
        // If map wasn't cleaned up, this could cause a StateError (double-complete)
        final lateResponse = _createTransactionUpdate(
          requestId: requestId,
          status: Committed(),
          reducerName: 'timeout_test',
        );

        // Should not throw - request was already removed from map
        expect(
          () => mockConnection.simulateIncoming(lateResponse),
          returnsNormally,
        );

        // Give time for any potential async errors
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
        // Set a very long custom timeout (won't actually wait)
        final future = reducerCaller.call(
          'custom_timeout',
          Uint8List(0),
          timeout: const Duration(seconds: 999),
        );

        final requestId = mockConnection.getLastSentRequestId();

        // Complete immediately (should not timeout)
        final response = _createTransactionUpdate(
          requestId: requestId,
          status: Committed(),
          reducerName: 'custom_timeout',
        );
        mockConnection.simulateIncoming(response);

        // Should complete without timeout
        await expectLater(future, completes);
      });
    });

    group('Test E: Connection Loss', () {
      test('Fails all pending requests on connection loss', () async {
        // Start 3 requests
        final future1 = reducerCaller.call('req1', Uint8List(0));
        final future2 = reducerCaller.call('req2', Uint8List(0));
        final future3 = reducerCaller.call('req3', Uint8List(0));

        // Simulate connection loss before any responses
        reducerCaller.failAllPendingRequests('WebSocket closed unexpectedly');

        // All should fail with SpacetimeDbConnectionException
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
      test('Failed reducer throws SpacetimeDbReducerException', () async {
        final future = reducerCaller.call('failing_reducer', Uint8List(0));
        final requestId = mockConnection.getLastSentRequestId();

        final failedResponse = _createTransactionUpdate(
          requestId: requestId,
          status: Failed('Validation error: Title too short'),
          reducerName: 'failing_reducer',
        );
        mockConnection.simulateIncoming(failedResponse);

        try {
          await future;
          fail('Should have thrown SpacetimeDbReducerException');
        } on SpacetimeDbReducerException catch (e) {
          expect(e.reducerName, equals('failing_reducer'));
          expect(e.message, contains('Validation error'));
          expect(e.result.isFailed, isTrue);
        }
      });

      test(
        'OutOfEnergy throws SpacetimeDbReducerException with budget info',
        () async {
          final future = reducerCaller.call('expensive_reducer', Uint8List(0));
          final requestId = mockConnection.getLastSentRequestId();

          final oomResponse = _createTransactionUpdate(
            requestId: requestId,
            status: OutOfEnergy('Budget: 1000, Used: 1200'),
            reducerName: 'expensive_reducer',
          );
          mockConnection.simulateIncoming(oomResponse);

          try {
            await future;
            fail('Should have thrown SpacetimeDbReducerException');
          } on SpacetimeDbReducerException catch (e) {
            expect(e.reducerName, equals('expensive_reducer'));
            expect(e.message, contains('Budget'));
            expect(e.result.isOutOfEnergy, isTrue);
          }
        },
      );
    });

    group('Test G: Race Condition Safety', () {
      test('Timeout and response arriving simultaneously', () async {
        // This tests the atomic remove() safety documented in code
        final future = reducerCaller.call(
          'race_test',
          Uint8List(0),
          timeout: const Duration(milliseconds: 100),
        );

        final requestId = mockConnection.getLastSentRequestId();

        // Wait until just before timeout
        await Future.delayed(const Duration(milliseconds: 95));

        // Fire response at almost the same moment as timeout
        final response = _createTransactionUpdate(
          requestId: requestId,
          status: Committed(),
          reducerName: 'race_test',
        );
        mockConnection.simulateIncoming(response);

        // One of two outcomes should occur:
        // 1. Response wins: future completes successfully
        // 2. Timeout wins: future throws TimeoutException
        // Both are valid - the key is NO double-completion crash
        try {
          final result = await future;
          expect(result.isSuccess, isTrue); // Response won
        } on SpacetimeDbTimeoutException {
          // Timeout won - also valid
        }

        // No StateError = race condition handled correctly
      });
    });
  });
}

// ============================================================================
// Helper Functions to Create Test Messages
// ============================================================================

/// Create a binary-encoded TransactionUpdate message
Uint8List _createTransactionUpdate({
  required int requestId,
  required UpdateStatus status,
  required String reducerName,
  int? energyConsumed,
  int? executionDurationMicros,
}) {
  final encoder = BsatnEncoder();

  // Compression tag (0 = none)
  encoder.writeU8(0);

  // ServerMessage discriminant for TransactionUpdate (1)
  encoder.writeU8(1);

  // UpdateStatus
  if (status is Committed) {
    encoder.writeU8(0); // Committed discriminant
    encoder.writeU32(0); // Empty table updates list (only Committed has this)
  } else if (status is Failed) {
    encoder.writeU8(1); // Failed discriminant
    encoder.writeString(status.message);
    // No table updates list for Failed
  } else if (status is OutOfEnergy) {
    encoder.writeU8(2); // OutOfEnergy discriminant
    encoder.writeString(status.budgetInfo);
    // No table updates list for OutOfEnergy
  }

  // Timestamp (nanoseconds since epoch)
  encoder.writeU64(Int64(DateTime.now().microsecondsSinceEpoch) * Int64(1000));

  // Caller identity (32 bytes, all zeros for test)
  encoder.writeBytes(Uint8List(32));

  // Caller connection ID (16 bytes, all zeros for test)
  encoder.writeBytes(Uint8List(16));

  // ReducerCallInfo
  encoder.writeString(reducerName);
  encoder.writeU32(0); // reducer_id
  encoder.writeU32(0); // args length
  encoder.writeU32(requestId);

  // Energy quanta used (u128 = 16 bytes, little-endian)
  final energyBytes = Uint8List(16);
  final energy = energyConsumed ?? 0;
  energyBytes[0] = energy & 0xFF;
  energyBytes[1] = (energy >> 8) & 0xFF;
  energyBytes[2] = (energy >> 16) & 0xFF;
  energyBytes[3] = (energy >> 24) & 0xFF;
  // Rest of bytes stay 0 for reasonable energy values
  encoder.writeBytes(energyBytes);

  // Execution duration (i64 microseconds, serialized as u64)
  encoder.writeU64(Int64(executionDurationMicros ?? 0));

  return encoder.toBytes();
}

/// Create a binary-encoded TransactionUpdateLight message
Uint8List _createTransactionUpdateLight({required int requestId}) {
  final encoder = BsatnEncoder();

  // Compression tag (0 = none)
  encoder.writeU8(0);

  // ServerMessage discriminant for TransactionUpdateLight (2)
  encoder.writeU8(2);

  // request_id
  encoder.writeU32(requestId);

  // Empty table updates list
  encoder.writeU32(0);

  return encoder.toBytes();
}
