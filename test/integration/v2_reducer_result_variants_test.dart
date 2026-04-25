import 'package:test/test.dart';
import 'package:spacetimedb_sdk/codegen.dart';

import '../helpers/integration_test_helper.dart';
import '../helpers/test_env.dart';

/// v2 ReducerResult outcome coverage. Slice 4 wires four `ReducerOutcome`
/// tags: Ok(ReducerOk), OkEmpty, Err(Bytes), InternalError(str). SpaceNotes
/// soak only exercised the success paths in steady state — these tests pin
/// the remaining variants against the live wire before 2.0.0 ships.
void main() {
  setUpAll(ensureTestEnvironment);
  tearDownAll(cleanupTestEnvironment);

  late TestEnv env;

  setUp(() async {
    env = await createTestEnv();
    final ready = env.subManager.onInitialConnection.first;
    await env.connection.connect();
    await ready.timeout(const Duration(seconds: 10));
  });

  tearDown(() async {
    env.subManager.dispose();
    await env.disconnect();
  });

  group('v2 ReducerResult variants', () {
    test('Err(Bytes) — reducer returning Err surfaces as exception with '
        'round-tripped message and Failed status', () async {
      const errorMessage = 'reducer rejected for test reasons';
      final encoder = BsatnEncoder();
      encoder.writeString(errorMessage);

      try {
        await env.subManager.reducers
            .call('reducer_returns_err', encoder.toBytes())
            .timeout(const Duration(seconds: 5));
        fail('expected SpacetimeDbReducerException');
      } on SpacetimeDbReducerException catch (e) {
        expect(e.reducerName, equals('reducer_returns_err'));
        expect(
          e.message,
          contains(errorMessage),
          reason:
              'errorBytes → errorMessage decode must round-trip the server '
              'string verbatim',
        );
        expect(
          e.result.status,
          isA<Failed>(),
          reason: 'reducer body Err(...) maps to v2 Failed(Bytes) outcome',
        );
        final failed = e.result.status as Failed;
        expect(failed.errorMessage, contains(errorMessage));
      }
    });

    test('InternalError(str) — panicking reducer surfaces as exception with '
        'InternalError status', () async {
      try {
        await env.subManager.reducers
            .call('reducer_that_panics', BsatnEncoder().toBytes())
            .timeout(const Duration(seconds: 5));
        fail('expected SpacetimeDbReducerException');
      } on SpacetimeDbReducerException catch (e) {
        expect(e.reducerName, equals('reducer_that_panics'));
        expect(
          e.result.status,
          isA<InternalError>(),
          reason:
              'panic in reducer body maps to v2 InternalError(str) outcome, '
              'distinct from Failed which is reserved for explicit Err returns',
        );
        final internal = e.result.status as InternalError;
        expect(
          internal.message,
          isNotEmpty,
          reason: 'server fills InternalError with a non-empty diagnostic',
        );
        // The server scrubs the original panic message and replaces it with
        // a generic "fatal error" string before sending. This is upstream
        // behaviour (privacy / not leaking module internals to clients) —
        // pin the contract so we notice if it ever changes.
        expect(
          internal.message.toLowerCase(),
          contains('fatal error'),
          reason:
              'server replaces the original panic text with a generic '
              '"fatal error" diagnostic — original message does NOT reach '
              'the client. Verified against SpacetimeDB 2026-04-25.',
        );
      }
    });

    test(
      'Ok / OkEmpty — unit-return reducer collapses to retValue: null',
      () async {
        // `no_op` is a unit-return reducer (`fn no_op(_ctx) {}`). v2 server
        // emits OkEmpty for unit returns; slice 4 collapses both OkEmpty and
        // zero-length Ok.ret_value to `retValue: null` on TransactionResult.
        final result = await env.subManager.reducers
            .call('no_op', BsatnEncoder().toBytes())
            .timeout(const Duration(seconds: 5));

        expect(result.status, isA<Committed>());
        expect(result.reducerName, equals('no_op'));
        expect(
          result.retValue,
          isNull,
          reason:
              'OkEmpty (and zero-length Ok.ret_value) both collapse to '
              'retValue: null per slice 4 contract',
        );
      },
    );
  });
}
