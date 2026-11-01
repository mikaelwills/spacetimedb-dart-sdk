import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';
import 'package:spacetimedb_sdk/codegen.dart';
import 'package:spacetimedb_sdk/protocol.dart';
import 'package:spacetimedb_sdk/src/messages/subscribe_batch.dart';

import '../../helpers/reconnect_replay.dart';
import '../../mocks/mock_connection.dart';

const _timeout = Duration(seconds: 2);

Uint8List _row(String value) => (BsatnEncoder()..writeString(value)).toBytes();

QueryRows _rows(String table, List<String> values) => queryRows({
  table: [for (final value in values) _row(value)],
});

class _JsonStringDecoder extends RowDecoder<String> {
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

class _GatedStorage extends InMemoryOfflineStorage {
  Completer<void>? gate;

  @override
  Future<void> saveTableSnapshot(
    String tableName,
    List<Map<String, dynamic>> rows,
  ) async {
    final pending = gate;
    if (pending != null) await pending.future;
    await super.saveTableSnapshot(tableName, rows);
  }
}

class _Fixture {
  _Fixture({OfflineStorage? storage}) : this._(MockConnection(), storage);

  _Fixture._(this.connection, OfflineStorage? storage)
    : manager = SubscriptionManager(connection, offlineStorage: storage) {
    for (final table in _tables) {
      manager.cache.registerDecoder<String>(table, _JsonStringDecoder());
    }
    manager.onSubscribeApplied.listen(applied.add);
    manager.onSubscriptionError.listen(errors.add);
  }

  static const _tables = ['ta', 'tb', 'tc'];

  static String tableFor(int querySetId) => _tables[querySetId - 1];

  final MockConnection connection;
  final SubscriptionManager manager;
  final applied = <SubscribeApplied>[];
  final errors = <SubscriptionErrorMessage>[];
  final deletes = <TableDeleteEvent<String>>[];

  TableCache<String> table(String name) =>
      manager.cache.getTableByTypedName<String>(name);

  void recordDeletes() {
    for (final name in _tables) {
      table(name).onDelete.listen(deletes.add);
    }
  }

  Future<void> establish({List<String> extraSet2Queries = const []}) async {
    await connection.connect();
    final futures = [
      for (final name in _tables)
        manager.subscribe([
          'SELECT * FROM $name',
          if (name == 'tb') ...extraSet2Queries,
        ]),
    ];
    for (var i = 0; i < _tables.length; i++) {
      connection.simulateIncoming(
        perSetSubscribeAppliedFrame(
          i + 1,
          _rows(_tables[i], ['${i}0', '${i}1']),
        ),
      );
    }
    await Future.wait(futures).timeout(_timeout);
    applied.clear();
  }

  Future<SentSubscribeBatch> bounce() async {
    connection.clearSent();
    await connection.disconnect();
    await connection.connect();
    await pumpEventQueue();
    return decodeSentSubscribeBatch(
      sentWithTag(connection.sentMessages, subscribeBatchTag).single,
    );
  }

  void reply(int requestId, List<int> ids) {
    connection.simulateIncoming(
      subscribeBatchAppliedFrame(requestId, [
        for (final id in ids)
          (
            querySetId: id,
            outcome: SubscribeSetApplied(_rows(_tables[id - 1], ['${id}x'])),
          ),
      ]),
    );
  }

  Set<String> get allRows => {
    for (final name in _tables) ...table(name).iter(),
  };

  Future<void> dispose() => manager.dispose();
}

void main() {
  group('Invariant B: no new public enum value', () {
    test('ServerMessageType and ClientMessageType keep their counts', () {
      expect(ServerMessageType.values.length, 8);
      expect(ClientMessageType.values.length, 5);
    });
  });

  group('a batch reply that does not match the pending batch closes once', () {
    late _Fixture f;

    setUp(() async {
      f = _Fixture();
      await f.establish();
    });

    tearDown(() => f.dispose());

    Future<void> expectClosedOnceUnchanged(Set<String> before) async {
      await pumpEventQueue();
      expect(f.connection.closeForReconnectReasons, hasLength(1));
      expect(f.allRows, before);
      expect(f.applied, isEmpty);
    }

    test('no pending batch: a requestId never sent', () async {
      final before = f.allRows;
      f.reply(99, [1, 2, 3]);
      await expectClosedOnceUnchanged(before);
    });

    test('a wrong requestId', () async {
      final batch = await f.bounce();
      final before = f.allRows;
      f.reply(batch.requestId + 1, [1, 2, 3]);
      await expectClosedOnceUnchanged(before);
    });

    test('an extra set id', () async {
      final batch = await f.bounce();
      final before = f.allRows;
      f.connection.simulateIncoming(
        subscribeBatchAppliedFrame(batch.requestId, [
          for (final id in [1, 2, 3])
            (querySetId: id, outcome: SubscribeSetApplied(_rows('ta', []))),
          (querySetId: 4, outcome: SubscribeSetApplied(_rows('ta', []))),
        ]),
      );
      await expectClosedOnceUnchanged(before);
    });

    test('a missing set id', () async {
      final batch = await f.bounce();
      final before = f.allRows;
      f.reply(batch.requestId, [1, 2]);
      await expectClosedOnceUnchanged(before);
    });
  });

  group('a matching batch reply', () {
    test('emits onSubscribeApplied once per set, in reply order, with that '
        "set's rows", () async {
      final f = _Fixture();
      addTearDown(f.dispose);
      await f.establish();

      final batch = await f.bounce();
      f.connection.simulateIncoming(
        subscribeBatchAppliedFrame(batch.requestId, [
          for (final id in [3, 1, 2])
            (
              querySetId: id,
              outcome: SubscribeSetApplied(
                _rows(_Fixture.tableFor(id), ['${id}x']),
              ),
            ),
        ]),
      );
      await pumpEventQueue();

      expect(f.applied.map((a) => a.querySetId), [3, 1, 2]);
      for (final message in f.applied) {
        final table = message.rows.tables.single;
        expect(table.tableName, _Fixture.tableFor(message.querySetId));
        expect(table.rows.getRows(), hasLength(1));
      }
      expect(f.connection.closeForReconnectReasons, isEmpty);
    });

    test('finalizes once, only after every set has persisted', () async {
      final storage = _GatedStorage();
      final f = _Fixture(storage: storage);
      addTearDown(f.dispose);
      await f.establish();
      f.recordDeletes();

      final batch = await f.bounce();
      final gate = Completer<void>();
      storage.gate = gate;
      f.reply(batch.requestId, [1, 2, 3]);
      await pumpEventQueue();

      expect(f.deletes, isEmpty, reason: 'finalize waits for persist');
      expect(f.manager.subscriptionsReady.value, isFalse);

      gate.complete();
      await pumpEventQueue();

      expect(f.manager.subscriptionsReady.value, isTrue);
      expect(
        f.deletes.map((e) => e.row),
        unorderedEquals(['00', '01', '10', '11', '20', '21']),
        reason: 'every pre-reconnect row was not re-delivered: one delete each',
      );
    });

    test(
      'completes a subscribe() that was waiting while disconnected',
      () async {
        final f = _Fixture();
        addTearDown(f.dispose);
        await f.establish();

        await f.connection.disconnect();
        final late = f.manager.subscribe(['SELECT * FROM tc WHERE v = 1']);
        await f.connection.connect();
        await pumpEventQueue();
        final batch = decodeSentSubscribeBatch(
          sentWithTag(f.connection.sentMessages, subscribeBatchTag).last,
        );
        expect(batch.sets.map((s) => s.querySetId), contains(4));

        answerReconnectReplay(f.connection);
        final id = await late.timeout(_timeout);
        await pumpEventQueue();

        expect(id, 4);
        expect(f.manager.subscriptionsReady.value, isTrue);
        expect(f.connection.keepAliveWorkInFlight, isFalse);
      },
    );

    test('a disconnect while the batch is pending completes it at once, with '
        'no finalize', () {
      fakeAsync((async) {
        final f = _Fixture();
        f.establish();
        async.flushMicrotasks();
        f.recordDeletes();
        final before = f.allRows;

        f.bounce();
        async.flushMicrotasks();
        expect(f.connection.keepAliveWorkInFlight, isTrue);

        f.connection.disconnect();
        async.elapse(const Duration(seconds: 1));

        expect(f.connection.keepAliveWorkInFlight, isFalse);
        expect(f.manager.consecutiveEvictionSkips, 1);
        expect(f.deletes, isEmpty);
        expect(f.allRows, before);

        f.dispose();
        async.flushMicrotasks();
      });
    });
  });

  group('a late reply to a timed-out batch', () {
    test('is applied without a close, and a new batch clears the record', () {
      fakeAsync((async) {
        final f = _Fixture();
        f.establish();
        async.flushMicrotasks();

        late SentSubscribeBatch batch;
        f.bounce().then((b) => batch = b);
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 31));
        expect(f.manager.subscriptionsReady.value, isFalse);

        f.reply(batch.requestId, [1, 2, 3]);
        async.flushMicrotasks();

        expect(f.connection.closeForReconnectReasons, isEmpty);
        expect(f.applied.map((a) => a.querySetId), [1, 2, 3]);
        expect(f.allRows, containsAll(['1x', '2x', '3x']));
        expect(f.manager.subscriptionsReady.value, isTrue);

        late SentSubscribeBatch second;
        f.bounce().then((b) => second = b);
        async.elapse(const Duration(milliseconds: 10));
        expect(second.requestId, isNot(batch.requestId));
        f.reply(batch.requestId, [1, 2, 3]);
        async.flushMicrotasks();

        expect(f.connection.closeForReconnectReasons, hasLength(1));

        f.dispose();
        async.flushMicrotasks();
      });
    });
  });

  group('an Error outcome fails only its own set', () {
    const missingTable =
        'no such table: `nonexistent_tbl`. If the table exists, it may be '
        'marked private., executing: `SELECT * FROM nonexistent_tbl`';

    void replyWithError(_Fixture f, int requestId, String error) {
      f.connection.simulateIncoming(
        subscribeBatchAppliedFrame(requestId, [
          (querySetId: 1, outcome: SubscribeSetApplied(_rows('ta', ['00']))),
          (querySetId: 2, outcome: SubscribeSetError(error)),
          (querySetId: 3, outcome: SubscribeSetApplied(_rows('tc', ['20']))),
        ]),
      );
    }

    test('the other sets apply and finalize; the errored set keeps its rows '
        'and stays live', () async {
      final f = _Fixture();
      addTearDown(f.dispose);
      await f.establish();
      f.recordDeletes();

      final batch = await f.bounce();
      replyWithError(f, batch.requestId, missingTable);
      await pumpEventQueue();

      expect(f.errors, hasLength(1));
      expect(f.errors.single.querySetId, 2);
      expect(f.errors.single.error, missingTable);
      expect(f.applied.map((a) => a.querySetId), [1, 3]);
      expect(f.table('ta').iter(), ['00']);
      expect(f.table('tc').iter(), ['20']);
      expect(f.table('tb').iter(), unorderedEquals(['10', '11']));
      expect(f.deletes.map((e) => e.row), unorderedEquals(['01', '21']));
      expect(f.manager.subscriptionsReady.value, isFalse);
      expect(f.manager.consecutiveEvictionSkips, 0);
      expect(f.manager.subscriptionsByQuerySetId.keys, contains(2));

      final next = await f.bounce();
      expect(next.sets.map((s) => s.querySetId), contains(2));
    });

    test('an error the regex parses drops the bad query and resubscribes the '
        'rest with one Subscribe', () async {
      final f = _Fixture();
      addTearDown(f.dispose);
      await f.establish(extraSet2Queries: ['SELECT * FROM foo']);
      f.recordDeletes();

      final batch = await f.bounce();
      f.connection.clearSent();
      replyWithError(f, batch.requestId, '`foo` is not a valid table');
      await pumpEventQueue();

      final resent = sentWithTag(f.connection.sentMessages, subscribeTag);
      expect(resent, hasLength(1));
      expect(subscribeQuerySetId(resent.single), 2);
      expect(f.manager.subscriptionsByQuerySetId[2], ['SELECT * FROM tb']);
      expect(f.errors.single.querySetId, 2);
      expect(f.table('ta').iter(), ['00']);
      expect(f.table('tc').iter(), ['20']);
      expect(f.table('tb').iter(), unorderedEquals(['10', '11']));
      expect(f.deletes.map((e) => e.row), unorderedEquals(['01', '21']));
    });

    test('an error that leaves the set empty drops it', () async {
      final f = _Fixture();
      addTearDown(f.dispose);
      await f.establish();

      final batch = await f.bounce();
      f.connection.clearSent();
      replyWithError(f, batch.requestId, '`tb` is not a valid table');
      await pumpEventQueue();

      expect(sentWithTag(f.connection.sentMessages, subscribeTag), isEmpty);
      expect(f.manager.subscriptionsByQuerySetId.keys, isNot(contains(2)));
      expect(f.manager.subscriptionsReady.value, isTrue);
    });
  });
}
