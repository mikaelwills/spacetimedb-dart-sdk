import 'dart:async';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:spacetimedb_dart_sdk/spacetimedb_dart_sdk.dart';
import '../generated/note.dart';
import '../helpers/integration_test_helper.dart';
import '../helpers/test_env.dart';

void main() {
  setUpAll(ensureTestEnvironment);
  tearDownAll(cleanupTestEnvironment);
  late TestEnv env;
  late SpacetimeDbConnection connection;
  late SubscriptionManager subManager;

  setUp(() async {
    env = await createTestEnv();
    connection = env.connection;
    subManager = env.subManager;

    await connection.connect();
    await subManager.onIdentityToken.first.timeout(const Duration(seconds: 5));
  });

  tearDown(() async {
    subManager.dispose();
    await env.disconnect();
  });

  group('Server Message Type Tests', () {
    test('IdentityToken message', () async {
      // Create a new connection to receive a fresh IdentityToken
      final newConnection = SpacetimeDbConnection(
        host: 'localhost:3000',
        database: 'notesdb',
      );
      final newSubManager = SubscriptionManager(newConnection);

      // A. PREPARE LISTENER - before connecting
      final tokenFuture = newSubManager.onIdentityToken.first;

      // B. ACTION - connect to trigger IdentityToken
      await newConnection.connect();

      // C. WAIT
      final token = await tokenFuture.timeout(const Duration(seconds: 2));

      // D. ASSERT
      expect(
        token.identity.length,
        equals(32),
        reason: 'Identity should be 32 bytes',
      );
      expect(
        token.connectionId.length,
        equals(16),
        reason: 'Connection ID should be 16 bytes',
      );
      expect(token.token, isNotEmpty, reason: 'Token should not be empty');

      // Clean up
      newSubManager.dispose();
      await newConnection.disconnect();
    });

    test('InitialSubscription message', () async {
      // A. PREPARE LISTENER
      final initialSubFuture = subManager.onInitialSubscription.first;

      // B. ACTION - use subscribe() to properly track table activation
      subManager.subscribe(['SELECT * FROM note']);

      // C. WAIT
      final initialSub = await initialSubFuture.timeout(
        const Duration(seconds: 2),
      );

      // D. ASSERT
      // Note: tableUpdates can be empty if the table has no rows
      // The server only includes tables with data in tableUpdates
      expect(
        initialSub.tableUpdates,
        isNotNull,
        reason: 'Should have tableUpdates list (may be empty)',
      );
      expect(
        initialSub.requestId,
        isA<int>(),
        reason: 'Request ID should be present',
      );
      expect(
        initialSub.totalHostExecutionDurationMicros,
        greaterThanOrEqualTo(0),
        reason: 'Execution duration should be non-negative',
      );

      // Verify cache was populated (even if table is empty)
      // The SDK activates empty tables automatically when using subscribe()
      final noteTable = subManager.cache.getTableByTypedName<Note>('note');
      expect(
        noteTable,
        isNotNull,
        reason: 'Note table should be in cache (even if empty)',
      );
    });

    test('TransactionUpdate message', () async {
      // Ensure we have initial subscription first
      subManager.subscribe(['SELECT * FROM note']);
      await subManager.onInitialSubscription.first;

      final noteTable = subManager.cache.getTableByTypedName<Note>('note');
      final noteCountBefore = noteTable.count();

      // A. PREPARE LISTENER
      final txUpdateFuture = subManager.onTransactionUpdate.first;

      // B. ACTION
      await env.reducers.createNote(
        title: 'TransactionUpdate Test',
        content: 'Testing TransactionUpdate message',
      );

      // C. WAIT
      final txUpdate = await txUpdateFuture.timeout(const Duration(seconds: 2));

      // D. ASSERT
      expect(
        txUpdate.timestamp,
        greaterThan(0),
        reason: 'Timestamp should be positive',
      );
      expect(
        txUpdate.tableUpdates,
        isNotEmpty,
        reason: 'Should have table updates',
      );
      expect(
        txUpdate.status,
        isA<Committed>(),
        reason: 'Transaction should be committed',
      );

      final noteCountAfter = noteTable.count();
      expect(
        noteCountAfter,
        equals(noteCountBefore + 1),
        reason: 'Note count should increase by 1',
      );
    });

    test('OneOffQueryResponse message', () async {
      // A. PREPARE LISTENER
      final queryResponseFuture = subManager.onOneOffQueryResponse.first;

      // B. ACTION
      final messageId = Uint8List.fromList([1, 2, 3, 4]);
      subManager.oneOffQuery(messageId, 'SELECT * FROM note');

      // C. WAIT
      final queryResponse = await queryResponseFuture.timeout(
        const Duration(seconds: 2),
      );

      // D. ASSERT
      expect(
        queryResponse.messageId,
        equals(messageId),
        reason: 'Message ID should match',
      );
      expect(
        queryResponse.error,
        isNull,
        reason: 'Should not have error for valid query',
      );
      expect(queryResponse.tables, isNotEmpty, reason: 'Should have tables');
      expect(
        queryResponse.totalHostExecutionDurationMicros,
        greaterThanOrEqualTo(0),
        reason: 'Execution duration should be non-negative',
      );
    });

    test('SubscribeApplied message', () async {
      const requestId = 100;
      const queryId = 123;

      // A. PREPARE LISTENER
      final subscribeAppliedFuture = subManager.onSubscribeApplied.first;

      // B. ACTION
      subManager.subscribeSingle(
        'SELECT * FROM note',
        requestId: requestId,
        queryId: queryId,
      );

      // C. WAIT
      final subscribeApplied = await subscribeAppliedFuture.timeout(
        const Duration(seconds: 2),
      );

      // D. ASSERT
      expect(
        subscribeApplied.requestId,
        equals(requestId),
        reason: 'Request ID should match',
      );
      expect(
        subscribeApplied.queryId,
        equals(queryId),
        reason: 'Query ID should match',
      );
      expect(
        subscribeApplied.totalHostExecutionDurationMicros,
        greaterThanOrEqualTo(0),
        reason: 'Execution duration should be non-negative',
      );
    });

    test('UnsubscribeApplied message', () async {
      const subscribeRequestId = 200;
      const queryId = 456;
      const unsubscribeRequestId = 201;

      // First, create a subscription
      subManager.subscribeSingle(
        'SELECT * FROM note',
        requestId: subscribeRequestId,
        queryId: queryId,
      );
      await subManager.onSubscribeApplied.first.timeout(
        const Duration(seconds: 2),
      );

      // A. PREPARE LISTENER
      final unsubAppliedFuture = subManager.onUnsubscribeApplied.first;

      // B. ACTION
      subManager.unsubscribe(queryId, requestId: unsubscribeRequestId);

      // C. WAIT
      final unsubApplied = await unsubAppliedFuture.timeout(
        const Duration(seconds: 2),
      );

      // D. ASSERT
      expect(
        unsubApplied.requestId,
        equals(unsubscribeRequestId),
        reason: 'Request ID should match',
      );
      expect(
        unsubApplied.queryId,
        equals(queryId),
        reason: 'Query ID should match',
      );
      expect(
        unsubApplied.totalHostExecutionDurationMicros,
        greaterThanOrEqualTo(0),
        reason: 'Execution duration should be non-negative',
      );
    });

    test('SubscriptionError message', () async {
      const requestId = 500;
      const queryId = 99999;

      // A. PREPARE LISTENER
      final errorFuture = subManager.onSubscriptionError.first;

      // B. ACTION - try to unsubscribe from non-existent subscription
      subManager.unsubscribe(queryId, requestId: requestId);

      // C. WAIT
      final subError = await errorFuture.timeout(const Duration(seconds: 2));

      // D. ASSERT
      expect(
        subError.requestId,
        equals(requestId),
        reason: 'Request ID should match',
      );
      expect(
        subError.queryId,
        equals(queryId),
        reason: 'Query ID should match',
      );
      expect(
        subError.error,
        isNotEmpty,
        reason: 'Error message should not be empty',
      );
      expect(
        subError.totalHostExecutionDurationMicros,
        greaterThanOrEqualTo(0),
        reason: 'Execution duration should be non-negative',
      );

      final errorMsg = subError.error.toLowerCase();
      expect(
        errorMsg.contains('subscription not found') ||
            errorMsg.contains('not found'),
        isTrue,
        reason: 'Error should indicate subscription not found',
      );
    });

    test('ProcedureResult message', () async {
      const requestId = 600;

      // A. PREPARE LISTENER
      final procedureResultFuture = subManager.onProcedureResult.first;

      // B. ACTION - call add_numbers(42, 58)
      final encoder = BsatnEncoder();
      encoder.writeU32(42);
      encoder.writeU32(58);
      subManager.callProcedure(
        'add_numbers',
        encoder.toBytes(),
        requestId: requestId,
      );

      // C. WAIT
      final procedureResult = await procedureResultFuture.timeout(
        const Duration(seconds: 2),
      );

      // D. ASSERT
      expect(
        procedureResult.requestId,
        equals(requestId),
        reason: 'Request ID should match',
      );
      expect(
        procedureResult.status.type,
        equals(ProcedureStatusType.returned),
        reason: 'Procedure should return successfully',
      );
      expect(
        procedureResult.timestamp,
        greaterThan(0),
        reason: 'Timestamp should be positive',
      );
      expect(
        procedureResult.totalHostExecutionDurationMicros,
        greaterThanOrEqualTo(0),
        reason: 'Execution duration should be non-negative',
      );

      // Verify return value
      expect(
        procedureResult.status.returnedData,
        isNotNull,
        reason: 'Should have returned data',
      );

      final decoder = BsatnDecoder(procedureResult.status.returnedData!);
      final result = decoder.readU32();
      expect(result, equals(100), reason: '42 + 58 should equal 100');
    });

    test('TransactionUpdateLight or TransactionUpdate message', () async {
      // Ensure we have initial subscription first
      final initialSubFuture = subManager.onInitialSubscription.first;
      await subManager.subscribe(['SELECT * FROM note']);
      await initialSubFuture;

      final noteTable = subManager.cache.getTableByTypedName<Note>('note');
      final noteCountBefore = noteTable.count();

      // A. PREPARE LISTENER - race between Light and Full
      final updateCompleter = Completer<String>();

      final lightSub = subManager.onTransactionUpdateLight.listen((light) {
        if (!updateCompleter.isCompleted) {
          updateCompleter.complete('light');
        }
      });

      final fullSub = subManager.onTransactionUpdate.listen((full) {
        if (!updateCompleter.isCompleted) {
          updateCompleter.complete('full');
        }
      });

      // B. ACTION
      await env.reducers.createNote(
        title: 'Light Update Test',
        content: 'May receive Light or Full TransactionUpdate',
      );

      // C. WAIT
      final updateType = await updateCompleter.future.timeout(
        const Duration(seconds: 2),
      );

      // D. ASSERT - either type is valid
      expect(
        updateType,
        anyOf(['light', 'full']),
        reason: 'Should receive either Light or Full update',
      );

      // Verify state changed
      final noteCountAfter = noteTable.count();
      expect(
        noteCountAfter,
        equals(noteCountBefore + 1),
        reason: 'Note count should increase by 1',
      );

      // Clean up
      await lightSub.cancel();
      await fullSub.cancel();
    });

    test('SubscribeMultiApplied message', () async {
      const requestId = 700;
      const queryId = 789;

      // A. PREPARE LISTENER
      final subscribeMultiFuture = subManager.onSubscribeMultiApplied.first;

      // B. ACTION
      subManager.subscribeMulti(
        [
          'SELECT * FROM note WHERE id > 50',
          'SELECT * FROM note WHERE id <= 50',
        ],
        requestId: requestId,
        queryId: queryId,
      );

      // C. WAIT
      final subscribeMultiApplied = await subscribeMultiFuture.timeout(
        const Duration(seconds: 2),
      );

      // D. ASSERT
      expect(
        subscribeMultiApplied.requestId,
        equals(requestId),
        reason: 'Request ID should match',
      );
      expect(
        subscribeMultiApplied.queryId,
        equals(queryId),
        reason: 'Query ID should match',
      );
      expect(
        subscribeMultiApplied.tableUpdates,
        isNotEmpty,
        reason: 'Should have table updates',
      );
      expect(
        subscribeMultiApplied.totalHostExecutionDurationMicros,
        greaterThanOrEqualTo(0),
        reason: 'Execution duration should be non-negative',
      );
    });

    test('UnsubscribeMultiApplied message', () async {
      const subscribeRequestId = 800;
      const queryId = 890;
      const unsubscribeRequestId = 801;

      // First, create a multi subscription
      subManager.subscribeMulti(
        ['SELECT * FROM note'],
        requestId: subscribeRequestId,
        queryId: queryId,
      );
      await subManager.onSubscribeMultiApplied.first.timeout(
        const Duration(seconds: 2),
      );

      // A. PREPARE LISTENER
      final unsubMultiFuture = subManager.onUnsubscribeMultiApplied.first;

      // B. ACTION
      subManager.unsubscribeMulti(queryId, requestId: unsubscribeRequestId);

      // C. WAIT
      final unsubscribeMultiApplied = await unsubMultiFuture.timeout(
        const Duration(seconds: 2),
      );

      // D. ASSERT
      expect(
        unsubscribeMultiApplied.requestId,
        equals(unsubscribeRequestId),
        reason: 'Request ID should match',
      );
      expect(
        unsubscribeMultiApplied.queryId,
        equals(queryId),
        reason: 'Query ID should match',
      );
      expect(
        unsubscribeMultiApplied.tableUpdates,
        isNotNull,
        reason: 'Should have table updates',
      );
      expect(
        unsubscribeMultiApplied.totalHostExecutionDurationMicros,
        greaterThanOrEqualTo(0),
        reason: 'Execution duration should be non-negative',
      );
    });
  });
}
