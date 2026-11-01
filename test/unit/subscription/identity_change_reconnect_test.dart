import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:spacetimedb_sdk/codegen.dart';

import '../../mocks/silent_socket.dart';

const _timeout = Duration(seconds: 2);
const _settle = Duration(milliseconds: 150);
const _table = 'notes';

final _identityA = Uint8List(32)..fillRange(0, 32, 0xa);
final _identityB = Uint8List(32)..fillRange(0, 32, 0xb);

Uint8List _initialConnectionBody(Uint8List identity) {
  final encoder = BsatnEncoder();
  encoder.writeU8(0);
  encoder.writeBytes(identity);
  encoder.writeBytes(Uint8List(16));
  encoder.writeString('token-for-${identity.first}');
  return encoder.toBytes();
}

Uint8List _subscribeAppliedBody({required int querySetId, required int id}) {
  final rows = BsatnEncoder()..writeU32(id);
  final rowBytes = rows.toBytes();
  final encoder = BsatnEncoder();
  encoder.writeU8(1);
  encoder.writeU32(0);
  encoder.writeU32(querySetId);
  encoder.writeU32(1);
  encoder.writeString(_table);
  encoder.writeU8(0);
  encoder.writeU16(4);
  encoder.writeU32(rowBytes.length);
  encoder.writeBytes(rowBytes);
  return encoder.toBytes();
}

Uint8List _frame(List<Uint8List> bodies) {
  final out = BytesBuilder()..addByte(0);
  for (final body in bodies) {
    out.add(body);
  }
  return out.toBytes();
}

class _IdDecoder extends RowDecoder<int> {
  @override
  int decode(BsatnDecoder decoder) => decoder.readU32();

  @override
  dynamic getPrimaryKey(int row) => row;
}

class _Harness {
  _Harness({String? initialToken}) {
    connection = SpacetimeDbConnection(
      host: 'localhost:3000',
      database: 'notesdb',
      initialToken: initialToken,
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
    manager = SubscriptionManager(connection);
    manager.cache.registerDecoder<int>(_table, _IdDecoder());
    manager.onInitialConnection.listen((_) => initialConnections++);
    manager.onSubscribeApplied.listen((_) => subscribeApplied++);
  }

  late final SpacetimeDbConnection connection;
  late final SubscriptionManager manager;
  final sockets = <SilentWebSocketChannel>[];
  var initialConnections = 0;
  var subscribeApplied = 0;

  TableCache<int> get notes => manager.cache.getTableByTypedName<int>(_table);

  Future<void> dispose() async {
    await manager.dispose();
    await connection.dispose();
  }

  Future<void> connectAs(Uint8List identity) async {
    await connection.connect();
    await pumpEventQueue();
    final received = manager.onInitialConnection.first.timeout(_timeout);
    sockets.last.deliver(_frame([_initialConnectionBody(identity)]));
    await received;
  }

  Future<void> dropAndAwaitReconnect() async {
    final reconnected = connection.onStateChanged
        .where((state) => state is Connected)
        .first
        .timeout(_timeout);
    await sockets.last.sink.close();
    await reconnected;
    await pumpEventQueue();
  }
}

Future<void> _settleFrames() async {
  await Future<void>.delayed(_settle);
  await pumpEventQueue();
}

void main() {
  test('a reconnect that presents a token and comes back with a different '
      'identity ends in FatalError and applies nothing', () async {
    final harness = _Harness(initialToken: 'tok');
    addTearDown(harness.dispose);

    await harness.connectAs(_identityA);
    final subscribed = harness.manager.subscribe(['SELECT * FROM $_table']);
    harness.sockets.last.deliver(
      _frame([_subscribeAppliedBody(querySetId: 1, id: 1)]),
    );
    await subscribed.timeout(_timeout);
    expect(harness.manager.identity, Identity(_identityA));

    await harness.dropAndAwaitReconnect();
    harness.sockets.last.deliver(
      _frame([
        _initialConnectionBody(_identityB),
        _subscribeAppliedBody(querySetId: 1, id: 2),
      ]),
    );
    await _settleFrames();

    final state = harness.connection.state;
    expect(state, isA<FatalError>());
    expect((state as FatalError).message, contains('different identity'));
    expect(harness.manager.identity, Identity(_identityA));
    expect(harness.initialConnections, 1);
    expect(harness.subscribeApplied, 1);
    expect(harness.notes.find(2), isNull);
    expect(harness.sockets, hasLength(2));
    expect(harness.sockets.last.closeCalls, 1);
  });

  test('a reconnect that presents no token accepts a new identity', () async {
    final harness = _Harness();
    addTearDown(harness.dispose);

    await harness.connectAs(_identityA);
    harness.connection.clearToken();
    await harness.connection.reconnect();
    await pumpEventQueue();
    final received = harness.manager.onInitialConnection.first.timeout(
      _timeout,
    );
    harness.sockets.last.deliver(_frame([_initialConnectionBody(_identityB)]));
    await received;

    expect(harness.connection.state, isA<Connected>());
    expect(harness.manager.identity, Identity(_identityB));
    expect(harness.initialConnections, 2);
  });

  test('a first connect with a token accepts any identity', () async {
    final harness = _Harness(initialToken: 'tok');
    addTearDown(harness.dispose);

    await harness.connectAs(_identityB);

    expect(harness.connection.state, isA<Connected>());
    expect(harness.manager.identity, Identity(_identityB));
  });

  test('a reconnect that presents a token and keeps its identity stays '
      'connected', () async {
    final harness = _Harness(initialToken: 'tok');
    addTearDown(harness.dispose);

    await harness.connectAs(_identityA);
    await harness.dropAndAwaitReconnect();
    final received = harness.manager.onInitialConnection.first.timeout(
      _timeout,
    );
    harness.sockets.last.deliver(_frame([_initialConnectionBody(_identityA)]));
    await received;

    expect(harness.connection.state, isA<Connected>());
    expect(harness.manager.identity, Identity(_identityA));
    expect(harness.initialConnections, 2);
  });
}
