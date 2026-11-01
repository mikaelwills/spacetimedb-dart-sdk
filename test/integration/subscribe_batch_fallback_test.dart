import 'dart:async';
import 'dart:typed_data';

import 'package:spacetimedb_sdk/codegen.dart';
import 'package:spacetimedb_sdk/protocol.dart';
import 'package:spacetimedb_sdk/src/connection/spacetimedb_connection.dart'
    show closeForReconnect, subscribeBatchUnsupported;
import 'package:spacetimedb_sdk/src/connection/websocket.dart' as ws;
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../generated/folder.dart';
import '../generated/note.dart';
import '../helpers/integration_test_helper.dart';
import '../helpers/reconnect_replay.dart';
import '../helpers/test_env.dart';

const _timeout = Duration(seconds: 10);
const _backoff = Duration(milliseconds: 100);
const _oldServerReason = 'unknown tag 0x5 for sum type ClientMessage';

class _OldServer {
  bool rejected = false;
}

class _OldServerSink implements WebSocketSink {
  _OldServerSink(this._channel);

  final _OldServerChannel _channel;

  @override
  void add(dynamic data) {
    if (data is Uint8List) _channel.sent.add(data);
    if (data is Uint8List &&
        data.isNotEmpty &&
        data[0] == subscribeBatchTag &&
        !_channel._server.rejected) {
      _channel._server.rejected = true;
      _channel._rejectAsOldServer();
      return;
    }
    _channel._inner.sink.add(data);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _channel._inner.sink.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<dynamic> stream) => stream.forEach(add);

  @override
  Future<void> get done => _channel._inner.sink.done;

  @override
  Future<void> close([int? closeCode, String? closeReason]) =>
      _channel._inner.sink.close(closeCode, closeReason);
}

class _OldServerChannel extends StreamChannelMixin<dynamic>
    implements WebSocketChannel {
  _OldServerChannel(this._inner, this._server) {
    _sink = _OldServerSink(this);
    _inner.stream.listen(
      (data) {
        if (!_inbound.isClosed) _inbound.add(data);
      },
      onError: (Object e) {
        if (!_inbound.isClosed) _inbound.addError(e);
      },
      onDone: () {
        if (!_inbound.isClosed) _inbound.close();
      },
    );
  }

  final List<Uint8List> sent = [];
  final WebSocketChannel _inner;
  final _OldServer _server;
  final StreamController<dynamic> _inbound = StreamController<dynamic>();
  late final _OldServerSink _sink;
  int? _closeCode;
  String? _closeReason;

  @override
  String? get protocol => _inner.protocol;

  @override
  int? get closeCode => _closeCode ?? _inner.closeCode;

  @override
  String? get closeReason => _closeReason ?? _inner.closeReason;

  @override
  Future<void> get ready => _inner.ready;

  @override
  Stream<dynamic> get stream => _inbound.stream;

  @override
  WebSocketSink get sink => _sink;

  void _rejectAsOldServer() {
    _closeCode = 1011;
    _closeReason = _oldServerReason;
    _inbound.close();
    _inner.sink.close();
  }
}

Future<void> _waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(_timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('condition never held');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

Set<String> _noteKeys(TableCache<Note> notes) => {
  for (final note in notes.iter()) '${note.id}|${note.title}|${note.content}',
};

Set<String> _folderKeys(TableCache<Folder> folders) => {
  for (final folder in folders.iter()) '${folder.path}|${folder.name}',
};

void main() {
  setUpAll(ensureTestEnvironment);
  tearDownAll(cleanupTestEnvironment);

  test('a server that rejects SubscribeBatch with 1011 costs one extra '
      'reconnect, then per-set Subscribe replays with no error', () async {
    final writer = await createTestEnv(registerFolder: true);
    addTearDown(writer.disconnect);
    await writer.connection.connect();
    await writer.subManager.onInitialConnection.first.timeout(_timeout);
    await writer.subManager.subscribe(['SELECT * FROM note']).timeout(_timeout);
    await writer.subManager
        .subscribe(['SELECT * FROM folder'])
        .timeout(_timeout);

    final server = _OldServer();
    final channels = <_OldServerChannel>[];
    final connection = SpacetimeDbConnection(
      host: 'localhost:3000',
      database: 'notesdb',
      config: const ConnectionConfig(
        baseReconnectDelay: _backoff,
        maxReconnectDelay: _backoff,
      ),
      socketFactory:
          (
            uri,
            protocols,
            headers, {
            connectTimeout = const Duration(seconds: 10),
            pingInterval,
          }) {
            final channel = _OldServerChannel(
              ws.connectWebSocket(
                uri,
                const ['v2.bsatn.spacetimedb'],
                headers,
                connectTimeout: connectTimeout,
                pingInterval: pingInterval,
              ),
              server,
            );
            channels.add(channel);
            return channel;
          },
    );
    final manager = SubscriptionManager(connection);
    manager.cache.registerDecoder<Note>('note', NoteDecoder());
    manager.cache.registerDecoder<Folder>('folder', FolderDecoder());
    final errors = <SubscriptionErrorMessage>[];
    manager.onSubscriptionError.listen(errors.add);
    addTearDown(() async {
      await manager.dispose();
      await connection.dispose();
    });

    final initial = manager.onInitialConnection.first;
    await connection.connect();
    await initial.timeout(_timeout);
    await Future.wait([
      manager.subscribe(['SELECT * FROM note']),
      manager.subscribe(['SELECT * FROM folder']),
    ]).timeout(_timeout);
    await _waitUntil(() => manager.subscriptionsReady.value);

    final stamp = DateTime.now().microsecondsSinceEpoch;
    final stopwatch = Stopwatch()..start();
    closeForReconnect(connection, 'test: force a reconnect');
    await _waitUntil(() => channels.length == 3);
    await writer.reducers
        .createNote(title: 'fallback-$stamp', content: 'x')
        .timeout(_timeout);
    await _waitUntil(
      () =>
          manager.subscriptionsReady.value &&
          manager.cache
              .getTableByTypedName<Note>('note')
              .iter()
              .any((n) => n.title == 'fallback-$stamp'),
    );
    stopwatch.stop();
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(server.rejected, isTrue);
    expect(subscribeBatchUnsupported(connection), isTrue);
    expect(channels, hasLength(3), reason: 'exactly one extra reconnect');
    expect(sentWithTag(channels[1].sent, subscribeBatchTag), hasLength(1));
    expect(sentWithTag(channels[2].sent, subscribeBatchTag), isEmpty);
    expect(
      sentWithTag(
        channels[2].sent,
        subscribeTag,
      ).map(subscribeQuerySetId).toList()..sort(),
      [1, 2],
    );
    expect(errors, isEmpty);
    expect(stopwatch.elapsed, lessThan(_backoff * 2 + _timeout));
    await _waitUntil(
      () => writer.noteTable.iter().any((n) => n.title == 'fallback-$stamp'),
    );
    expect(
      _noteKeys(manager.cache.getTableByTypedName<Note>('note')),
      _noteKeys(writer.noteTable),
    );
    expect(
      _folderKeys(manager.cache.getTableByTypedName<Folder>('folder')),
      _folderKeys(writer.folderTable),
    );

    final reconnected = connection.onStateChanged
        .where((state) => state is Connected)
        .first;
    closeForReconnect(connection, 'test: force a third reconnect');
    await reconnected.timeout(_timeout);
    await _waitUntil(() => manager.subscriptionsReady.value);

    expect(channels, hasLength(4));
    expect(sentWithTag(channels[3].sent, subscribeBatchTag), isEmpty);
    expect(sentWithTag(channels[3].sent, subscribeTag), hasLength(2));
  });
}
