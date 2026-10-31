import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:spacetimedb_sdk/codegen.dart';

import '../../mocks/silent_socket.dart';

Uint8List _reducerResultOkEmpty({required int requestId}) {
  final encoder = BsatnEncoder();
  encoder.writeU8(0);
  encoder.writeU8(6);
  encoder.writeU32(requestId);
  encoder.writeU64(Int64(0));
  encoder.writeU8(1);
  return encoder.toBytes();
}

void main() {
  test('a reducer result received just before the socket closes completes '
      'the call', () async {
    final sockets = <SilentWebSocketChannel>[];
    final connection = SpacetimeDbConnection(
      host: 'localhost:3000',
      database: 'notesdb',
      config: const ConnectionConfig(
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
    final manager = SubscriptionManager(connection);
    addTearDown(() async {
      await manager.dispose();
      await connection.dispose();
    });

    await connection.connect();
    await pumpEventQueue();

    final call = manager.reducers.callWithBytes('do_thing', Uint8List(0));

    sockets.first.deliver(_reducerResultOkEmpty(requestId: 1));
    await sockets.first.sink.close();

    final result = await call.timeout(const Duration(seconds: 2));
    expect(result.isSuccess, isTrue);
  });
}
