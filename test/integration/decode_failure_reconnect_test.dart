import 'dart:async';
import 'dart:typed_data';

import 'package:spacetimedb_sdk/codegen.dart';
import 'package:spacetimedb_sdk/src/connection/websocket.dart' as ws;
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../generated/note.dart';
import '../helpers/integration_test_helper.dart';
import '../helpers/test_env.dart';

class _CorruptingChannel extends StreamChannelMixin<dynamic>
    implements WebSocketChannel {
  _CorruptingChannel(this._inner) {
    _inner.stream.listen(
      (data) {
        if (!corruptNextFrame) {
          _inbound.add(data);
          return;
        }
        corruptNextFrame = false;
        _inbound.add(Uint8List.fromList([3]));
      },
      onError: _inbound.addError,
      onDone: _inbound.close,
    );
  }

  final WebSocketChannel _inner;
  final StreamController<dynamic> _inbound = StreamController<dynamic>();
  bool corruptNextFrame = false;

  @override
  String? get protocol => _inner.protocol;

  @override
  int? get closeCode => _inner.closeCode;

  @override
  String? get closeReason => _inner.closeReason;

  @override
  Future<void> get ready => _inner.ready;

  @override
  Stream<dynamic> get stream => _inbound.stream;

  @override
  WebSocketSink get sink => _inner.sink;
}

Future<void> _waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('condition never held');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  setUpAll(ensureTestEnvironment);
  tearDownAll(cleanupTestEnvironment);

  test(
    'a corrupt TransactionUpdate frame closes the socket, and the resubscribe '
    'brings the cache back in line with the server',
    () async {
      final channels = <_CorruptingChannel>[];
      final connection = SpacetimeDbConnection(
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
              final channel = _CorruptingChannel(
                ws.connectWebSocket(
                  uri,
                  protocols,
                  headers,
                  connectTimeout: connectTimeout,
                  pingInterval: pingInterval,
                ),
              );
              channels.add(channel);
              return channel;
            },
      );
      final subManager = SubscriptionManager(connection);
      subManager.cache.registerDecoder<Note>('note', NoteDecoder());
      addTearDown(() async {
        await subManager.dispose();
        await connection.dispose();
      });

      final writer = await createTestEnv();
      addTearDown(writer.disconnect);
      await writer.connection.connect();
      await writer.subManager.onInitialConnection.first.timeout(
        const Duration(seconds: 5),
      );
      await writer.subManager
          .subscribe(['SELECT * FROM note'])
          .timeout(const Duration(seconds: 5));

      final initialConnection = subManager.onInitialConnection.first;
      await connection.connect();
      await initialConnection.timeout(const Duration(seconds: 5));
      await subManager
          .subscribe(['SELECT * FROM note'])
          .timeout(const Duration(seconds: 5));
      final notes = subManager.cache.getTableByTypedName<Note>('note');

      final reconnected = connection.onStateChanged
          .where((state) => state is Connected)
          .first;
      final title = 'decode-fail-${DateTime.now().microsecondsSinceEpoch}';
      channels.single.corruptNextFrame = true;
      await writer.reducers
          .createNote(title: title, content: 'lost in a corrupt frame')
          .timeout(const Duration(seconds: 5));

      await reconnected.timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail(
          'a decode failure must close the socket and reconnect; '
          'state is still ${connection.state} on ${channels.length} socket(s)',
        ),
      );
      expect(channels.length, 2, reason: 'the reconnect built a fresh socket');

      await _waitUntil(() => subManager.subscriptionsReady.value);
      expect(
        notes.iter().map((n) => n.title),
        contains(title),
        reason:
            'the resubscribe snapshot carries the row the corrupt frame lost',
      );
      expect(
        notes.count(),
        writer.noteTable.count(),
        reason: 'the cache matches the server after the resubscribe',
      );
    },
  );
}
