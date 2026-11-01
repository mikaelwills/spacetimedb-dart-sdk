import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:spacetimedb_sdk/codegen.dart';
import 'package:spacetimedb_sdk/src/connection/spacetimedb_connection.dart'
    show closeForReconnect;
import 'package:spacetimedb_sdk/src/connection/websocket.dart' as ws;
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../generated/folder.dart';
import '../generated/note.dart';
import '../helpers/integration_test_helper.dart';
import '../helpers/test_env.dart';

const _timeout = Duration(seconds: 10);
const _subscribeUrl = 'ws://localhost:3000/v1/database/notesdb/subscribe';
const _sessionBusy = 4000;
const _sessionBusyFloor = Duration(milliseconds: 500);

class _RecordingSink implements WebSocketSink {
  _RecordingSink(this._inner, this.sent);

  final WebSocketSink Function() _inner;
  final List<Uint8List> sent;

  @override
  void add(dynamic data) {
    if (data is Uint8List) sent.add(data);
    _inner().add(data);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _inner().addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<dynamic> stream) => stream.forEach(add);

  @override
  Future<void> get done => _inner().done;

  @override
  Future<void> close([int? closeCode, String? closeReason]) =>
      _inner().close(closeCode, closeReason);
}

class _RecordingChannel extends StreamChannelMixin<dynamic>
    implements WebSocketChannel {
  _RecordingChannel({
    required this.uri,
    required this.dialedAt,
    required this._open,
  }) {
    _sink = _RecordingSink(() => _inner!.sink, <Uint8List>[]);
  }

  final Uri uri;
  final Duration dialedAt;
  Duration? closedAt;
  final Future<WebSocketChannel> Function() _open;
  late final _RecordingSink _sink;
  WebSocketChannel? _inner;
  Future<void>? _ready;

  List<Uint8List> get sent => _sink.sent;

  String? get sessionId => uri.queryParameters['session_id'];

  @override
  String? get protocol => _inner?.protocol;

  @override
  int? get closeCode => _inner?.closeCode;

  @override
  String? get closeReason => _inner?.closeReason;

  @override
  Future<void> get ready => _ready ??= _connect();

  @override
  Stream<dynamic> get stream => _inner!.stream.transform(
    StreamTransformer.fromHandlers(
      handleDone: (sink) {
        closedAt = _clock.elapsed;
        sink.close();
      },
    ),
  );

  @override
  WebSocketSink get sink => _sink;

  Future<void> _connect() async {
    final inner = await _open();
    _inner = inner;
    await inner.ready;
  }
}

final _clock = Stopwatch()..start();

class _Holder {
  _Holder(this._uri, this._protocols, this._headers);

  final Uri _uri;
  final Iterable<String>? _protocols;
  final Map<String, dynamic>? _headers;
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;

  Future<void> take() async {
    for (var tries = 0; tries < 20; tries++) {
      if (await _tryOnce()) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    fail('the holder never got the session');
  }

  Future<void> close() async {
    await _subscription?.cancel();
    await _channel?.sink.close().timeout(
      const Duration(seconds: 1),
      onTimeout: () {},
    );
  }

  Future<bool> _tryOnce() async {
    final channel = ws.connectWebSocket(_uri, _protocols, _headers);
    await channel.ready;
    final firstFrame = Completer<bool>();
    _subscription = channel.stream.listen(
      (_) {
        if (!firstFrame.isCompleted) firstFrame.complete(true);
      },
      onDone: () {
        if (!firstFrame.isCompleted) firstFrame.complete(false);
      },
    );
    final held = await firstFrame.future.timeout(_timeout);
    if (held) {
      _channel = channel;
      return true;
    }
    expect(channel.closeCode, _sessionBusy);
    return false;
  }
}

Future<String> _anonymousToken() async {
  final channel = ws.connectWebSocket(
    Uri.parse('$_subscribeUrl?compression=None'),
    const ['v2.bsatn.spacetimedb'],
    null,
  );
  await channel.ready;
  final frame = await channel.stream.first.timeout(_timeout);
  await channel.sink.close();
  final bytes = switch (frame) {
    Uint8List() => frame,
    List<int>() => Uint8List.fromList(frame),
    _ => fail('InitialConnection was not a binary frame'),
  };
  expect(bytes[0], 0, reason: 'uncompressed frame');
  expect(bytes[1], 0, reason: 'InitialConnection tag');
  final length = ByteData.sublistView(
    bytes,
    50,
    54,
  ).getUint32(0, Endian.little);
  return utf8.decode(bytes.sublist(54, 54 + length));
}

class _Reader {
  _Reader(String token) {
    connection = SpacetimeDbConnection(
      host: 'localhost:3000',
      database: 'notesdb',
      initialToken: token,
      config: const ConnectionConfig(
        baseReconnectDelay: Duration(milliseconds: 200),
        maxReconnectDelay: Duration(milliseconds: 200),
      ),
      socketFactory:
          (
            uri,
            protocols,
            headers, {
            connectTimeout = const Duration(seconds: 10),
            pingInterval,
          }) {
            final takeover = takeoverNext;
            takeoverNext = false;
            final channel = _RecordingChannel(
              uri: uri,
              dialedAt: _clock.elapsed,
              open: () async {
                if (takeover) {
                  final holder = _Holder(uri, protocols, headers);
                  holders.add(holder);
                  await holder.take();
                  await duringGap?.call();
                }
                return ws.connectWebSocket(
                  uri,
                  protocols,
                  headers,
                  connectTimeout: connectTimeout,
                  pingInterval: pingInterval,
                );
              },
            );
            channels.add(channel);
            return channel;
          },
    );
    manager = SubscriptionManager(connection);
    manager.cache.registerDecoder<Note>('note', NoteDecoder());
    manager.cache.registerDecoder<Folder>('folder', FolderDecoder());
    connection.onStateChanged.listen((state) {
      states.add(state);
      stateTimes.add(_clock.elapsed);
    });
  }

  late final SpacetimeDbConnection connection;
  late final SubscriptionManager manager;
  final channels = <_RecordingChannel>[];
  final holders = <_Holder>[];
  final states = <ConnectionState>[];
  final stateTimes = <Duration>[];
  bool takeoverNext = false;
  Future<void> Function()? duringGap;

  TableCache<Note> get notes => manager.cache.getTableByTypedName<Note>('note');

  TableCache<Folder> get folders =>
      manager.cache.getTableByTypedName<Folder>('folder');

  Future<void> connect() async {
    final initial = manager.onInitialConnection.first;
    await connection.connect();
    await initial.timeout(_timeout);
    await Future.wait([
      manager.subscribe(['SELECT * FROM note']),
      manager.subscribe(['SELECT * FROM folder']),
    ]).timeout(_timeout);
    await _waitUntil(() => manager.subscriptionsReady.value);
  }

  Future<void> dispose() async {
    for (final holder in holders) {
      await holder.close();
    }
    await manager.dispose();
    await connection.dispose();
  }
}

Future<void> _waitUntil(bool Function() condition, {String? reason}) async {
  final deadline = DateTime.now().add(_timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail(reason ?? 'condition never held');
    }
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

  late TestEnv writer;

  setUp(() async {
    writer = await createTestEnv(registerFolder: true);
    await writer.connection.connect();
    await writer.subManager.onInitialConnection.first.timeout(_timeout);
    await writer.subManager.subscribe(['SELECT * FROM note']).timeout(_timeout);
    await writer.subManager
        .subscribe(['SELECT * FROM folder'])
        .timeout(_timeout);
  });

  tearDown(() => writer.disconnect());

  Future<int> createNote(String title) async {
    await writer.reducers
        .createNote(title: title, content: 'v1')
        .timeout(_timeout);
    await _waitUntil(
      () => writer.noteTable.iter().any((n) => n.title == title),
    );
    return writer.noteTable.iter().firstWhere((n) => n.title == title).id;
  }

  Future<void> expectCacheEqualsServer(_Reader reader) async {
    await _waitUntil(
      () =>
          reader.manager.subscriptionsReady.value &&
          _noteKeys(reader.notes).length == _noteKeys(writer.noteTable).length,
      reason: 'the reader never caught up with the server',
    );
    expect(_noteKeys(reader.notes), _noteKeys(writer.noteTable));
    expect(_folderKeys(reader.folders), _folderKeys(writer.folderTable));
  }

  test('a reconnect while the server holds the session is refused with '
      '4000, then ends Connected with the cache equal to the server', () async {
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final changedId = await createNote('takeover-changed-$stamp');

    final reader = _Reader(await _anonymousToken());
    addTearDown(reader.dispose);
    await reader.connect();
    expect(
      reader.notes.iter().any((n) => n.title == 'takeover-changed-$stamp'),
      isTrue,
    );

    final gapTitle = 'takeover-gap-$stamp';
    reader.duringGap = () async {
      await writer.reducers
          .updateNote(
            noteId: changedId,
            title: 'takeover-changed-$stamp',
            content: 'v2',
          )
          .timeout(_timeout);
      await writer.reducers
          .createNote(title: gapTitle, content: 'gap')
          .timeout(_timeout);
      await writer.reducers
          .createFolder(path: '/takeover/$stamp', name: 'f')
          .timeout(_timeout);
    };
    reader.takeoverNext = true;
    closeForReconnect(reader.connection, 'test: drop for takeover');

    await _waitUntil(
      () => reader.channels.length >= 2 && reader.channels[1].closedAt != null,
      reason: 'the takeover dial never closed',
    );
    final takeover = reader.channels[1];
    expect(takeover.closeCode, _sessionBusy);
    expect(takeover.closeReason, 'session busy');

    await _waitUntil(
      () =>
          reader.channels.length >= 3 &&
          reader.connection.state is Connected &&
          reader.channels.last.closedAt == null,
      reason: 'never Connected on a later socket',
    );
    await _waitUntil(
      () => writer.noteTable.iter().any((n) => n.title == gapTitle),
    );
    await expectCacheEqualsServer(reader);
    expect(
      reader.notes.iter().firstWhere((n) => n.id == changedId).content,
      'v2',
    );
    expect(reader.notes.iter().any((n) => n.title == gapTitle), isTrue);
    expect(reader.states.whereType<FatalError>(), isEmpty);

    Reconnecting? lastReconnectingBefore(Duration at) {
      Reconnecting? found;
      for (var i = 0; i < reader.states.length; i++) {
        final state = reader.states[i];
        if (reader.stateTimes[i] > at) break;
        if (state is Reconnecting) found = state;
      }
      return found;
    }

    final refusedAt = takeover.closedAt!;
    final beforeTakeover = lastReconnectingBefore(takeover.dialedAt);
    expect(beforeTakeover?.attempt, 1);
    final afterRefusalIndex = reader.states.indexWhere(
      (state) => state is Reconnecting,
      reader.stateTimes.indexWhere((at) => at >= refusedAt),
    );
    expect(afterRefusalIndex, isNot(-1));
    final afterRefusal = reader.states[afterRefusalIndex] as Reconnecting;
    expect(afterRefusal.attempt, beforeTakeover!.attempt);
    expect(afterRefusal.nextDelay, greaterThanOrEqualTo(_sessionBusyFloor));
    final retry = reader.channels[2];
    expect(retry.dialedAt - refusedAt, greaterThanOrEqualTo(_sessionBusyFloor));

    final ids = {for (final channel in reader.channels) channel.sessionId};
    expect(ids, hasLength(1));
    expect(ids.single, matches(RegExp(r'^[0-9a-f]{32}$')));
  });

  test('no holder: a reconnect carrying session_id is accepted with no 4000 '
      'and replays to server state', () async {
    final stamp = DateTime.now().microsecondsSinceEpoch;
    await createNote('no-holder-$stamp');

    final reader = _Reader(await _anonymousToken());
    addTearDown(reader.dispose);
    await reader.connect();

    final gapTitle = 'no-holder-gap-$stamp';
    final reconnected = reader.connection.onStateChanged
        .where((state) => state is Connected)
        .first;
    closeForReconnect(reader.connection, 'test: drop with no holder');
    await reconnected.timeout(_timeout);
    await writer.reducers
        .createNote(title: gapTitle, content: 'gap')
        .timeout(_timeout);
    await _waitUntil(
      () => writer.noteTable.iter().any((n) => n.title == gapTitle),
    );
    await _waitUntil(() => reader.notes.iter().any((n) => n.title == gapTitle));

    expect(reader.channels, hasLength(2));
    expect(reader.connection.state, isA<Connected>());
    expect(
      reader.channels.map((channel) => channel.closeCode),
      isNot(contains(_sessionBusy)),
    );
    final ids = {for (final channel in reader.channels) channel.sessionId};
    expect(ids, hasLength(1));
    expect(ids.single, matches(RegExp(r'^[0-9a-f]{32}$')));
    await expectCacheEqualsServer(reader);
  });
}
