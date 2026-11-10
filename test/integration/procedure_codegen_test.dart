import 'dart:async';

import 'package:spacetimedb_sdk/codegen.dart';
import 'package:spacetimedb_sdk/src/utils/sdk_logger.dart';
import 'package:test/test.dart';

import '../generated/client.dart';
import '../generated/note_status.dart';
import '../helpers/integration_test_helper.dart';

void main() {
  late SpacetimeDbClient client;

  setUpAll(() async {
    SdkLogger.level = SdkLogLevel.none;
    await ensureTestEnvironment();
  });
  tearDownAll(cleanupTestEnvironment);

  setUp(() async {
    client = await SpacetimeDbClient.create(
      host: 'localhost:3000',
      database: 'notesdb',
    );
    await client.connect(initialSubscriptions: const []);
  });

  tearDown(() async {
    await client.connection.disconnect();
  });

  test('a primitive procedure returns its decoded value', () async {
    expect(await client.procedures.addNumbers(a: 2, b: 40), 42);
  });

  test('concurrent calls each get their own result', () async {
    final results = await Future.wait([
      for (var i = 0; i < 20; i++) client.procedures.addNumbers(a: i, b: 1000),
    ]);

    expect(results, [for (var i = 0; i < 20; i++) i + 1000]);
  });

  test('a custom sum type round-trips through args and return', () async {
    final result = await client.procedures.echoStatus(
      status: NoteStatusPublished(Int64(1234)),
    );

    expect(
      result,
      isA<NoteStatusPublished>().having((s) => s.value, 'value', Int64(1234)),
    );
    expect(
      await client.procedures.echoStatus(status: const NoteStatusArchived()),
      isA<NoteStatusArchived>(),
    );
  });

  test('an Option return decodes both Some and None', () async {
    expect(await client.procedures.maybeGreeting(name: 'ada'), 'hello ada');
    expect(await client.procedures.maybeGreeting(name: null), isNull);
  });

  test('a unit procedure completes', () async {
    await expectLater(client.procedures.returnNothing(), completes);
  });

  test('a failing procedure throws with the server message', () async {
    await expectLater(
      client.procedures.divideByZero(numerator: 10),
      throwsA(
        isA<SpacetimeDbProcedureException>()
            .having((e) => e.procedureName, 'procedureName', 'divide_by_zero')
            .having((e) => e.message, 'message', contains('divide')),
      ),
    );
  });
}
