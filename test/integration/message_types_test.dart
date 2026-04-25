import 'package:test/test.dart';
import 'package:spacetimedb_sdk/codegen.dart';
import 'package:spacetimedb_sdk/protocol.dart';
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
    await subManager.onInitialConnection.first.timeout(
      const Duration(seconds: 5),
    );
  });

  tearDown(() async {
    subManager.dispose();
    await env.disconnect();
  });

  group('v2 ServerMessage shapes', () {
    test(
      'InitialConnection carries identity + connection_id + token',
      () async {
        final newConnection = SpacetimeDbConnection(
          host: 'localhost:3000',
          database: 'notesdb',
        );
        final newSubManager = SubscriptionManager(newConnection);

        final initialFuture = newSubManager.onInitialConnection.first;

        await newConnection.connect();

        final initial = await initialFuture.timeout(const Duration(seconds: 2));

        expect(initial.identity.length, equals(32));
        expect(initial.connectionId.length, equals(16));
        expect(initial.token, isNotEmpty);

        newSubManager.dispose();
        await newConnection.disconnect();
      },
    );

    test(
      'SubscribeApplied delivers initial rows keyed by querySetId',
      () async {
        final subscribeAppliedFuture = subManager.onSubscribeApplied.first;

        final querySetId = await subManager.subscribe(['SELECT * FROM note']);

        final subscribeApplied = await subscribeAppliedFuture.timeout(
          const Duration(seconds: 5),
        );

        expect(subscribeApplied.querySetId, equals(querySetId));
        expect(subscribeApplied.requestId, isA<int>());
        expect(subscribeApplied.rows.tables, isNotNull);

        final noteTable = subManager.cache.getTableByTypedName<Note>('note');
        expect(noteTable, isNotNull);
      },
    );

    test('ReducerResult carries the caller\'s commit + row updates', () async {
      await subManager.subscribe(['SELECT * FROM note']);

      final noteTable = subManager.cache.getTableByTypedName<Note>('note');
      final noteCountBefore = noteTable.count();

      final reducerResultFuture = subManager.onReducerResult.first;

      await env.reducers.createNote(
        title: 'ReducerResult Test',
        content: 'Caller-side commit via v2 ReducerResult',
      );

      final reducerResult = await reducerResultFuture.timeout(
        const Duration(seconds: 5),
      );

      expect(reducerResult.status, isA<Committed>());
      expect(reducerResult.querySets, isNotEmpty);

      final noteCountAfter = noteTable.count();
      expect(noteCountAfter, equals(noteCountBefore + 1));
    });

    test('OneOffQueryResult returns Ok(QueryRows) for a valid query', () async {
      final resultFuture = subManager.onOneOffQueryResult.first;

      subManager.oneOffQuery('SELECT * FROM note', requestId: 42);

      final result = await resultFuture.timeout(const Duration(seconds: 2));

      expect(result.requestId, equals(42));
      expect(result.error, isNull);
      expect(result.rows, isNotNull);
      expect(result.rows!.tables, isNotEmpty);
    });

    test('UnsubscribeApplied matches the assigned querySetId', () async {
      final querySetId = await subManager.subscribe(['SELECT * FROM note']);

      final unsubAppliedFuture = subManager.onUnsubscribeApplied.first;

      subManager.unsubscribe(querySetId, requestId: 201);

      final unsubApplied = await unsubAppliedFuture.timeout(
        const Duration(seconds: 2),
      );

      expect(unsubApplied.requestId, equals(201));
      expect(unsubApplied.querySetId, equals(querySetId));
      expect(
        unsubApplied.rows,
        isNull,
        reason: 'default flag = no dropped-row payload',
      );
    });

    test('SubscriptionError surfaces the querySetId for a bad query', () async {
      final errorFuture = subManager.onSubscriptionError.first;

      try {
        await subManager
            .subscribe(['SELECT * FROM __nonexistent_table__'])
            .timeout(const Duration(seconds: 2));
      } catch (_) {
        // subscribe() awaits SubscribeApplied; on error the server sends
        // SubscriptionError instead. We'll assert on the error stream.
      }

      final subError = await errorFuture.timeout(const Duration(seconds: 2));
      expect(subError.error, isNotEmpty);
      expect(subError.querySetId, isA<int>());
    });

    test('ProcedureResult returns bytes for a procedure call', () async {
      final procedureResultFuture = subManager.onProcedureResult.first;

      final encoder = BsatnEncoder();
      encoder.writeU32(42);
      encoder.writeU32(58);
      subManager.callProcedure(
        'add_numbers',
        encoder.toBytes(),
        requestId: 600,
      );

      final procedureResult = await procedureResultFuture.timeout(
        const Duration(seconds: 5),
      );

      expect(procedureResult.requestId, equals(600));
      expect(procedureResult.status.type, equals(ProcedureStatusType.returned));
      expect(procedureResult.status.returnedData, isNotNull);

      final decoder = BsatnDecoder(procedureResult.status.returnedData!);
      final result = decoder.readU32();
      expect(result, equals(100));
    });
  });
}
