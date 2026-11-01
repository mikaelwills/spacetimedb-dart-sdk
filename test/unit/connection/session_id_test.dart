import 'package:fake_async/fake_async.dart';
import 'package:spacetimedb_sdk/spacetimedb_sdk.dart';
import 'package:spacetimedb_sdk/src/connection/spacetimedb_connection.dart'
    show closeForReconnect;
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

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
  }

  late final SpacetimeDbConnection connection;
  final List<_Dial> _script;
  final dials = <Uri>[];
  final channels = <WebSocketChannel>[];
  final states = <ConnectionState>[];

  Set<String?> get sessionIds => {
    for (final uri in dials) uri.queryParameters['session_id'],
  };

  Future<void> dispose() => connection.dispose();
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
        harness.dispose();
        async.flushMicrotasks();
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
        first.dispose();
        second.dispose();
        async.flushMicrotasks();
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
        harness.dispose();
        async.flushMicrotasks();
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
        harness.dispose();
        async.flushMicrotasks();
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
        harness.dispose();
        async.flushMicrotasks();
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
        harness.dispose();
        async.flushMicrotasks();
      });
    });
  });
}
