import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:spacetimedb_sdk/codegen.dart';
import 'package:spacetimedb_sdk/src/messages/message_decoder.dart';
import 'package:spacetimedb_sdk/src/messages/server_messages.dart';

import '../../mocks/mock_connection.dart';

const _timeout = Duration(seconds: 2);
const _settle = Duration(milliseconds: 150);
const _table = 'notes';

void _writeRowList(BsatnEncoder encoder, List<int> ids) {
  final rows = BsatnEncoder();
  for (final id in ids) {
    rows.writeU32(id);
  }
  final data = rows.toBytes();
  encoder.writeU8(0);
  encoder.writeU16(ids.isEmpty ? 0 : 4);
  encoder.writeU32(data.length);
  encoder.writeBytes(data);
}

Uint8List _subscribeApplied({
  required int querySetId,
  List<int> ids = const [],
}) {
  final encoder = BsatnEncoder();
  encoder.writeU8(0);
  encoder.writeU8(1);
  encoder.writeU32(0);
  encoder.writeU32(querySetId);
  encoder.writeU32(1);
  encoder.writeString(_table);
  _writeRowList(encoder, ids);
  return encoder.toBytes();
}

Uint8List _transactionUpdate({
  required int querySetId,
  List<int> inserts = const [],
  List<int> deletes = const [],
}) {
  final encoder = BsatnEncoder();
  encoder.writeU8(0);
  encoder.writeU8(4);
  encoder.writeU32(1);
  encoder.writeU32(querySetId);
  encoder.writeU32(1);
  encoder.writeString(_table);
  encoder.writeU32(1);
  encoder.writeU8(0);
  _writeRowList(encoder, inserts);
  _writeRowList(encoder, deletes);
  return encoder.toBytes();
}

Uint8List _corruptFrame({required int length}) => Uint8List(length)..[0] = 3;

class _IdDecoder extends RowDecoder<int> {
  @override
  int decode(BsatnDecoder decoder) => decoder.readU32();

  @override
  dynamic getPrimaryKey(int row) => row;
}

Future<List<ServerMessage>> _decodeSlowerForLargerFrames(
  Uint8List bytes,
) async {
  await Future<void>.delayed(Duration(milliseconds: bytes.length ~/ 8));
  return MessageDecoder.decodeAll(bytes);
}

final _snapshotIds = List<int>.generate(40, (i) => 100 + i);

void main() {
  late MockConnection connection;
  late SubscriptionManager manager;
  late TableCache<int> notes;

  setUp(() async {
    connection = MockConnection();
    manager = SubscriptionManager(connection);
    manager.cache.registerDecoder<int>(_table, _IdDecoder());
    notes = manager.cache.getTableByTypedName<int>(_table);
    await connection.connect();
  });

  tearDown(() async {
    await manager.dispose();
  });

  Future<void> settle() async {
    await Future<void>.delayed(_settle);
    await pumpEventQueue();
  }

  group('frames route in arrival order', () {
    setUp(() => manager.frameDecoder = _decodeSlowerForLargerFrames);

    test(
      'a TransactionUpdate sent after the SubscribeApplied keeps its row',
      () async {
        final subscribed = manager.subscribe(['SELECT * FROM $_table']);

        connection.simulateIncoming(
          _subscribeApplied(querySetId: 1, ids: _snapshotIds),
        );
        connection.simulateIncoming(
          _transactionUpdate(querySetId: 1, inserts: [1]),
        );
        await subscribed.timeout(_timeout);
        await settle();

        expect(notes.find(1), 1);
        expect(notes.count(), _snapshotIds.length + 1);
      },
    );

    test('three frames of decreasing size apply in arrival order', () async {
      final subscribed = manager.subscribe(['SELECT * FROM $_table']);

      connection.simulateIncoming(
        _subscribeApplied(querySetId: 1, ids: _snapshotIds),
      );
      connection.simulateIncoming(
        _transactionUpdate(querySetId: 1, inserts: [1, 2, 3, 4, 5]),
      );
      connection.simulateIncoming(
        _transactionUpdate(querySetId: 1, deletes: [1]),
      );
      await subscribed.timeout(_timeout);
      await settle();

      expect(notes.primaryKeys, {..._snapshotIds, 2, 3, 4, 5});
    });

    test('a frame that fails to decode closes once and the next frame still routes', () async {
      final subscribed = manager.subscribe(['SELECT * FROM $_table']);
      connection.simulateIncoming(_subscribeApplied(querySetId: 1));
      await subscribed.timeout(_timeout);

      connection.simulateIncoming(_corruptFrame(length: 200));
      connection.simulateIncoming(
        _transactionUpdate(querySetId: 1, inserts: [1]),
      );
      await settle();

      expect(connection.closeForReconnectReasons, hasLength(1));
      expect(notes.find(1), 1);
    });
  });

  group('frames from a socket that has since been replaced', () {
    Future<void> subscribeAndApply() async {
      final subscribed = manager.subscribe(['SELECT * FROM $_table']);
      connection.simulateIncoming(_subscribeApplied(querySetId: 1));
      await subscribed.timeout(_timeout);
      manager.frameDecoder = _decodeSlowerForLargerFrames;
    }

    Future<void> reconnect() async {
      connection.mockState = const Disconnected();
      connection.mockState = const Connected();
      await pumpEventQueue();
    }

    test(
      'a decode that fails after a reconnect does not close the new socket',
      () async {
        await subscribeAndApply();

        connection.simulateIncoming(_corruptFrame(length: 200));
        await reconnect();
        await settle();

        expect(connection.closeForReconnectReasons, isEmpty);
      },
    );

    test(
      'a decode that succeeds after a reconnect does not apply its rows',
      () async {
        await subscribeAndApply();

        connection.simulateIncoming(
          _transactionUpdate(querySetId: 1, inserts: [7]),
        );
        await reconnect();
        await settle();

        expect(notes.find(7), isNull);
      },
    );

    test('a frame received after the reconnect routes normally', () async {
      await subscribeAndApply();

      await reconnect();
      connection.simulateIncoming(
        _transactionUpdate(querySetId: 1, inserts: [8]),
      );
      await settle();

      expect(notes.find(8), 8);
    });
  });
}
