import 'package:test/test.dart';
import 'package:spacetimedb_sdk/codegen.dart';
import 'package:spacetimedb_sdk/src/connection/spacetimedb_connection.dart'
    show
        noteSocketClosed,
        setSubscribeBatchInFlight,
        setSubscribeBatchUnsupported,
        subscribeBatchUnsupported;

import '../../helpers/reconnect_replay.dart';
import '../../mocks/mock_connection.dart';

const _timeout = Duration(seconds: 2);
const _oldServerReason = 'unknown tag 0x5 for sum type ClientMessage';

void main() {
  group('noteSocketClosed classifies an old-server close', () {
    late MockConnection connection;

    setUp(() => connection = MockConnection());

    test('a batch in flight + 1011 + the unknown-tag reason marks batch '
        'unsupported', () {
      setSubscribeBatchInFlight(connection, true);
      noteSocketClosed(
        connection,
        closeCode: 1011,
        closeReason: _oldServerReason,
      );
      expect(subscribeBatchUnsupported(connection), isTrue);
    });

    test('code 1000 with a matching reason does not', () {
      setSubscribeBatchInFlight(connection, true);
      noteSocketClosed(
        connection,
        closeCode: 1000,
        closeReason: _oldServerReason,
      );
      expect(subscribeBatchUnsupported(connection), isFalse);
    });

    test('1011 with another reason does not', () {
      setSubscribeBatchInFlight(connection, true);
      noteSocketClosed(
        connection,
        closeCode: 1011,
        closeReason: 'internal error',
      );
      expect(subscribeBatchUnsupported(connection), isFalse);
    });

    test('a matching close with no batch in flight does not', () {
      noteSocketClosed(
        connection,
        closeCode: 1011,
        closeReason: _oldServerReason,
      );
      expect(subscribeBatchUnsupported(connection), isFalse);
    });

    test('once set, the flag survives a later normal close', () {
      setSubscribeBatchInFlight(connection, true);
      noteSocketClosed(
        connection,
        closeCode: 1011,
        closeReason: _oldServerReason,
      );
      setSubscribeBatchInFlight(connection, false);
      noteSocketClosed(connection, closeCode: 1000, closeReason: 'bye');
      expect(subscribeBatchUnsupported(connection), isTrue);
    });
  });

  group('the manager falls back after an old-server close', () {
    test('the pending batch completes not applied, and the next reconnect '
        'sends one tag-0 Subscribe per set', () async {
      final connection = MockConnection();
      final manager = SubscriptionManager(connection);
      addTearDown(manager.dispose);
      await connection.connect();
      final futures = [
        manager.subscribe(['SELECT * FROM ta']),
        manager.subscribe(['SELECT * FROM tb']),
      ];
      for (final id in [1, 2]) {
        connection.simulateIncoming(
          perSetSubscribeAppliedFrame(id, queryRows({})),
        );
      }
      await Future.wait(futures).timeout(_timeout);

      await connection.disconnect();
      await connection.connect();
      await pumpEventQueue();
      expect(connection.keepAliveWorkInFlight, isTrue);

      noteSocketClosed(
        connection,
        closeCode: 1011,
        closeReason: _oldServerReason,
      );
      await connection.disconnect();
      await pumpEventQueue();
      expect(connection.keepAliveWorkInFlight, isFalse);
      expect(manager.consecutiveEvictionSkips, 1);
      expect(subscribeBatchUnsupported(connection), isTrue);

      connection.clearSent();
      await connection.connect();
      await pumpEventQueue();

      expect(sentWithTag(connection.sentMessages, subscribeBatchTag), isEmpty);
      expect(
        sentWithTag(
          connection.sentMessages,
          subscribeTag,
        ).map(subscribeQuerySetId).toList()..sort(),
        [1, 2],
      );
    });
  });

  group('Invariant A: cold start always sends tag 0', () {
    for (final unsupported in [true, false]) {
      test('with batch unsupported=$unsupported', () async {
        final connection = MockConnection();
        setSubscribeBatchUnsupported(connection, unsupported);
        final manager = SubscriptionManager(connection);
        addTearDown(manager.dispose);
        await connection.connect();
        manager.subscribe(['SELECT * FROM ta']);
        manager.subscribe(['SELECT * FROM tb']);
        manager.subscribe(['SELECT * FROM tc']);
        await pumpEventQueue();

        expect(connection.sentMessages, hasLength(3));
        expect(connection.sentMessages.every((m) => m[0] == 0), isTrue);
      });
    }
  });
}
