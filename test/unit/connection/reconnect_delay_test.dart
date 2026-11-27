import 'dart:math';

import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';
import 'package:spacetimedb_sdk/spacetimedb_sdk.dart';
import 'package:spacetimedb_sdk/src/connection/reconnect_delay.dart'
    show reconnectDelay;
import 'package:spacetimedb_sdk/src/connection/spacetimedb_connection.dart'
    show setReconnectRandom;

import '../../mocks/silent_socket.dart';

const _base = Duration(seconds: 1);
const _max = Duration(seconds: 30);
const _clients = 1000;
const _maxSharedDelay = 3;
const _firstAttempt = 1;
const _secondAttempt = 2;
const _cappedAtMaxAttempt = 6;
const _cappedAttempt = 10;
const _fixedFactor = 0.5;
const _oneTick = Duration(milliseconds: 1);
final _minDelay = _base * 0.5;
final _fixedFactorDelay = _base * 0.75;
final _secondAttemptFixedFactorDelay = _base * 1.5;
final _maxFixedFactorDelay = _max * 0.75;
final _halfMax = _max * 0.5;

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

Duration _delay(int attempt, double random) =>
    reconnectDelay(attempt, random, base: _base, max: _max);

Map<Duration, int> _delaysForAttempt(int attempt, Random random) {
  final counts = <Duration, int>{};
  for (var client = 0; client < _clients; client++) {
    final delay = _delay(attempt, random.nextDouble());
    counts[delay] = (counts[delay] ?? 0) + 1;
  }
  return counts;
}

int _largestSharedCount(Map<Duration, int> counts) => counts.values.reduce(max);

void main() {
  group('auto-reconnect delay', () {
    test('the first auto-reconnect waits between half base and base', () {
      fakeAsync((async) {
        final delay = _connectThenDrop(async).firstAutoReconnectDelay();

        expect(delay, greaterThanOrEqualTo(_minDelay));
        expect(delay, lessThan(_base));
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

    test('with a fixed factor the first auto-reconnect fires at its delay', () {
      fakeAsync((async) {
        final harness = _Harness();
        setReconnectRandom(harness.connection, () => _fixedFactor);
        harness.connection.connect();
        async.flushMicrotasks();
        harness.sockets.single.sink.close();
        async.flushMicrotasks();

        async.elapse(_fixedFactorDelay - _oneTick);
        expect(harness.sockets, hasLength(1));

        async.elapse(_oneTick);
        expect(harness.sockets, hasLength(2));
      });
    });
  });

  group('reconnectDelay', () {
    test('matches the jitter table', () {
      expect(_delay(_firstAttempt, 0), _minDelay);
      expect(_delay(_firstAttempt, _fixedFactor), _fixedFactorDelay);
      expect(_delay(_secondAttempt, 0), _base);
      expect(
        _delay(_secondAttempt, _fixedFactor),
        _secondAttemptFixedFactorDelay,
      );
      expect(_delay(_cappedAtMaxAttempt, 0), _halfMax);
      expect(_delay(_cappedAtMaxAttempt, _fixedFactor), _maxFixedFactorDelay);
    });

    test('caps the exponent so a large attempt stays finite', () {
      expect(_delay(1000, 0), _halfMax);
    });

    test('every attempt and factor stays within half base and max', () {
      for (var attempt = 1; attempt <= 25; attempt++) {
        for (final random in [0.0, 0.25, 0.5, 0.75, 0.9999]) {
          final result = _delay(attempt, random);
          expect(result, greaterThanOrEqualTo(_minDelay));
          expect(result, lessThanOrEqualTo(_max));
        }
      }
    });

    test('1000 clients spread the first attempt over distinct delays', () {
      final counts = _delaysForAttempt(_firstAttempt, Random(1));

      expect(_largestSharedCount(counts), lessThanOrEqualTo(_maxSharedDelay));
    });

    test('1000 clients spread a capped attempt over distinct delays', () {
      final counts = _delaysForAttempt(_cappedAttempt, Random(2));

      expect(_largestSharedCount(counts), lessThanOrEqualTo(_maxSharedDelay));
    });

    test('no delay is pinned to base or max', () {
      final counts = _delaysForAttempt(_cappedAttempt, Random(3));

      expect(counts.containsKey(_max), isFalse);
      expect(counts.containsKey(_base), isFalse);
    });
  });
}
