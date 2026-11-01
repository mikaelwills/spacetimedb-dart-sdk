import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';
import 'package:spacetimedb_sdk/spacetimedb_sdk.dart';
import 'package:spacetimedb_sdk/src/connection/spacetimedb_connection.dart'
    show reconnectDelay, setReconnectRandom;

import '../../mocks/silent_socket.dart';

const _base = Duration(seconds: 1);
const _max = Duration(seconds: 30);

class _Harness {
  _Harness() {
    connection = SpacetimeDbConnection(
      host: 'localhost:3000',
      database: 'notesdb',
      config: const ConnectionConfig(
        maxReconnectAttempts: 10,
        baseReconnectDelay: _base,
        maxReconnectDelay: _max,
      ),
      socketFactory:
          (
            uri,
            protocols,
            headers, {
            connectTimeout = const Duration(seconds: 10),
            pingInterval,
          }) {
            final socket = SilentWebSocketChannel();
            sockets.add(socket);
            return socket;
          },
    );
    connection.onStateChanged.listen(states.add);
  }

  late final SpacetimeDbConnection connection;
  final sockets = <SilentWebSocketChannel>[];
  final states = <ConnectionState>[];

  Duration firstAutoReconnectDelay() => states
      .whereType<Reconnecting>()
      .firstWhere((s) => s.attempt == 1)
      .nextDelay!;
}

_Harness _connectThenDrop(FakeAsync async) {
  final harness = _Harness();
  harness.connection.connect();
  async.flushMicrotasks();
  harness.sockets.single.sink.close();
  async.flushMicrotasks();
  return harness;
}

void main() {
  group('auto-reconnect delay', () {
    test('the first auto-reconnect waits between base and 1.5 x base', () {
      fakeAsync((async) {
        final delay = _connectThenDrop(async).firstAutoReconnectDelay();

        expect(delay, greaterThanOrEqualTo(_base));
        expect(delay, lessThan(_base * 1.5));
      });
    });

    test('the first auto-reconnect delay varies between connections', () {
      fakeAsync((async) {
        final delays = {
          for (var i = 0; i < 20; i++)
            _connectThenDrop(async).firstAutoReconnectDelay(),
        };

        expect(delays.length, greaterThan(1));
      });
    });

    test('with a fixed factor of 1 the first auto-reconnect fires at base', () {
      fakeAsync((async) {
        final harness = _Harness();
        setReconnectRandom(harness.connection, () => 0.5);
        harness.connection.connect();
        async.flushMicrotasks();
        harness.sockets.single.sink.close();
        async.flushMicrotasks();

        async.elapse(_base - const Duration(milliseconds: 1));
        expect(harness.sockets, hasLength(1));

        async.elapse(const Duration(milliseconds: 1));
        expect(harness.sockets, hasLength(2));
      });
    });
  });

  group('reconnectDelay', () {
    Duration delay(int attempt, double random) =>
        reconnectDelay(attempt, random, base: _base, max: _max);

    test('matches the upstream table', () {
      expect(delay(1, 0), const Duration(milliseconds: 1000));
      expect(delay(1, 0.5), const Duration(milliseconds: 1000));
      expect(delay(2, 0.5), const Duration(milliseconds: 2000));
      expect(delay(2, 0), const Duration(milliseconds: 1000));
      expect(delay(6, 0), const Duration(milliseconds: 15000));
      expect(delay(1 << 30, 0.9999), const Duration(milliseconds: 30000));
    });

    test('caps the exponent so a large attempt stays finite', () {
      expect(delay(1000, 0), const Duration(milliseconds: 15000));
    });

    test('every attempt and factor stays within base and max', () {
      for (var attempt = 1; attempt <= 25; attempt++) {
        for (final random in [0.0, 0.25, 0.5, 0.75, 0.9999]) {
          final result = delay(attempt, random);
          expect(result, greaterThanOrEqualTo(_base));
          expect(result, lessThanOrEqualTo(_max));
        }
      }
    });
  });
}
