import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:spacetimedb_sdk/codegen.dart';
import 'package:spacetimedb_sdk/src/messages/message_decoder.dart';

import '../../mocks/mock_connection.dart';

const _timeout = Duration(seconds: 2);

Uint8List _subscribeApplied({required int querySetId}) {
  final encoder = BsatnEncoder();
  encoder.writeU8(0);
  encoder.writeU8(1);
  encoder.writeU32(0);
  encoder.writeU32(querySetId);
  encoder.writeU32(0);
  return encoder.toBytes();
}

Uint8List _transactionUpdateInsertingOneRow({
  required int querySetId,
  required String tableName,
}) {
  final encoder = BsatnEncoder();
  encoder.writeU8(0);
  encoder.writeU8(4);
  encoder.writeU32(1);
  encoder.writeU32(querySetId);
  encoder.writeU32(1);
  encoder.writeString(tableName);
  encoder.writeU32(1);
  encoder.writeU8(0);
  encoder.writeU8(0);
  encoder.writeU16(4);
  encoder.writeU32(4);
  encoder.writeBytes(Uint8List(4));
  encoder.writeU8(0);
  encoder.writeU16(0);
  encoder.writeU32(0);
  return encoder.toBytes();
}

class _ThrowingDecoder extends RowDecoder<String> {
  @override
  String decode(BsatnDecoder decoder) => throw StateError('row decode failed');

  @override
  dynamic getPrimaryKey(String row) => row;
}

void main() {
  late MockConnection connection;
  late SubscriptionManager manager;

  setUp(() async {
    connection = MockConnection();
    manager = SubscriptionManager(connection);
    await connection.connect();
  });

  tearDown(() async {
    await manager.dispose();
  });

  test('a frame with an unknown compression tag closes the socket', () async {
    connection.simulateIncoming(Uint8List.fromList([3]));
    await pumpEventQueue();

    expect(connection.closeForReconnectReasons, hasLength(1));
    expect(
      connection.closeForReconnectReasons.single,
      contains('Unknown compression tag: 3'),
    );
  });

  test('a truncated message body closes the socket', () async {
    connection.simulateIncoming(Uint8List.fromList([0, 1, 0]));
    await pumpEventQueue();

    expect(connection.closeForReconnectReasons, hasLength(1));
  });

  test('a valid frame leaves the socket open', () async {
    final subscribed = manager.subscribe(['SELECT * FROM notes']);
    connection.simulateIncoming(_subscribeApplied(querySetId: 1));
    await subscribed.timeout(_timeout);

    expect(connection.closeForReconnectReasons, isEmpty);
  });

  test('a failure applying a decoded frame leaves the socket open', () async {
    manager.cache.registerDecoder<String>('notes', _ThrowingDecoder());
    final subscribed = manager.subscribe(['SELECT * FROM notes']);
    connection.simulateIncoming(_subscribeApplied(querySetId: 1));
    await subscribed.timeout(_timeout);

    connection.simulateIncoming(
      _transactionUpdateInsertingOneRow(querySetId: 1, tableName: 'notes'),
    );
    await pumpEventQueue();

    expect(connection.closeForReconnectReasons, isEmpty);
  });

  group('tag 8 opens only for a well-formed SubscribeBatchApplied', () {
    final batchReply = Uint8List.fromList([0, 8, 7, 0, 0, 0, 1, 0, 0, 0]);

    Future<void> expectClosedOnce(List<int> frame) async {
      connection.simulateIncoming(Uint8List.fromList(frame));
      await pumpEventQueue();
      expect(connection.closeForReconnectReasons, hasLength(1));
      expect(manager.cache.allTables.every((t) => t.count() == 0), isTrue);
    }

    test('a tag-9 frame still closes once', () async {
      await expectClosedOnce([0, 9, 0, 0, 0, 0]);
    });

    test('a tag-8 frame with outcome tag 2 closes once', () async {
      await expectClosedOnce([...batchReply, 11, 0, 0, 0, 2]);
    });

    test('a truncated tag-8 frame closes once', () async {
      await expectClosedOnce([...batchReply, 11, 0]);
    });

    test('MessageDecoder.decodeAll still throws on tag 8', () async {
      await expectLater(
        MessageDecoder.decodeAll(
          Uint8List.fromList([0, 8, 7, 0, 0, 0, 0, 0, 0, 0]),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  test('a corrupt frame after dispose does not close the socket', () async {
    await manager.dispose();
    connection.simulateIncoming(Uint8List.fromList([3]));
    await pumpEventQueue();

    expect(connection.closeForReconnectReasons, isEmpty);
  });
}
