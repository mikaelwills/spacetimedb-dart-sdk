import 'package:test/test.dart';
import 'package:spacetimedb_sdk/spacetimedb_sdk.dart';

import '../../mocks/silent_socket.dart';

void main() {
  test(
    'a keep-alive-detected stale socket flows into the existing reconnect path',
    () async {
      final sockets = <SilentWebSocketChannel>[];
      final states = <ConnectionState>[];

      final connection = SpacetimeDbConnection(
        host: 'localhost:3000',
        database: 'notesdb',
        config: const ConnectionConfig(
          maxReconnectAttempts: 2,
          baseReconnectDelay: Duration(milliseconds: 20),
          maxReconnectDelay: Duration(milliseconds: 20),
          pingInterval: Duration(milliseconds: 40),
          pongTimeout: Duration(milliseconds: 40),
          appLevelKeepAlive: true,
        ),
        socketFactory: (
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
      await Future<void>.delayed(const Duration(milliseconds: 400));

      expect(
        sockets.first.closeCalls,
        greaterThan(0),
        reason: 'the stale socket was closed by _handleStaleConnection',
      );
      expect(
        states.whereType<Reconnecting>(),
        isNotEmpty,
        reason:
            'closing the sink lands in onDone, which drives the existing '
            '_attemptReconnect ladder — no second reconnect implementation',
      );
      expect(
        sockets.length,
        greaterThan(1),
        reason: 'the reconnect actually built a fresh socket',
      );
    },
  );
}
