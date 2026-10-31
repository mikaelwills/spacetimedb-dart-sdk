import 'package:test/test.dart';
import 'package:spacetimedb_sdk/spacetimedb_sdk.dart';
import 'package:spacetimedb_sdk/src/connection/spacetimedb_connection.dart'
    show closeForReconnect;

import '../../mocks/silent_socket.dart';

void main() {
  test('closeForReconnect closes the socket and the reconnect ladder builds a '
      'fresh one', () async {
    final sockets = <SilentWebSocketChannel>[];
    final states = <ConnectionState>[];

    final connection = SpacetimeDbConnection(
      host: 'localhost:3000',
      database: 'notesdb',
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
            final socket = SilentWebSocketChannel();
            sockets.add(socket);
            return socket;
          },
    );
    addTearDown(connection.dispose);

    final sub = connection.onStateChanged.listen(states.add);
    addTearDown(sub.cancel);

    await connection.connect();
    final reconnected = connection.onStateChanged
        .where((state) => state is Connected)
        .first;
    closeForReconnect(connection, 'test');
    await reconnected.timeout(const Duration(seconds: 2));

    expect(sockets.first.closeCalls, 1);
    expect(states.whereType<Reconnecting>(), isNotEmpty);
    expect(sockets, hasLength(2));
  });

  test('with auto-reconnect off, closeForReconnect closes the socket and does '
      'not build another', () async {
    final sockets = <SilentWebSocketChannel>[];

    final connection = SpacetimeDbConnection(
      host: 'localhost:3000',
      database: 'notesdb',
      config: const ConnectionConfig(
        autoReconnect: false,
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
            final socket = SilentWebSocketChannel();
            sockets.add(socket);
            return socket;
          },
    );
    addTearDown(connection.dispose);

    await connection.connect();
    closeForReconnect(connection, 'test');
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(sockets.single.closeCalls, 1);
    expect(connection.state, isA<Reconnecting>());
  });
}
