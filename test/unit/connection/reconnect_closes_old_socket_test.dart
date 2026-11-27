import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';
import 'package:spacetimedb_sdk/spacetimedb_sdk.dart';

import '../../mocks/silent_socket.dart';

const _host = 'localhost:3000';
const _database = 'notesdb';
const _socketReset = 'socket reset';
const _defaultConnectTimeout = Duration(seconds: 10);

class _Recorder {
  final sockets = <SilentWebSocketChannel>[];
  final oldClosedWhenNewOpened = <bool>[];

  bool get _previousSocketClosed =>
      sockets.isEmpty || sockets.last.closeCalls > 0;

  SilentWebSocketChannel open(Uri uri) {
    oldClosedWhenNewOpened.add(_previousSocketClosed);
    final socket = SilentWebSocketChannel();
    sockets.add(socket);
    return socket;
  }

  int get firstSocketCloseCalls => sockets.first.closeCalls;
}

SpacetimeDbConnection _connection(_Recorder recorder) => SpacetimeDbConnection(
  host: _host,
  database: _database,
  socketFactory: (
    uri,
    protocols,
    headers, {
    connectTimeout = _defaultConnectTimeout,
    pingInterval,
  }) => recorder.open(uri),
);

void main() {
  group('reconnect', () {
    test('the old channel is closed before the new one opens', () {
      fakeAsync((async) {
        final recorder = _Recorder();
        final connection = _connection(recorder);

        connection.connect();
        async.flushMicrotasks();
        recorder.sockets.single.fail(_socketReset);
        async.flushMicrotasks();
        connection.connect();
        async.flushMicrotasks();

        expect(recorder.sockets, hasLength(2));
        expect(recorder.oldClosedWhenNewOpened, [true, true]);
        expect(recorder.firstSocketCloseCalls, 1);
      });
    });
  });
}
