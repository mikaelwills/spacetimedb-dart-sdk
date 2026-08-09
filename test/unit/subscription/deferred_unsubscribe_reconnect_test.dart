import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:spacetimedb_sdk/codegen.dart';

import '../../mocks/mock_connection.dart';

const _timeout = Duration(seconds: 2);

class _SendGatedMockConnection extends MockConnection {
  @override
  void send(Uint8List data) {
    if (!isConnected) return;
    super.send(data);
  }
}

Uint8List _createSubscribeApplied({
  required int requestId,
  required int querySetId,
  Map<String, List<String>> rowsByTable = const {},
}) {
  final encoder = BsatnEncoder();
  encoder.writeU8(0);
  encoder.writeU8(1);
  encoder.writeU32(requestId);
  encoder.writeU32(querySetId);
  encoder.writeU32(rowsByTable.length);
  for (final entry in rowsByTable.entries) {
    encoder.writeString(entry.key);
    encoder.writeU8(0);
    final rowsEncoder = BsatnEncoder();
    for (final row in entry.value) {
      rowsEncoder.writeString(row);
    }
    final rowsData = rowsEncoder.toBytes();
    final rowSize =
        entry.value.isEmpty ? 0 : rowsData.length ~/ entry.value.length;
    encoder.writeU16(rowSize);
    encoder.writeU32(rowsData.length);
    encoder.writeBytes(rowsData);
  }
  return encoder.toBytes();
}

class _StringDecoder extends RowDecoder<String> {
  @override
  String decode(BsatnDecoder decoder) => decoder.readString();

  @override
  dynamic getPrimaryKey(String row) => row;
}

int _sentQuerySetId(Uint8List sent) {
  expect(sent[0], 0, reason: 'expected a Subscribe message (tag 0)');
  return sent[5] | (sent[6] << 8) | (sent[7] << 16) | (sent[8] << 24);
}

Iterable<Uint8List> _subscribeFrames(List<Uint8List> sent) =>
    sent.where((m) => m[0] == 0);

void main() {
  group('unsubscribe while disconnected drops the set from the resubscribe '
      'batch', () {
    late _SendGatedMockConnection mockConnection;
    late SubscriptionManager subscriptionManager;

    setUp(() {
      mockConnection = _SendGatedMockConnection();
      subscriptionManager = SubscriptionManager(mockConnection);
    });

    tearDown(() async {
      await subscriptionManager.dispose();
    });

    test('a set unsubscribed while disconnected is NOT revived on reconnect',
        () async {
      await mockConnection.connect();

      final futures = [
        subscriptionManager.subscribe(['SELECT * FROM globals']),
        subscriptionManager.subscribe([
          "SELECT * FROM message WHERE agent_id = 'a1'",
        ]),
      ];
      for (var id = 1; id <= 2; id++) {
        mockConnection.simulateIncoming(
          _createSubscribeApplied(requestId: 0, querySetId: id),
        );
      }
      await Future.wait(futures).timeout(_timeout);
      expect(subscriptionManager.subscriptionsReady.value, isTrue);

      await mockConnection.disconnect();
      await pumpEventQueue();
      expect(mockConnection.isConnected, isFalse);

      subscriptionManager.unsubscribe(2);

      expect(
        subscriptionManager.subscriptionsByQuerySetId.keys.toSet(),
        {1},
        reason:
            'unsubscribe removes local state unconditionally; the wire send '
            'is the only part gated on the socket',
      );

      mockConnection.clearSent();
      await mockConnection.connect();
      await pumpEventQueue();

      final resubscribed =
          _subscribeFrames(mockConnection.sentMessages).map(_sentQuerySetId);
      expect(
        resubscribed,
        isNot(contains(2)),
        reason:
            'the set unsubscribed while disconnected must not be revived by '
            '_onReconnected; reviving it creates a duplicate query set with '
            'byte-identical queries alongside any live set for the same agent',
      );
      expect(resubscribed.toSet(), {1});
    });

    test('deferred unsubscribe leaves the live set\'s rows intact when the '
        'duplicate answers with a STIPULATED empty SubscribeApplied',
        () async {
      subscriptionManager.cache.registerDecoder<String>(
        'message',
        _StringDecoder(),
      );

      await mockConnection.connect();

      final first = subscriptionManager.subscribe([
        "SELECT * FROM message WHERE agent_id = 'a1'",
      ]);
      mockConnection.simulateIncoming(
        _createSubscribeApplied(
          requestId: 0,
          querySetId: 1,
          rowsByTable: {
            'message': ['m1', 'm2'],
          },
        ),
      );
      await first.timeout(_timeout);

      await mockConnection.disconnect();
      await pumpEventQueue();

      subscriptionManager.unsubscribe(1);

      await mockConnection.connect();
      await pumpEventQueue();

      final second = subscriptionManager.subscribe([
        "SELECT * FROM message WHERE agent_id = 'a1'",
      ]);
      mockConnection.simulateIncoming(
        _createSubscribeApplied(
          requestId: 0,
          querySetId: 2,
          rowsByTable: {
            'message': ['m1', 'm2'],
          },
        ),
      );
      await second.timeout(_timeout);

      await mockConnection.disconnect();
      await pumpEventQueue();
      mockConnection.clearSent();
      await mockConnection.connect();
      await pumpEventQueue();

      final revivedIds =
          _subscribeFrames(mockConnection.sentMessages).map(_sentQuerySetId);
      expect(
        revivedIds,
        isNot(contains(1)),
        reason: 'set 1 was unsubscribed while disconnected',
      );

      mockConnection.simulateIncoming(
        _createSubscribeApplied(
          requestId: 0,
          querySetId: 2,
          rowsByTable: {
            'message': ['m1', 'm2'],
          },
        ),
      );
      await pumpEventQueue();

      final message = subscriptionManager.cache.getTableByName('message');
      if (message == null) fail('message table not registered');
      expect(
        message.iter(),
        containsAll(['m1', 'm2']),
        reason:
            'with no duplicate set in the batch, the live set re-delivers '
            'every row and _evictReconnectDeletes evicts nothing',
      );
    });
  });
}
