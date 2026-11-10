import 'dart:async';
import 'dart:typed_data';

import 'package:spacetimedb_sdk/codegen.dart';
import 'package:spacetimedb_sdk/src/messages/client_messages.dart';
import 'package:spacetimedb_sdk/src/messages/server_messages.dart';
import 'package:test/test.dart';

import '../../mocks/mock_connection.dart';

void main() {
  late MockConnection connection;
  late SubscriptionManager manager;
  late ProcedureCaller procedures;

  setUp(() {
    connection = MockConnection()..setStateSilently(const Connected());
    manager = SubscriptionManager(connection);
    procedures = manager.procedures;
  });

  tearDown(() async {
    await manager.dispose();
  });

  int readU32(BsatnDecoder decoder) => decoder.readU32();

  group('ProcedureCaller request-id matching', () {
    test('each result completes the call that sent its request id', () async {
      final first = procedures.call('add_numbers', Uint8List(0), readU32);
      final second = procedures.call('add_numbers', Uint8List(0), readU32);
      final firstId = connection.getSentRequestId(0);
      final secondId = connection.getSentRequestId(1);
      expect(firstId, isNot(secondId));

      connection.simulateIncoming(_returned(secondId, _u32(22)));
      connection.simulateIncoming(_returned(firstId, _u32(11)));

      expect(await first, 11);
      expect(await second, 22);
    });

    test(
      'a result for an unknown request id leaves pending calls waiting',
      () async {
        final call = procedures.call('add_numbers', Uint8List(0), readU32);
        final requestId = connection.getLastSentRequestId();
        var completed = false;
        unawaited(call.then((_) => completed = true));

        connection.simulateIncoming(_returned(requestId + 500, _u32(1)));
        await pumpEventQueue();
        expect(completed, isFalse);

        connection.simulateIncoming(_returned(requestId, _u32(7)));
        expect(await call, 7);
      },
    );

    test('the raw result stream still sees every result', () async {
      final seen = manager.onProcedureResult.first;
      final call = procedures.call('add_numbers', Uint8List(0), readU32);
      final requestId = connection.getLastSentRequestId();

      connection.simulateIncoming(_returned(requestId, _u32(3)));

      expect((await seen).requestId, requestId);
      expect(await call, 3);
    });
  });

  group('ProcedureCaller encoding', () {
    test('sends CallProcedure with the name and args bytes', () async {
      final args = Uint8List.fromList([1, 2, 3]);
      unawaited(
        procedures.call('add_numbers', args, readU32).catchError((_) => 0),
      );

      final decoder = BsatnDecoder(connection.sentMessages.single);
      expect(decoder.readU8(), ClientMessageType.callProcedure.tag);
      expect(decoder.readU32(), greaterThan(0));
      expect(decoder.readU8(), 0);
      expect(decoder.readString(), 'add_numbers');
      expect(decoder.readBytes(decoder.readU32()), args);
    });

    test('decodes the returned bytes with the given decoder', () async {
      final call = procedures.call(
        'maybe_greeting',
        Uint8List(0),
        (decoder) => decoder.readOption<String>(() => decoder.readString()),
      );
      final encoder = BsatnEncoder();
      encoder.writeOption<String>('hello', (v) => encoder.writeString(v));

      connection.simulateIncoming(
        _returned(connection.getLastSentRequestId(), encoder.toBytes()),
      );

      expect(await call, 'hello');
    });
  });

  group('ProcedureCaller failures', () {
    test('an internal error fails the call with the server message', () async {
      final call = procedures.call('divide_by_zero', Uint8List(0), readU32);

      connection.simulateIncoming(
        _internalError(
          connection.getLastSentRequestId(),
          'attempt to divide by zero',
        ),
      );

      await expectLater(
        call,
        throwsA(
          isA<SpacetimeDbProcedureException>()
              .having((e) => e.procedureName, 'procedureName', 'divide_by_zero')
              .having((e) => e.message, 'message', 'attempt to divide by zero'),
        ),
      );
    });

    test('bytes the decoder cannot read fail the call', () async {
      final call = procedures.call('add_numbers', Uint8List(0), readU32);

      connection.simulateIncoming(
        _returned(connection.getLastSentRequestId(), Uint8List(1)),
      );

      await expectLater(call, throwsA(isA<SpacetimeDbProcedureException>()));
    });

    test('a call while not connected fails without sending', () async {
      connection.setStateSilently(const Disconnected());

      await expectLater(
        procedures.call('add_numbers', Uint8List(0), readU32),
        throwsA(isA<SpacetimeDbConnectionException>()),
      );
      expect(connection.sentMessages, isEmpty);
    });

    test('a dropped connection fails every pending call', () async {
      final first = procedures.call('add_numbers', Uint8List(0), readU32);
      final second = procedures.call('add_numbers', Uint8List(0), readU32);

      connection.mockState = const Disconnected();

      await expectLater(first, throwsA(isA<SpacetimeDbConnectionException>()));
      await expectLater(second, throwsA(isA<SpacetimeDbConnectionException>()));
    });

    test(
      'a result after the timeout is ignored and the call times out',
      () async {
        final call = procedures.call(
          'add_numbers',
          Uint8List(0),
          readU32,
          timeout: const Duration(milliseconds: 20),
        );
        final requestId = connection.getLastSentRequestId();

        await expectLater(call, throwsA(isA<SpacetimeDbTimeoutException>()));
        expect(procedures.handleResult(_decoded(requestId, _u32(1))), isFalse);
      },
    );
  });
}

Uint8List _u32(int value) => (BsatnEncoder()..writeU32(value)).toBytes();

Uint8List _frame(int requestId, void Function(BsatnEncoder) writeStatus) {
  final encoder = BsatnEncoder()
    ..writeU8(0)
    ..writeU8(ServerMessageType.procedureResult.tag);
  writeStatus(encoder);
  encoder
    ..writeU64(Int64(0))
    ..writeU64(Int64(0))
    ..writeU32(requestId);
  return encoder.toBytes();
}

Uint8List _returned(int requestId, Uint8List data) => _frame(requestId, (e) {
  e
    ..writeU8(0)
    ..writeU32(data.length)
    ..writeBytes(data);
});

Uint8List _internalError(int requestId, String message) =>
    _frame(requestId, (e) {
      e
        ..writeU8(1)
        ..writeString(message);
    });

ProcedureResultMessage _decoded(int requestId, Uint8List data) =>
    ProcedureResultMessage(
      status: ProcedureStatus(
        type: ProcedureStatusType.returned,
        returnedData: data,
      ),
      timestamp: Int64(0),
      totalHostExecutionDurationMicros: Int64(0),
      requestId: requestId,
    );
