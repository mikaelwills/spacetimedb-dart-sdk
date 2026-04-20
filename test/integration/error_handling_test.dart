import 'dart:async';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:spacetimedb_sdk/codegen.dart';
import 'package:spacetimedb_sdk/protocol.dart';
import '../helpers/integration_test_helper.dart';
import '../helpers/test_env.dart';

void main() {
  setUpAll(ensureTestEnvironment);
  tearDownAll(cleanupTestEnvironment);
  late TestEnv env;

  setUp(() async {
    env = await createTestEnv();

    await env.connection.connect();
    await env.subManager.onInitialConnection.first.timeout(
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
      final errorFuture = env.subManager.onSubscriptionError.first;

      unawaited(
        env.subManager
            .subscribe(['SELECT * FROM non_existent_table'])
            .catchError((_) => 0),
      );

      final error = await errorFuture.timeout(const Duration(seconds: 2));

      expect(error.querySetId, isA<int>());
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
      const fakeQuerySetId = 88888;

      final errorFuture = env.subManager.onSubscriptionError.firstWhere(
        (err) => err.requestId == requestId,
      );

      env.subManager.unsubscribe(fakeQuerySetId, requestId: requestId);

      final error = await errorFuture.timeout(const Duration(seconds: 2));

      expect(error.requestId, equals(requestId));
      expect(error.querySetId, equals(fakeQuerySetId));
      expect(error.error, isNotEmpty);

      final errorMsg = error.error.toLowerCase();
      expect(
        errorMsg.contains('subscription not found') ||
            errorMsg.contains('not found'),
        isTrue,
      );
    });

    test(
      'Invalid reducer arguments surface as SpacetimeDbReducerException',
      () async {
        // Under v2, the server sends `ReducerResult` with `InternalError(...)`
        // carrying the caller's request_id, so the pending future is resolved
        // to an exception rather than timing out. (Under v1 the protocol-level
        // failure used request_id=0 and the call sat until the client-side
        // timeout.)
        final encoder = BsatnEncoder();
        final future = env.subManager.reducers.call(
          'create_note',
          encoder.toBytes(),
        );

        await expectLater(
          future,
          throwsA(
            isA<SpacetimeDbReducerException>().having(
              (e) => e.message,
              'message',
              contains('invalid arguments'),
            ),
          ),
        );

        expect(env.connection.isConnected, isTrue);
      },
    );

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
