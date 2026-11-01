import 'dart:async';
import 'dart:io';

import 'package:spacetimedb_sdk/spacetimedb_sdk.dart';
import 'package:spacetimedb_sdk/src/connection/websocket.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class _Proxy {
  _Proxy._(this._server, this._wsServer);
  final ServerSocket _server;
  final HttpServer _wsServer;
  final List<Socket> clientSides = [];

  int get port => _server.port;

  static Future<_Proxy> start() async {
    final ws = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    ws.listen((req) async {
      final socket = await WebSocketTransformer.upgrade(
        req,
        protocolSelector: (p) => p.first,
      );
      socket.listen((_) {}, onError: (_) {});
    });
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final proxy = _Proxy._(server, ws);
    server.listen((client) async {
      proxy.clientSides.add(client);
      final upstream = await Socket.connect(
        InternetAddress.loopbackIPv4,
        ws.port,
      );
      upstream.listen(
        client.add,
        onError: (_) {},
        onDone: () => client.destroy(),
      );
      client.listen(
        upstream.add,
        onError: (_) {},
        onDone: () => upstream.destroy(),
      );
    });
    return proxy;
  }

  Future<void> stop() async {
    for (final s in clientSides) {
      s.destroy();
    }
    await _server.close();
    await _wsServer.close(force: true);
  }
}

class _HtmlShapedChannel extends StreamChannelMixin<dynamic>
    implements WebSocketChannel {
  _HtmlShapedChannel() {
    _controller.local.stream.listen((_) {});
  }

  final _controller = StreamChannelController<Object?>(
    sync: true,
    allowForeignErrors: false,
  );

  void browserErrorEvent() {
    _controller.local.sink.addError(
      WebSocketChannelException('WebSocket connection failed.'),
    );
    _controller.local.sink.close();
  }

  @override
  String? get protocol => 'v2.bsatn.spacetimedb';
  @override
  int? get closeCode => null;
  @override
  String? get closeReason => null;
  @override
  Future<void> get ready => Future<void>.value();
  @override
  Stream get stream => _controller.foreign.stream;
  @override
  late final WebSocketSink sink = _Sink(_controller.foreign.sink);
}

class _Sink implements WebSocketSink {
  _Sink(this._inner);
  final StreamSink<dynamic> _inner;
  @override
  void add(dynamic data) => _inner.add(data);
  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _inner.addError(error, stackTrace);
  @override
  Future<void> addStream(Stream<dynamic> stream) => _inner.addStream(stream);
  @override
  Future<void> get done => _inner.done;
  @override
  Future<void> close([int? closeCode, String? closeReason]) => _inner.close();
}

Future<void> _probeRealIo(void Function(Socket clientSide) fault) async {
  final proxy = await _Proxy.start();
  addTearDown(proxy.stop);
  final errors = <String>[];
  final states = <ConnectionState>[];
  final connection = SpacetimeDbConnection(
    host: '127.0.0.1:${proxy.port}',
    database: 'probe',
    config: const ConnectionConfig(
      maxReconnectAttempts: 3,
      baseReconnectDelay: Duration(milliseconds: 20),
      maxReconnectDelay: Duration(milliseconds: 20),
    ),
    socketFactory: connectWebSocket,
  );
  addTearDown(connection.dispose);
  connection.onError.listen(errors.add);
  connection.onStateChanged.listen(states.add);

  await connection.connect();
  expect(connection.state, isA<Connected>());
  final reconnected = connection.onStateChanged
      .where((s) => s is Connected)
      .first;
  fault(proxy.clientSides.single);
  await reconnected.timeout(const Duration(seconds: 3));

  expect(errors, isEmpty, reason: 'real IO stack must not reach onError');
  expect(states.whereType<Reconnecting>(), isNotEmpty);
  expect(proxy.clientSides, hasLength(2));
}

void main() {
  test('real IO channel: protocol-violating frame mid-session', () async {
    await _probeRealIo((c) => c.add([0x8F, 0x00]));
  });

  test('real IO channel: RSV bits set mid-session', () async {
    await _probeRealIo((c) => c.add([0xF2, 0x00]));
  });

  test('real IO channel: TCP dropped mid-session', () async {
    await _probeRealIo((c) => c.destroy());
  });

  test('html-shaped channel: browser error event mid-session', () async {
    final sockets = <_HtmlShapedChannel>[];
    final errors = <String>[];
    final states = <ConnectionState>[];
    final connection = SpacetimeDbConnection(
      host: 'localhost:3000',
      database: 'probe',
      config: const ConnectionConfig(
        maxReconnectAttempts: 2,
        baseReconnectDelay: Duration(milliseconds: 20),
        maxReconnectDelay: Duration(milliseconds: 20),
      ),
      socketFactory:
          (
            uri,
            protocols,
            headers, {
            connectTimeout = const Duration(seconds: 10),
            pingInterval,
          }) {
            final s = _HtmlShapedChannel();
            sockets.add(s);
            return s;
          },
    );
    addTearDown(connection.dispose);
    connection.onError.listen(errors.add);
    connection.onStateChanged.listen(states.add);

    await connection.connect();
    final reconnected = connection.onStateChanged
        .where((s) => s is Connected)
        .first;
    sockets.first.browserErrorEvent();
    await reconnected.timeout(const Duration(seconds: 2));

    expect(errors, hasLength(1));
    expect(states.whereType<Reconnecting>(), isNotEmpty);
    expect(sockets, hasLength(2));
  });
}
