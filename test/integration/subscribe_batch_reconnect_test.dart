import 'dart:async';
import 'dart:typed_data';

import 'package:spacetimedb_sdk/codegen.dart';
import 'package:spacetimedb_sdk/protocol.dart';
import 'package:spacetimedb_sdk/src/connection/spacetimedb_connection.dart'
    show closeForReconnect;
import 'package:spacetimedb_sdk/src/connection/websocket.dart' as ws;
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../generated/entity.dart';
import '../generated/folder.dart';
import '../generated/note.dart';
import '../helpers/integration_test_helper.dart';
import '../helpers/reconnect_replay.dart';
import '../helpers/test_env.dart';

const _timeout = Duration(seconds: 10);

class _RecordingSink implements WebSocketSink {
  _RecordingSink(this._inner, this.sent);

  final WebSocketSink _inner;
  final List<Uint8List> sent;

  @override
  void add(dynamic data) {
    if (data is Uint8List) sent.add(data);
    _inner.add(data);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _inner.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<dynamic> stream) => stream.forEach(add);

  @override
  Future<void> get done => _inner.done;

  @override
  Future<void> close([int? closeCode, String? closeReason]) =>
      _inner.close(closeCode, closeReason);
}

class _RecordingChannel extends StreamChannelMixin<dynamic>
    implements WebSocketChannel {
  _RecordingChannel(this._inner, this._gate)
    : _sink = _RecordingSink(_inner.sink, <Uint8List>[]);

  final WebSocketChannel _inner;
  final Future<void>? _gate;
  final _RecordingSink _sink;

  List<Uint8List> get sent => _sink.sent;

  @override
  String? get protocol => _inner.protocol;

  @override
  int? get closeCode => _inner.closeCode;

  @override
  String? get closeReason => _inner.closeReason;

  @override
  Future<void> get ready async {
    await _gate;
    await _inner.ready;
  }

  @override
  Stream<dynamic> get stream => _inner.stream;

  @override
  WebSocketSink get sink => _sink;
}

class _Reader {
  _Reader(String protocol) {
    connection = SpacetimeDbConnection(
      host: 'localhost:3000',
      database: 'notesdb',
      config: const ConnectionConfig(
        baseReconnectDelay: Duration(milliseconds: 100),
        maxReconnectDelay: Duration(milliseconds: 100),
      ),
      socketFactory:
          (
            uri,
            protocols,
            headers, {
            connectTimeout = const Duration(seconds: 10),
            pingInterval,
          }) {
            final channel = _RecordingChannel(
              ws.connectWebSocket(
                uri,
                [protocol],
                headers,
                connectTimeout: connectTimeout,
                pingInterval: pingInterval,
              ),
              nextGate?.future,
            );
            nextGate = null;
            channels.add(channel);
            return channel;
          },
    );
    manager = SubscriptionManager(connection);
    manager.cache.registerDecoder<Note>('note', NoteDecoder());
    manager.cache.registerDecoder<Folder>('folder', FolderDecoder());
    manager.cache.registerDecoder<Entity>('entity', EntityDecoder());
    manager.subscriptionsReady.addListener(
      () => readyTransitions.add(manager.subscriptionsReady.value),
    );
    manager.onSubscriptionError.listen(errors.add);
  }

  late final SpacetimeDbConnection connection;
  late final SubscriptionManager manager;
  final channels = <_RecordingChannel>[];
  final readyTransitions = <bool>[];
  final errors = <SubscriptionErrorMessage>[];
  Completer<void>? nextGate;

  TableCache<Note> get notes => manager.cache.getTableByTypedName<Note>('note');

  TableCache<Folder> get folders =>
      manager.cache.getTableByTypedName<Folder>('folder');

  Future<void> connect() async {
    final initial = manager.onInitialConnection.first;
    await connection.connect();
    await initial.timeout(_timeout);
  }

  Future<void> forceReconnect() async {
    final reconnected = connection.onStateChanged
        .where((state) => state is Connected)
        .first;
    closeForReconnect(connection, 'test: force a reconnect');
    await reconnected.timeout(_timeout);
  }

  Future<void> dispose() async {
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

  for (final protocol in ['v3.bsatn.spacetimedb', 'v2.bsatn.spacetimedb']) {
    group(protocol, () {
      late TestEnv writer;

      setUp(() async {
        writer = await createTestEnv(registerFolder: true);
        await writer.connection.connect();
        await writer.subManager.onInitialConnection.first.timeout(_timeout);
        await writer.subManager
            .subscribe(['SELECT * FROM note'])
            .timeout(_timeout);
        await writer.subManager
            .subscribe(['SELECT * FROM folder'])
            .timeout(_timeout);
      });

      tearDown(() => writer.disconnect());

      test('a reconnect replays every set in one SubscribeBatch and '
          'reconciles to server state', () async {
        final stamp = DateTime.now().microsecondsSinceEpoch;
        Future<int> createNote(String title) async {
          await writer.reducers
              .createNote(title: title, content: 'v1')
              .timeout(_timeout);
          await _waitUntil(
            () => writer.noteTable.iter().any((n) => n.title == title),
          );
          return writer.noteTable.iter().firstWhere((n) => n.title == title).id;
        }

        final deletedId = await createNote('deleted-$stamp');
        final changedId = await createNote('changed-$stamp');
        await createNote('untouched-$stamp');
        await writer.reducers
            .createFolder(path: '/batch/$stamp', name: 'f')
            .timeout(_timeout);

        final reader = _Reader(protocol);
        addTearDown(reader.dispose);
        await reader.connect();
        expect(
          reader.connection.negotiatedProtocol.name,
          protocol[1] == '3' ? 'v3' : 'v2',
        );
        await Future.wait([
          reader.manager.subscribe(['SELECT * FROM note']),
          reader.manager.subscribe(['SELECT * FROM folder']),
          reader.manager.subscribe(['SELECT * FROM entity']),
        ]).timeout(_timeout);
        await _waitUntil(() => reader.manager.subscriptionsReady.value);
        reader.readyTransitions.clear();

        final updates = <TableUpdateEvent<Note>>[];
        final deletes = <TableDeleteEvent<Note>>[];
        final inserts = <TableInsertEvent<Note>>[];
        reader.notes.onUpdate.listen(updates.add);
        reader.notes.onDelete.listen(deletes.add);
        reader.notes.onInsert.listen(inserts.add);

        final gate = Completer<void>();
        reader.nextGate = gate;
        final reconnected = reader.connection.onStateChanged
            .where((state) => state is Connected)
            .first;
        closeForReconnect(reader.connection, 'test: force a reconnect');
        await _waitUntil(() => reader.channels.length == 2);

        await writer.reducers
            .updateNote(
              noteId: changedId,
              title: 'changed-$stamp',
              content: 'v2',
            )
            .timeout(_timeout);
        await writer.reducers.deleteNote(noteId: deletedId).timeout(_timeout);

        gate.complete();
        await reconnected.timeout(_timeout);
        final concurrentTitle = 'concurrent-$stamp';
        final concurrent = writer.reducers.createNote(
          title: concurrentTitle,
          content: 'during replay',
        );
        await _waitUntil(() => reader.manager.subscriptionsReady.value);
        await concurrent.timeout(_timeout);
        await _waitUntil(
          () =>
              reader.notes.iter().any((n) => n.title == concurrentTitle) &&
              writer.noteTable.iter().any((n) => n.title == concurrentTitle),
        );
        await Future<void>.delayed(const Duration(milliseconds: 200));

        final replay = reader.channels.last.sent;
        final batches = sentWithTag(replay, subscribeBatchTag);
        expect(batches, hasLength(1));
        expect(batchQuerySetIds(batches.single).toSet(), {1, 2, 3});
        expect(sentWithTag(replay, subscribeTag), isEmpty);
        expect(reader.readyTransitions, [false, true]);
        expect(
          reader.channels,
          hasLength(2),
          reason: 'no decode-failure close',
        );
        expect(reader.errors, isEmpty);

        expect(_noteKeys(reader.notes), _noteKeys(writer.noteTable));
        expect(_folderKeys(reader.folders), _folderKeys(writer.folderTable));
        expect(updates.where((e) => e.newRow.id == changedId), hasLength(1));
        expect(deletes.map((e) => e.row.id), [deletedId]);
        expect([
          ...updates.map((e) => e.newRow.title),
          ...inserts.map((e) => e.row.title),
        ], isNot(contains('untouched-$stamp')));
      });

      test('a reconnect with no query sets sends no SubscribeBatch', () async {
        final reader = _Reader(protocol);
        addTearDown(reader.dispose);
        await reader.connect();

        await reader.forceReconnect();
        await Future<void>.delayed(const Duration(milliseconds: 300));

        expect(
          sentWithTag(reader.channels.last.sent, subscribeBatchTag),
          isEmpty,
        );
      });
    });
  }
}
