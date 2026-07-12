import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:spacetimedb_sdk/codegen.dart';

import '../../mocks/mock_connection.dart';

const _timeout = Duration(seconds: 2);

class _StringDecoder extends RowDecoder<String> {
  @override
  String decode(BsatnDecoder decoder) => decoder.readString();

  @override
  dynamic getPrimaryKey(String row) => row;
}

Uint8List _encodeRowsData(List<String> rows) {
  final encoder = BsatnEncoder();
  for (final row in rows) {
    encoder.writeString(row);
  }
  return encoder.toBytes();
}

void _writeBsatnRowList(BsatnEncoder encoder, List<String> rows) {
  encoder.writeU8(0);
  final rowsData = _encodeRowsData(rows);
  final rowSize = rows.isEmpty ? 0 : rowsData.length ~/ rows.length;
  encoder.writeU16(rowSize);
  encoder.writeU32(rowsData.length);
  encoder.writeBytes(rowsData);
}

void _writeQueryRows(
  BsatnEncoder encoder,
  Map<String, List<String>> rowsByTable,
) {
  encoder.writeU32(rowsByTable.length);
  for (final entry in rowsByTable.entries) {
    encoder.writeString(entry.key);
    _writeBsatnRowList(encoder, entry.value);
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
  _writeQueryRows(encoder, rowsByTable);
  return encoder.toBytes();
}

Uint8List _createSubscriptionError({
  required int querySetId,
  required String error,
  int? requestId,
}) {
  final encoder = BsatnEncoder();
  encoder.writeU8(0);
  encoder.writeU8(3);
  encoder.writeOption<int>(requestId, (v) => encoder.writeU32(v));
  encoder.writeU32(querySetId);
  encoder.writeString(error);
  return encoder.toBytes();
}

void main() {
  group('subscribe() completion under error/disconnect/dispose', () {
    late MockConnection mockConnection;
    late SubscriptionManager subscriptionManager;

    setUp(() {
      mockConnection = MockConnection();
      subscriptionManager = SubscriptionManager(mockConnection);
    });

    tearDown(() async {
      await subscriptionManager.dispose();
    });

    test(
      'completes when a SubscriptionError removes all queries in the set',
      () async {
        final future = subscriptionManager.subscribe([
          'SELECT * FROM bad_table',
        ]);

        mockConnection.simulateIncoming(
          _createSubscriptionError(
            querySetId: 1,
            error: '`bad_table` is not a valid table',
          ),
        );

        await expectLater(future, completion(equals(1))).timeout(_timeout);
        expect(subscriptionManager.subscriptionsByQuerySetId, isEmpty);
      },
    );

    test('completes on unparseable subscription error text', () async {
      final future = subscriptionManager.subscribe(['SELECT * FROM notes']);

      mockConnection.simulateIncoming(
        _createSubscriptionError(
          querySetId: 1,
          error: 'some completely different server error format',
        ),
      );

      await expectLater(future, completion(equals(1))).timeout(_timeout);
    });

    test(
      'completes via SubscribeApplied in the partial-removal path',
      () async {
        final future = subscriptionManager.subscribe([
          'SELECT * FROM bad_table',
          'SELECT * FROM notes',
        ]);

        mockConnection.simulateIncoming(
          _createSubscriptionError(
            querySetId: 1,
            error: '`bad_table` is not a valid table',
          ),
        );

        bool completed = false;
        unawaited(future.then((_) => completed = true));
        await pumpEventQueue();
        expect(
          completed,
          isFalse,
          reason:
              'partial removal must resubscribe under the same querySetId '
              'and wait for SubscribeApplied, not resolve immediately',
        );

        expect(
          subscriptionManager.subscriptionsByQuerySetId[1],
          equals(['SELECT * FROM notes']),
        );

        mockConnection.simulateIncoming(
          _createSubscribeApplied(requestId: 0, querySetId: 1),
        );

        await expectLater(future, completion(equals(1))).timeout(_timeout);
      },
    );

    test(
      'completes when the connection reports Disconnected mid-subscribe',
      () async {
        final future = subscriptionManager.subscribe(['SELECT * FROM notes']);

        mockConnection.mockState = const Disconnected();

        await expectLater(future, completion(equals(1))).timeout(_timeout);
      },
    );

    test('dispose() mid-subscribe resolves without throwing', () async {
      final future = subscriptionManager.subscribe(['SELECT * FROM notes']);

      await subscriptionManager.dispose();

      await expectLater(future, completion(equals(1))).timeout(_timeout);
    });

    test('dispose during the reconnect resubscribe loop does not touch the '
        'disposed subscriptionsReady notifier', () async {
      final subscribeFuture = subscriptionManager.subscribe([
        'SELECT * FROM notes',
      ]);
      await mockConnection.connect();
      mockConnection.simulateIncoming(
        _createSubscribeApplied(requestId: 0, querySetId: 1),
      );
      await expectLater(
        subscribeFuture,
        completion(equals(1)),
      ).timeout(_timeout);

      await mockConnection.disconnect();

      Object? escaped;
      await runZonedGuarded(
        () async {
          await mockConnection.connect();
          await pumpEventQueue();

          await subscriptionManager.dispose();
          await pumpEventQueue();
        },
        (error, stack) {
          escaped = error;
        },
      );

      expect(
        escaped,
        isNull,
        reason:
            'dispose() landing while _onReconnected awaits the resubscribe '
            'loop must not write subscriptionsReady after it is disposed',
      );
    });
  });

  group('subscriptionsReady flips only when ALL query sets applied', () {
    late MockConnection mockConnection;
    late SubscriptionManager subscriptionManager;

    setUp(() {
      mockConnection = MockConnection();
      subscriptionManager = SubscriptionManager(mockConnection);
    });

    tearDown(() async {
      await subscriptionManager.dispose();
    });

    test(
      'stays false after the first of two query sets applies, flips true only '
      'after the second',
      () async {
        await mockConnection.connect();

        final firstFuture = subscriptionManager.subscribe([
          'SELECT * FROM notes',
        ]);
        final secondFuture = subscriptionManager.subscribe([
          'SELECT * FROM folders',
        ]);

        mockConnection.simulateIncoming(
          _createSubscribeApplied(requestId: 0, querySetId: 1),
        );
        await expectLater(firstFuture, completion(equals(1))).timeout(_timeout);

        expect(
          subscriptionManager.subscriptionsReady.value,
          isFalse,
          reason:
              'query set 2 has not applied yet; subscriptionsReady must not '
              'flip true after only the first set',
        );

        mockConnection.simulateIncoming(
          _createSubscribeApplied(requestId: 0, querySetId: 2),
        );
        await expectLater(
          secondFuture,
          completion(equals(2)),
        ).timeout(_timeout);

        expect(subscriptionManager.subscriptionsReady.value, isTrue);
      },
    );
  });

  group('provenance regex tolerates quoted table names', () {
    late MockConnection mockConnection;
    late SubscriptionManager subscriptionManager;

    setUp(() {
      mockConnection = MockConnection();
      subscriptionManager = SubscriptionManager(mockConnection);
      subscriptionManager.cache.registerDecoder<String>(
        'quoted_table',
        _StringDecoder(),
      );
    });

    tearDown(() async {
      await subscriptionManager.dispose();
    });

    test(
      'a query quoting the table name still gets rows tracked for eviction '
      'when a later SubscribeApplied for the same querySetId omits them',
      () async {
        final future = subscriptionManager.subscribe([
          'SELECT * FROM "quoted_table"',
        ]);

        mockConnection.simulateIncoming(
          _createSubscribeApplied(
            requestId: 0,
            querySetId: 1,
            rowsByTable: {
              'quoted_table': ['row_a'],
            },
          ),
        );

        await expectLater(future, completion(equals(1))).timeout(_timeout);

        final table = subscriptionManager.cache.getTableByName('quoted_table');
        if (table == null) fail('quoted_table was not registered');
        expect(table.iter(), contains('row_a'));

        final appliedAgain = subscriptionManager.onSubscribeApplied.firstWhere(
          (m) => m.querySetId == 1,
        );
        mockConnection.simulateIncoming(
          _createSubscribeApplied(
            requestId: 0,
            querySetId: 1,
            rowsByTable: const {'quoted_table': []},
          ),
        );
        await appliedAgain.timeout(_timeout);

        expect(
          table.iter(),
          isNot(contains('row_a')),
          reason:
              'row_a is no longer matched by any query set; if the regex '
              'failed to strip the quotes around "quoted_table", provenance '
              'tracking for it would silently never have been recorded '
              'under the bare table name and this row would leak forever',
        );
      },
    );
  });
}
