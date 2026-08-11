import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:spacetimedb_sdk/codegen.dart';

import '../../mocks/mock_connection.dart';

const _timeout = Duration(seconds: 30);

const _agentAQueries = ["SELECT * FROM chat WHERE agent_id = 'a'"];
const _agentBQueries = ["SELECT * FROM chat WHERE agent_id = 'b'"];

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

Uint8List _createUnsubscribeApplied({
  required int requestId,
  required int querySetId,
}) {
  final encoder = BsatnEncoder();
  encoder.writeU8(0);
  encoder.writeU8(2);
  encoder.writeU32(requestId);
  encoder.writeU32(querySetId);
  encoder.writeU8(1);
  return encoder.toBytes();
}

class _StringDecoder extends RowDecoder<String> {
  @override
  String decode(BsatnDecoder decoder) => decoder.readString();

  @override
  dynamic getPrimaryKey(String row) => row;

  @override
  bool get supportsJsonSerialization => true;

  @override
  Map<String, dynamic>? toJson(String row) => {'v': row};

  @override
  String? fromJson(Map<String, dynamic> json) {
    final value = json['v'];
    return value is String ? value : null;
  }
}

void main() {
  late MockConnection mockConnection;
  late SubscriptionManager subscriptionManager;
  late TableCache<String> chat;

  Future<void> start({bool retain = false, OfflineStorage? storage}) async {
    mockConnection = MockConnection();
    subscriptionManager = SubscriptionManager(
      mockConnection,
      retainRowsOnUnsubscribe: retain,
      offlineStorage: storage,
    );
    subscriptionManager.cache.registerDecoder<String>('chat', _StringDecoder());
    chat = subscriptionManager.cache.getTableByTypedName<String>('chat');
    await mockConnection.connect();
  }

  tearDown(() async {
    await subscriptionManager.dispose();
  });

  Future<int> subscribeWithRows(List<String> queries, List<String> rows) async {
    final pending = subscriptionManager.subscribe(queries);
    final querySetId = subscriptionManager.subscriptionsByQuerySetId.keys.last;
    mockConnection.simulateIncoming(
      _createSubscribeApplied(
        requestId: 0,
        querySetId: querySetId,
        rowsByTable: {'chat': rows},
      ),
    );
    await pending.timeout(_timeout);
    return querySetId;
  }

  group('retain on unsubscribe (slice 1)', () {
    test('with retention enabled, a connected unsubscribe retains rows '
        'tagged with the set\'s query hash', () async {
      await start(retain: true);
      final id = await subscribeWithRows(_agentAQueries, ['a1', 'a2']);
      expect(chat.count(), 2);
      final sentBefore = mockConnection.sentMessages.length;

      subscriptionManager.unsubscribe(id);

      expect(chat.count(), 2);
      expect(
        mockConnection.sentMessages.length,
        sentBefore + 1,
        reason: 'the wire UnsubscribeMessage is still sent',
      );
      expect(
        subscriptionManager.subscriptionsByQuerySetId.containsKey(id),
        isFalse,
        reason: 'reconnect tracking is still removed',
      );
      expect(chat.ownerEntryCount, 0);
      final tag = SubscriptionManager.computeQuerySetHash(_agentAQueries);
      expect(chat.retainedTagsFor('a1'), {tag});
      expect(chat.retainedTagsFor('a2'), {tag});
    });

    test('with retention disabled (default), the same sequence evicts and '
        'counts the eviction', () async {
      await start();
      final id = await subscribeWithRows(_agentAQueries, ['a1', 'a2']);
      expect(chat.count(), 2);

      subscriptionManager.unsubscribe(id);

      expect(chat.count(), 0);
      expect(chat.retainedTagEntryCount, 0);
      expect(chat.unsubscribeEvictionCount, 2);
    });

    test('forgetQuerySet with retention converts owners to tags, so the '
        'deferred unsubscribe replay evicts nothing', () async {
      await start(retain: true);
      final id = await subscribeWithRows(_agentAQueries, ['a1', 'a2']);
      expect(chat.count(), 2);

      subscriptionManager.forgetQuerySet(id);
      expect(chat.count(), 2);
      expect(chat.ownerEntryCount, 0);
      final tag = SubscriptionManager.computeQuerySetHash(_agentAQueries);
      expect(chat.retainedTagsFor('a1'), {tag});

      subscriptionManager.unsubscribe(id);

      expect(chat.count(), 2);
      expect(chat.retainedTagsFor('a1'), {tag});
    });

    test('the server\'s UnsubscribeApplied re-drop does not evict retained '
        'rows', () async {
      await start(retain: true);
      final id = await subscribeWithRows(_agentAQueries, ['a1', 'a2']);
      subscriptionManager.unsubscribe(id);
      expect(chat.count(), 2);

      mockConnection.simulateIncoming(
        _createUnsubscribeApplied(requestId: 0, querySetId: id),
      );
      await pumpEventQueue();

      expect(chat.count(), 2);
      final tag = SubscriptionManager.computeQuerySetHash(_agentAQueries);
      expect(chat.retainedTagsFor('a1'), {tag});
    });

    test('query set hash is order- and whitespace-insensitive but '
        'case-sensitive', () {
      final base = SubscriptionManager.computeQuerySetHash([
        "SELECT * FROM message WHERE agent_id = 'x'",
        "SELECT * FROM tool_event WHERE agent_id = 'x'",
      ]);
      expect(
        SubscriptionManager.computeQuerySetHash([
          "SELECT * FROM tool_event WHERE agent_id = 'x'",
          "SELECT * FROM message WHERE agent_id = 'x'",
        ]),
        base,
        reason: 'query order must not change the hash',
      );
      expect(
        SubscriptionManager.computeQuerySetHash([
          "  SELECT  *  FROM message  WHERE agent_id = 'x' ",
          "SELECT * FROM tool_event\n WHERE agent_id = 'x'",
        ]),
        base,
        reason: 'whitespace differences must not change the hash',
      );
      expect(
        SubscriptionManager.computeQuerySetHash([
          "SELECT * FROM message WHERE agent_id = 'X'",
          "SELECT * FROM tool_event WHERE agent_id = 'x'",
        ]),
        isNot(base),
        reason: 'string literals are case-sensitive',
      );
      expect(
        SubscriptionManager.computeQuerySetHash([
          "SELECT * FROM message WHERE agent_id = 'y'",
          "SELECT * FROM tool_event WHERE agent_id = 'y'",
        ]),
        isNot(base),
      );
    });
  });

  group('reconcile on resubscribe (slice 2)', () {
    test('re-subscribing the same query set evicts ghosts, keeps '
        're-delivered rows, clears tags and restores ownership', () async {
      await start(retain: true);
      final id = await subscribeWithRows(_agentAQueries, ['a1', 'a2', 'a3']);
      subscriptionManager.unsubscribe(id);
      expect(chat.count(), 3);
      final reconcileBefore = chat.reconcileEvictionCount;

      await subscribeWithRows(_agentAQueries, ['a1', 'a2']);

      expect(chat.find('a3'), isNull, reason: 'ghost row reconciled away');
      expect(chat.count(), 2);
      expect(chat.retainedTagEntryCount, 0);
      expect(chat.ownedKeys('a1'), isNotEmpty);
      expect(chat.reconcileEvictionCount - reconcileBefore, 1);
    });

    test('another query set\'s snapshot neither evicts nor untags rows '
        'retained under a different hash', () async {
      await start(retain: true);
      final idA = await subscribeWithRows(_agentAQueries, ['a1', 'a2']);
      subscriptionManager.unsubscribe(idA);
      expect(chat.count(), 2);

      await subscribeWithRows(_agentBQueries, ['b1']);

      expect(chat.count(), 3);
      final tagA = SubscriptionManager.computeQuerySetHash(_agentAQueries);
      expect(chat.retainedTagsFor('a1'), {tagA});
      expect(chat.retainedTagsFor('a2'), {tagA});
      expect(chat.ownedKeys('b1'), isNotEmpty);
    });

    test('untagged unowned rows are still swept by a scoped snapshot '
        '(stale data purge preserved)', () async {
      await start(retain: true);
      chat.loadFromSerializable([
        {'v': 'stale1'},
        {'v': 'stale2'},
      ]);
      expect(chat.count(), 2);

      await subscribeWithRows(_agentBQueries, ['b1']);

      expect(chat.count(), 1);
      expect(chat.find('stale1'), isNull);
      expect(chat.sweepEvictionCount, 2);
    });
  });

  group('tag persistence (slice 3)', () {
    test('retained tags survive persist/restore: restored rows survive a '
        'foreign snapshot and reconcile under their own set', () async {
      final storage = InMemoryOfflineStorage();
      await start(retain: true, storage: storage);
      final id = await subscribeWithRows(_agentAQueries, ['a1', 'a2']);
      subscriptionManager.unsubscribe(id);
      await pumpEventQueue();
      await subscriptionManager.dispose();

      await start(retain: true, storage: storage);
      await subscriptionManager.loadFromOfflineCache();
      expect(chat.count(), 2);
      final tagA = SubscriptionManager.computeQuerySetHash(_agentAQueries);
      expect(chat.retainedTagsFor('a1'), {tagA});
      expect(chat.retainedTagsFor('a2'), {tagA});

      await subscribeWithRows(_agentBQueries, ['b1']);
      expect(chat.count(), 3, reason: 'foreign snapshot leaves them alone');

      await subscribeWithRows(_agentAQueries, ['a1']);
      expect(chat.find('a2'), isNull, reason: 'ghost reconciled on own set');
      expect(chat.find('a1'), isNotNull);
      expect(chat.ownedKeys('a1'), isNotEmpty);
    });

    test('rows owned by a live set at persist time restore carrying that '
        'set\'s query hash', () async {
      final storage = InMemoryOfflineStorage();
      await start(retain: true, storage: storage);
      await subscribeWithRows(_agentAQueries, ['a1', 'a2']);
      await pumpEventQueue();
      await subscriptionManager.dispose();

      await start(retain: true, storage: storage);
      await subscriptionManager.loadFromOfflineCache();
      expect(chat.count(), 2);
      final tagA = SubscriptionManager.computeQuerySetHash(_agentAQueries);
      expect(chat.retainedTagsFor('a1'), {tagA});

      await subscribeWithRows(_agentAQueries, ['a1']);
      expect(chat.find('a2'), isNull, reason: 'cold-start ghost reconciled');
      expect(chat.count(), 1);
    });

    test('a tag sidecar left by a retention-on run is ignored when retention '
        'is off: rows load untagged and are swept', () async {
      final storage = InMemoryOfflineStorage();
      await start(retain: true, storage: storage);
      final id = await subscribeWithRows(_agentAQueries, ['a1', 'a2']);
      subscriptionManager.unsubscribe(id);
      await pumpEventQueue();
      await subscriptionManager.dispose();

      await start(storage: storage);
      await subscriptionManager.loadFromOfflineCache();
      expect(chat.count(), 2);
      expect(chat.retainedTagEntryCount, 0);
      expect(chat.ownedKeys('a1'), isEmpty);

      await subscribeWithRows(_agentBQueries, ['b1']);
      expect(
        chat.count(),
        1,
        reason: 'retention off must keep default sweep behaviour '
            'even when a stale tag sidecar exists on disk',
      );
    });

    test('a legacy snapshot without tag data loads exactly as today: rows '
        'unowned, untagged, swept by a scoped snapshot', () async {
      final storage = InMemoryOfflineStorage();
      await start(storage: storage);
      await subscribeWithRows(_agentAQueries, ['a1', 'a2']);
      await pumpEventQueue();
      await subscriptionManager.dispose();

      await start(retain: true, storage: storage);
      await subscriptionManager.loadFromOfflineCache();
      expect(chat.count(), 2);
      expect(chat.retainedTagEntryCount, 0);
      expect(chat.ownedKeys('a1'), isEmpty);

      await subscribeWithRows(_agentBQueries, ['b1']);
      expect(chat.count(), 1, reason: 'untagged disk rows are swept');
    });
  });
}
