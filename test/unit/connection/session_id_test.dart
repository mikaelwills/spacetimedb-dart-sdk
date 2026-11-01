import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:spacetimedb_sdk/spacetimedb_sdk.dart';
import 'package:spacetimedb_sdk/src/connection/spacetimedb_connection.dart'
    show closeForReconnect, reconnectDelay, setReconnectRandom;
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../mocks/close_code_socket.dart';
import '../../mocks/silent_socket.dart';

final _hex32 = RegExp(r'^[0-9a-f]{32}$');

typedef _Dial = WebSocketChannel Function();

class _Harness {
  _Harness({
    ConnectionConfig config = const ConnectionConfig(),
    String? initialToken,
    List<_Dial> script = const [],
  }) : _script = [...script] {
    connection = SpacetimeDbConnection(
      host: 'localhost:3000',
      database: 'notesdb',
      initialToken: initialToken,
      config: config,
      socketFactory:
          (
            uri,
            protocols,
            headers, {
            connectTimeout = const Duration(seconds: 10),
            pingInterval,
          }) {
            dials.add(uri);
            final channel = _script.isEmpty
                ? SilentWebSocketChannel()
                : _script.removeAt(0)();
            channels.add(channel);
            return channel;
          },
    );
    connection.onStateChanged.listen(states.add);
    connection.connectionQuality.listen(qualities.add);
  }

  late final SpacetimeDbConnection connection;
  final dials = <Uri>[];
  final channels = <WebSocketChannel>[];
  final states = <ConnectionState>[];
  final qualities = <ConnectionQuality>[];
  final List<_Dial> _script;

  Set<String?> get sessionIds => {
    for (final uri in dials) uri.queryParameters['session_id'],
  };

  Reconnecting get lastReconnecting => states.whereType<Reconnecting>().last;

  int get reconnectAttempts => qualities.last.reconnectAttempts;

  void dispose(FakeAsync async) {
    connection.dispose();
    async.flushMicrotasks();
  }
}

WebSocketChannel _fail() => throw Exception('simulated connect failure');

void main() {
  group('session_id on the subscribe URL', () {
    test('session_id is 32 lowercase hex', () {
      fakeAsync((async) {
        final harness = _Harness();
        harness.connection.connect();
        async.flushMicrotasks();

        final id = harness.dials.single.queryParameters['session_id'];
        expect(id, matches(_hex32));
        harness.dispose(async);
      });
    });

    test('two objects carry different ids', () {
      fakeAsync((async) {
        final first = _Harness();
        final second = _Harness();
        first.connection.connect();
        second.connection.connect();
        async.flushMicrotasks();

        expect(
          first.dials.single.queryParameters['session_id'],
          isNot(second.dials.single.queryParameters['session_id']),
        );
        first.dispose(async);
        second.dispose(async);
      });
    });

    test('id is stable across dials', () {
      fakeAsync((async) {
        final harness = _Harness(
          initialToken: 'token',
          config: const ConnectionConfig(
            baseReconnectDelay: Duration(milliseconds: 100),
            maxReconnectDelay: Duration(milliseconds: 100),
          ),
        );
        final connection = harness.connection;

        connection.connect();
        async.flushMicrotasks();
        expect(harness.dials, hasLength(1));

        closeForReconnect(connection, 'test: drop');
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 1));
        expect(harness.dials, hasLength(2));
        expect(connection.state, isA<Connected>());

        connection.reconnect();
        async.flushMicrotasks();
        expect(harness.dials, hasLength(3));

        connection.clearToken();
        connection.reconnect();
        async.flushMicrotasks();
        expect(harness.dials, hasLength(4));
        expect(harness.dials.last.queryParameters, contains('session_id'));

        connection.disconnect();
        async.flushMicrotasks();
        connection.retryConnection();
        async.flushMicrotasks();
        expect(harness.dials, hasLength(5));

        expect(harness.sessionIds, hasLength(1));
        expect(harness.sessionIds.single, matches(_hex32));
        harness.dispose(async);
      });
    });

    test('id survives clearToken', () {
      fakeAsync((async) {
        final harness = _Harness(initialToken: 'token');
        final connection = harness.connection;

        connection.connect();
        async.flushMicrotasks();
        connection.clearToken();
        connection.reconnect();
        async.flushMicrotasks();

        expect(harness.dials, hasLength(2));
        expect(
          harness.dials.last.queryParameters['session_id'],
          harness.dials.first.queryParameters['session_id'],
        );
        harness.dispose(async);
      });
    });

    test('a retryInitialConnect retry carries the same id', () {
      fakeAsync((async) {
        final harness = _Harness(
          config: const ConnectionConfig(
            baseReconnectDelay: Duration(milliseconds: 100),
            maxReconnectDelay: Duration(milliseconds: 100),
            retryInitialConnect: true,
          ),
          script: [_fail],
        );

        harness.connection.connect();
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 1));

        expect(harness.dials, hasLength(2));
        expect(harness.connection.state, isA<Connected>());
        expect(harness.sessionIds, hasLength(1));
        expect(harness.sessionIds.single, matches(_hex32));
        harness.dispose(async);
      });
    });

    test('autoReconnect off sends no query string on the VM', () {
      fakeAsync((async) {
        final harness = _Harness(
          config: const ConnectionConfig(autoReconnect: false),
        );
        harness.connection.connect();
        async.flushMicrotasks();

        final uri = harness.dials.single;
        expect(uri.query, isEmpty);
        expect(uri.queryParameters.containsKey('session_id'), isFalse);
        harness.dispose(async);
      });
    });
  });

  group('a 4000 refusal does not count as a failed attempt', () {
    const base = Duration(seconds: 1);
    const max = Duration(seconds: 30);
    const smallBase = Duration(milliseconds: 100);
    const floor = Duration(milliseconds: 500);
    const pinned = 0.5;
    const millisecond = Duration(milliseconds: 1);

    Duration delayFor(int attempt, {Duration base = base}) =>
        reconnectDelay(attempt, pinned, base: base, max: max);

    Duration sessionBusyDelay(int attempt, {Duration base = base}) {
      final delay = delayFor(attempt < 1 ? 1 : attempt, base: base);
      return delay < floor ? floor : delay;
    }

    _Harness pinnedHarness(
      List<_Dial> script, {
      ConnectionConfig config = const ConnectionConfig(
        baseReconnectDelay: base,
        maxReconnectDelay: max,
      ),
    }) {
      final harness = _Harness(config: config, script: script);
      setReconnectRandom(harness.connection, () => pinned);
      return harness;
    }

    void connectThenDrop(FakeAsync async, _Harness harness) {
      harness.connection.connect();
      async.flushMicrotasks();
      harness.channels.first.sink.close();
      async.flushMicrotasks();
    }

    void elapseLastDelay(FakeAsync async, _Harness harness) {
      async.elapse(harness.lastReconnecting.nextDelay!);
      async.flushMicrotasks();
    }

    List<Reconnecting> reconnectingSince(_Harness harness, int count) =>
        harness.states.whereType<Reconnecting>().skip(count).toList();

    int reconnectingCount(_Harness harness) =>
        harness.states.whereType<Reconnecting>().length;

    test('4000 keeps the attempt number', () {
      fakeAsync((async) {
        final harness = pinnedHarness([
          SilentWebSocketChannel.new,
          _fail,
          CloseCodeWebSocketChannel.sessionBusy,
          CloseCodeWebSocketChannel.sessionBusy,
          CloseCodeWebSocketChannel.sessionBusy,
          _fail,
          SilentWebSocketChannel.new,
        ]);
        connectThenDrop(async, harness);
        elapseLastDelay(async, harness);
        expect(harness.lastReconnecting.attempt, 2);
        expect(harness.reconnectAttempts, 2);

        for (var refusal = 0; refusal < 3; refusal++) {
          final before = reconnectingCount(harness);
          elapseLastDelay(async, harness);
          final emitted = reconnectingSince(harness, before);
          expect(emitted, hasLength(1));
          expect(emitted.single.attempt, 2);
          expect(emitted.single.nextDelay, sessionBusyDelay(2));
          expect(harness.reconnectAttempts, 2);
        }
        expect(harness.dials, hasLength(5));

        elapseLastDelay(async, harness);
        expect(harness.dials, hasLength(6));
        expect(harness.lastReconnecting.attempt, 3);
        expect(harness.reconnectAttempts, 3);

        elapseLastDelay(async, harness);
        expect(harness.connection.state, isA<Connected>());
        harness.channels.last.sink.close();
        async.flushMicrotasks();
        expect(harness.lastReconnecting.attempt, 1);
        expect(harness.reconnectAttempts, 1);
        harness.dispose(async);
      });
    });

    test('4000 on the first connect() retries through auto-reconnect', () {
      fakeAsync((async) {
        final harness = _Harness(
          config: const ConnectionConfig(
            baseReconnectDelay: base,
            maxReconnectDelay: max,
          ),
          script: [CloseCodeWebSocketChannel.sessionBusy],
        );
        Object? thrown;
        var completed = false;
        harness.connection.connect().then(
          (_) {
            completed = true;
          },
          onError: (Object e) {
            thrown = e;
          },
        );
        async.flushMicrotasks();

        expect(completed, isTrue);
        expect(thrown, isNull);
        final reconnecting = harness.states.whereType<Reconnecting>().toList();
        expect(reconnecting, hasLength(1));
        expect(reconnecting.single.attempt, 0);
        expect(reconnecting.single.nextDelay, greaterThanOrEqualTo(base));
        expect(reconnecting.single.nextDelay, lessThanOrEqualTo(base * 1.5));

        async.elapse(reconnecting.single.nextDelay!);
        async.flushMicrotasks();
        expect(harness.dials, hasLength(2));
        expect(harness.connection.state, isA<Connected>());
        harness.dispose(async);
      });
    });

    _Harness atTheCap(List<_Dial> tail) => pinnedHarness(
      [SilentWebSocketChannel.new, _fail, ...tail],
      config: const ConnectionConfig(
        maxReconnectAttempts: 2,
        baseReconnectDelay: smallBase,
        maxReconnectDelay: max,
      ),
    );

    test('4000 at the cap still retries without FatalError', () {
      fakeAsync((async) {
        final harness = atTheCap([
          for (var i = 0; i < 5; i++) CloseCodeWebSocketChannel.sessionBusy,
        ]);
        connectThenDrop(async, harness);
        elapseLastDelay(async, harness);
        expect(harness.reconnectAttempts, 2);

        var before = reconnectingCount(harness);
        elapseLastDelay(async, harness);
        for (var refusal = 1; refusal <= 5; refusal++) {
          final emitted = reconnectingSince(harness, before);
          expect(emitted, hasLength(1), reason: 'refusal $refusal');
          expect(emitted.single.attempt, 2);
          expect(emitted.single.nextDelay, greaterThanOrEqualTo(floor));
          expect(harness.reconnectAttempts, 2);

          final dials = harness.dials.length;
          before = reconnectingCount(harness);
          async.elapse(emitted.single.nextDelay! - millisecond);
          async.flushMicrotasks();
          expect(harness.dials, hasLength(dials));
          async.elapse(millisecond);
          async.flushMicrotasks();
          expect(harness.dials, hasLength(dials + 1));
        }
        expect(harness.connection.state, isA<Connected>());
        expect(harness.states.whereType<FatalError>(), isEmpty);
        harness.dispose(async);
      });
    });

    test('a non-4000 failure at the cap still gives up with FatalError', () {
      fakeAsync((async) {
        final harness = atTheCap([_fail]);
        connectThenDrop(async, harness);
        elapseLastDelay(async, harness);
        expect(harness.reconnectAttempts, 2);

        elapseLastDelay(async, harness);
        final fatal = harness.states.whereType<FatalError>().toList();
        expect(fatal, hasLength(1));
        expect(fatal.single.message, 'Max reconnection attempts reached');
        final dials = harness.dials.length;
        async.elapse(const Duration(seconds: 60));
        expect(harness.dials, hasLength(dials));
        harness.dispose(async);
      });
    });

    test('the 500 ms floor is session-busy only', () {
      fakeAsync((async) {
        final harness = pinnedHarness(
          [CloseCodeWebSocketChannel.sessionBusy, _fail],
          config: const ConnectionConfig(
            baseReconnectDelay: smallBase,
            maxReconnectDelay: max,
          ),
        );
        harness.connection.connect();
        async.flushMicrotasks();
        final refusal = harness.lastReconnecting;
        expect(refusal.nextDelay, greaterThanOrEqualTo(floor));

        async.elapse(floor - millisecond);
        async.flushMicrotasks();
        expect(harness.dials, hasLength(1));
        async.elapse(millisecond);
        async.flushMicrotasks();
        expect(harness.dials, hasLength(2));

        final failed = harness.lastReconnecting;
        expect(failed.attempt, 1);
        expect(failed.nextDelay, delayFor(1, base: smallBase));
        expect(failed.nextDelay, lessThan(floor));
        harness.dispose(async);
      });
    });

    test('disconnect wins over a 4000', () {
      fakeAsync((async) {
        final harness = _Harness(
          script: [
            () =>
                CloseCodeWebSocketChannel.sessionBusy(closeAfterFrames: false),
          ],
        );
        harness.connection.connect();
        async.flushMicrotasks();
        expect(harness.connection.state, isA<Connected>());

        final before = reconnectingCount(harness);
        harness.connection.disconnect();
        async.flushMicrotasks();
        expect(harness.channels.single.closeCode, 4000);

        async.elapse(const Duration(seconds: 60));
        expect(harness.dials, hasLength(1));
        expect(harness.connection.state, isA<Disconnected>());
        expect(reconnectingSince(harness, before), isEmpty);
        harness.dispose(async);
      });
    });

    test('4000 after a frame counts as a normal close', () {
      fakeAsync((async) {
        final harness = pinnedHarness(
          [
            () => CloseCodeWebSocketChannel.sessionBusy(
              frames: [
                Uint8List.fromList([0, 0]),
              ],
            ),
          ],
          config: const ConnectionConfig(
            baseReconnectDelay: smallBase,
            maxReconnectDelay: max,
          ),
        );
        harness.connection.connect();
        async.flushMicrotasks();

        expect(harness.lastReconnecting.attempt, 1);
        expect(
          harness.lastReconnecting.nextDelay,
          delayFor(1, base: smallBase),
        );
        expect(harness.reconnectAttempts, 1);
        expect(
          harness.states.whereType<Reconnecting>().map((s) => s.nextDelay),
          everyElement(lessThan(floor)),
        );
        harness.dispose(async);
      });
    });

    for (final code in [1000, 1006]) {
      test('a $code close with no frames counts as today', () {
        fakeAsync((async) {
          final harness = pinnedHarness([
            () => CloseCodeWebSocketChannel(closeCode: code),
          ]);
          harness.connection.connect();
          async.flushMicrotasks();

          expect(harness.lastReconnecting.attempt, 1);
          expect(harness.lastReconnecting.nextDelay, delayFor(1));
          expect(harness.reconnectAttempts, 1);
          harness.dispose(async);
        });
      });
    }

    test('the keep-alive is stopped on a refused socket', () {
      fakeAsync((async) {
        const pingInterval = Duration(milliseconds: 600);
        const pongTimeout = Duration(milliseconds: 50);
        final retryReady = Completer<void>();
        final harness = pinnedHarness(
          [
            () =>
                CloseCodeWebSocketChannel.sessionBusy(closeAfterFrames: false),
            () => CloseCodeWebSocketChannel(
              closeCode: 1000,
              closeAfterFrames: false,
              ready: retryReady.future,
            ),
          ],
          config: const ConnectionConfig(
            baseReconnectDelay: smallBase,
            maxReconnectDelay: max,
            appLevelKeepAlive: true,
            pingInterval: pingInterval,
            pongTimeout: pongTimeout,
          ),
        );
        harness.connection.connect();
        async.flushMicrotasks();
        final refused = harness.channels.single as CloseCodeWebSocketChannel;
        refused.close();
        async.flushMicrotasks();
        expect(harness.lastReconnecting.nextDelay, floor);
        final sentAtClose = refused.sent.length;

        async.elapse(floor);
        async.flushMicrotasks();
        expect(harness.dials, hasLength(2));
        expect(harness.connection.state, isA<Connecting>());
        final retry = harness.channels.last as CloseCodeWebSocketChannel;

        async.elapse(pingInterval + pongTimeout);
        async.flushMicrotasks();
        expect(retry.sink.closeCalls, 0);
        expect(refused.sent, hasLength(sentAtClose));
        expect(
          harness.qualities.map((quality) => quality.lastPingSent),
          everyElement(isNull),
        );

        retryReady.complete();
        async.flushMicrotasks();
        expect(harness.connection.state, isA<Connected>());
        harness.dispose(async);
      });
    });
  });
}
