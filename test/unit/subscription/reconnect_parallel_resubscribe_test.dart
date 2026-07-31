import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';
import 'package:spacetimedb_sdk/codegen.dart';

import '../../mocks/mock_connection.dart';

const _timeout = Duration(seconds: 2);

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

void main() {
  group('reconnect resubscribe is pipelined, not serial', () {
    late MockConnection mockConnection;
    late SubscriptionManager subscriptionManager;

    setUp(() {
      mockConnection = MockConnection();
      subscriptionManager = SubscriptionManager(mockConnection);
    });

    tearDown(() async {
      await subscriptionManager.dispose();
    });

    Future<void> establishThreeAppliedSets() async {
      await mockConnection.connect();
      final futures = [
        subscriptionManager.subscribe(['SELECT * FROM notes']),
        subscriptionManager.subscribe(['SELECT * FROM folders']),
        subscriptionManager.subscribe(['SELECT * FROM tags']),
      ];
      for (var id = 1; id <= 3; id++) {
        mockConnection.simulateIncoming(
          _createSubscribeApplied(requestId: 0, querySetId: id),
        );
      }
      await Future.wait(futures).timeout(_timeout);
      expect(subscriptionManager.subscriptionsReady.value, isTrue);
    }

    test(
      'all Subscribe messages go out before any SubscribeApplied arrives',
      () async {
        await establishThreeAppliedSets();

        mockConnection.clearSent();
        await mockConnection.disconnect();
        await mockConnection.connect();
        await pumpEventQueue();

        expect(
          mockConnection.sentMessages.length,
          3,
          reason:
              'reconnect must send every query set\'s Subscribe up front; '
              'a serial loop blocks on the first SubscribeApplied and only '
              'one Subscribe is on the wire at this point',
        );
        expect(mockConnection.sentMessages.map(_sentQuerySetId).toSet(), {
          1,
          2,
          3,
        });

        expect(subscriptionManager.subscriptionsReady.value, isFalse);
        for (var id = 1; id <= 3; id++) {
          mockConnection.simulateIncoming(
            _createSubscribeApplied(requestId: 0, querySetId: id),
          );
        }
        await pumpEventQueue();

        expect(
          subscriptionManager.subscriptionsReady.value,
          isTrue,
          reason: 'ready must flip once all sets have re-applied',
        );
        expect(subscriptionManager.subscriptionsByQuerySetId.keys.toSet(), {
          1,
          2,
          3,
        });
      },
    );

    test('ready stays false until the LAST set applies', () async {
      await establishThreeAppliedSets();

      await mockConnection.disconnect();
      await mockConnection.connect();
      await pumpEventQueue();

      mockConnection.simulateIncoming(
        _createSubscribeApplied(requestId: 0, querySetId: 1),
      );
      mockConnection.simulateIncoming(
        _createSubscribeApplied(requestId: 0, querySetId: 2),
      );
      await pumpEventQueue();
      expect(
        subscriptionManager.subscriptionsReady.value,
        isFalse,
        reason: 'two of three sets applied; ready must not flip early',
      );

      mockConnection.simulateIncoming(
        _createSubscribeApplied(requestId: 0, querySetId: 3),
      );
      await pumpEventQueue();
      expect(subscriptionManager.subscriptionsReady.value, isTrue);
    });
  });

  group('reconnect worst case is ONE timeout window, not one per set', () {
    test('all per-set 30s windows elapse concurrently', () {
      fakeAsync((async) {
        final mockConnection = MockConnection();
        final subscriptionManager = SubscriptionManager(mockConnection);

        mockConnection.connect();
        async.flushMicrotasks();

        subscriptionManager.subscribe(['SELECT * FROM notes']);
        subscriptionManager.subscribe(['SELECT * FROM folders']);
        subscriptionManager.subscribe(['SELECT * FROM tags']);
        async.flushMicrotasks();
        for (var id = 1; id <= 3; id++) {
          mockConnection.simulateIncoming(
            _createSubscribeApplied(requestId: 0, querySetId: id),
          );
        }
        async.flushMicrotasks();
        expect(subscriptionManager.subscriptionsReady.value, isTrue);

        mockConnection.clearSent();
        mockConnection.disconnect();
        async.flushMicrotasks();
        mockConnection.connect();
        async.flushMicrotasks();

        async.elapse(const Duration(seconds: 31));
        async.flushMicrotasks();

        expect(
          async.nonPeriodicTimerCount,
          0,
          reason:
              'at +31s every per-set timeout window must already have '
              'elapsed; a serial loop starts set 2\'s 30s window only after '
              'set 1\'s expires, leaving windows still pending here (worst '
              'case N x 30s instead of one bounded window)',
        );
        expect(
          mockConnection.sentMessages.length,
          3,
          reason: 'every Subscribe must have been sent inside the window',
        );
        expect(
          subscriptionManager.subscriptionsByQuerySetId.keys.toSet(),
          {1, 2, 3},
          reason: 'timed-out sets are retained for the next reconnect',
        );
        expect(
          subscriptionManager.subscriptionsReady.value,
          isFalse,
          reason: 'nothing re-applied; ready must not flip',
        );

        subscriptionManager.dispose();
        async.flushMicrotasks();
      });
    });

    test('partial timeout: applied set reconciles, timed-out set retains rows, '
        'late apply completes readiness, next reconnect evicts stale rows', () {
      fakeAsync((async) {
        final mockConnection = MockConnection();
        final subscriptionManager = SubscriptionManager(mockConnection);
        subscriptionManager.cache.registerDecoder<String>(
          'ta',
          _StringDecoder(),
        );
        subscriptionManager.cache.registerDecoder<String>(
          'tb',
          _StringDecoder(),
        );

        mockConnection.connect();
        async.flushMicrotasks();

        subscriptionManager.subscribe(['SELECT * FROM ta']);
        subscriptionManager.subscribe(['SELECT * FROM tb']);
        async.flushMicrotasks();
        mockConnection.simulateIncoming(
          _createSubscribeApplied(
            requestId: 0,
            querySetId: 1,
            rowsByTable: {
              'ta': ['a1'],
            },
          ),
        );
        mockConnection.simulateIncoming(
          _createSubscribeApplied(
            requestId: 0,
            querySetId: 2,
            rowsByTable: {
              'tb': ['b1'],
            },
          ),
        );
        async.flushMicrotasks();
        final ta = subscriptionManager.cache.getTableByName('ta');
        final tb = subscriptionManager.cache.getTableByName('tb');
        if (ta == null || tb == null) fail('tables not registered');
        expect(ta.iter(), contains('a1'));
        expect(tb.iter(), contains('b1'));

        mockConnection.disconnect();
        async.flushMicrotasks();
        mockConnection.connect();
        async.flushMicrotasks();

        mockConnection.simulateIncoming(
          _createSubscribeApplied(
            requestId: 0,
            querySetId: 1,
            rowsByTable: {
              'ta': ['a2'],
            },
          ),
        );
        async.flushMicrotasks();

        async.elapse(const Duration(seconds: 31));
        async.flushMicrotasks();

        expect(
          subscriptionManager.subscriptionsReady.value,
          isFalse,
          reason: 'set 2 never re-applied inside the window',
        );
        expect(
          tb.iter(),
          contains('b1'),
          reason:
              'skipped eviction must retain the timed-out set\'s cached '
              'rows for the next reconnect',
        );
        expect(
          ta.iter(),
          containsAll(['a1', 'a2']),
          reason:
              'eviction was skipped, so the server-deleted a1 is retained '
              'alongside the fresh snapshot until a full reconnect',
        );
        expect(subscriptionManager.subscriptionsByQuerySetId.keys.toSet(), {
          1,
          2,
        });

        mockConnection.simulateIncoming(
          _createSubscribeApplied(
            requestId: 0,
            querySetId: 2,
            rowsByTable: {
              'tb': ['b1'],
            },
          ),
        );
        async.flushMicrotasks();
        expect(
          subscriptionManager.subscriptionsReady.value,
          isTrue,
          reason:
              'the late apply of the timed-out set completes readiness, '
              'matching the pre-change serial semantics',
        );
        expect(tb.iter(), contains('b1'));

        mockConnection.disconnect();
        async.flushMicrotasks();
        mockConnection.connect();
        async.flushMicrotasks();
        mockConnection.simulateIncoming(
          _createSubscribeApplied(
            requestId: 0,
            querySetId: 1,
            rowsByTable: {
              'ta': ['a2'],
            },
          ),
        );
        mockConnection.simulateIncoming(
          _createSubscribeApplied(
            requestId: 0,
            querySetId: 2,
            rowsByTable: {
              'tb': ['b1'],
            },
          ),
        );
        async.flushMicrotasks();

        expect(
          ta.iter(),
          isNot(contains('a1')),
          reason:
              'a fully-applied reconnect must evict the stale a1 via the '
              'dirty-set diff',
        );
        expect(ta.iter(), contains('a2'));
        expect(tb.iter(), contains('b1'));
        expect(subscriptionManager.subscriptionsReady.value, isTrue);

        subscriptionManager.dispose();
        async.flushMicrotasks();
      });
    });
  });
}
