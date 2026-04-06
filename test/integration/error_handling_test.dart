import 'dart:async';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:spacetimedb_dart_sdk/spacetimedb_dart_sdk.dart';
import '../helpers/integration_test_helper.dart';
import '../helpers/test_env.dart';

void main() {
  setUpAll(ensureTestEnvironment);
  tearDownAll(cleanupTestEnvironment);
  late TestEnv env;

  setUp(() async {
    env = await createTestEnv();

    await env.connection.connect();
    await env.subManager.onIdentityToken.first.timeout(
      const Duration(seconds: 5),
    );
  });

  tearDown(() async {
    env.subManager.dispose();
    await env.disconnect();
  });

  group('Error Handling Tests', () {
    test('Non-existent procedure returns internalError', () async {
      const requestId = 1001;

      final resultFuture = env.subManager.onProcedureResult.firstWhere(
        (msg) => msg.requestId == requestId,
      );

      env.subManager.callProcedure(
        'non_existent_procedure',
        Uint8List(0),
        requestId: requestId,
      );

      final result = await resultFuture.timeout(const Duration(seconds: 2));

      expect(result.requestId, equals(requestId));
      expect(result.status.type, equals(ProcedureStatusType.internalError));
      expect(result.status.errorMessage, isNotNull);

      final errorMsg = result.status.errorMessage!.toLowerCase();
      expect(
        errorMsg.contains('not found') ||
            errorMsg.contains('no such procedure'),
        isTrue,
      );
    });

    test('Invalid SQL query returns SubscriptionError', () async {
      const requestId = 1002;
      const queryId = 9999;

      final errorFuture = env.subManager.onSubscriptionError.firstWhere(
        (err) => err.requestId == requestId,
      );

      env.subManager.subscribeSingle(
        'SELECT * FROM non_existent_table',
        requestId: requestId,
        queryId: queryId,
      );

      final error = await errorFuture.timeout(const Duration(seconds: 2));

      expect(error.requestId, equals(requestId));
      expect(error.queryId, equals(queryId));
      expect(error.error, isNotEmpty);

      final errorMsg = error.error.toLowerCase();
      expect(
        errorMsg.contains('table') ||
            errorMsg.contains('not found') ||
            errorMsg.contains('does not exist'),
        isTrue,
      );
    });

    test('Unsubscribe non-existent subscription returns error', () async {
      const requestId = 1003;
      const queryId = 88888;

      final errorFuture = env.subManager.onSubscriptionError.firstWhere(
        (err) => err.requestId == requestId,
      );

      env.subManager.unsubscribe(queryId, requestId: requestId);

      final error = await errorFuture.timeout(const Duration(seconds: 2));

      expect(error.requestId, equals(requestId));
      expect(error.queryId, equals(queryId));
      expect(error.error, isNotEmpty);

      final errorMsg = error.error.toLowerCase();
      expect(
        errorMsg.contains('subscription not found') ||
            errorMsg.contains('not found'),
        isTrue,
      );
    });

    test('Invalid reducer arguments are handled', () async {
      final encoder = BsatnEncoder();
      final future = env.subManager.reducers.call(
        'create_note',
        encoder.toBytes(),
        timeout: const Duration(milliseconds: 200),
      );

      await expectLater(future, throwsA(isA<TimeoutException>()));

      expect(env.connection.isConnected, isTrue);
    });

    test('Procedure with wrong argument types', () async {
      const requestId = 1005;

      final resultFuture = env.subManager.onProcedureResult.firstWhere(
        (msg) => msg.requestId == requestId,
      );

      final encoder = BsatnEncoder();
      encoder.writeString('not a number');
      encoder.writeString('also not a number');

      env.subManager.callProcedure(
        'add_numbers',
        encoder.toBytes(),
        requestId: requestId,
      );

      final result = await resultFuture.timeout(const Duration(seconds: 2));

      expect(result.requestId, equals(requestId));
      expect(result.status.type, isA<ProcedureStatusType>());
    });

    test('Procedure panic (divide by zero) returns internalError', () async {
      const requestId = 1006;

      final resultFuture = env.subManager.onProcedureResult.firstWhere(
        (msg) => msg.requestId == requestId,
      );

      final encoder = BsatnEncoder();
      encoder.writeU32(100);

      env.subManager.callProcedure(
        'divide_by_zero',
        encoder.toBytes(),
        requestId: requestId,
      );

      final result = await resultFuture.timeout(const Duration(seconds: 2));

      expect(result.requestId, equals(requestId));
      expect(result.status.type, equals(ProcedureStatusType.internalError));
      expect(result.status.errorMessage, isNotNull);

      final errorMsg = result.status.errorMessage!.toLowerCase();
      expect(errorMsg.contains('divide') || errorMsg.contains('panic'), isTrue);
    });
  });
}
