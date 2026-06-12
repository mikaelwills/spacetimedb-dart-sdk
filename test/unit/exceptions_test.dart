import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:spacetimedb_sdk/src/exceptions.dart';
import 'package:spacetimedb_sdk/src/connection/connection_state.dart';
import 'package:spacetimedb_sdk/src/reducers/transaction_result.dart';
import 'package:spacetimedb_sdk/src/messages/update_status.dart';

String classify(SpacetimeDbException e) => switch (e) {
  SpacetimeDbAuthException() => 'auth',
  SpacetimeDbConnectionException() => 'connection',
  SpacetimeDbReducerException() => 'reducer',
  SpacetimeDbTimeoutException() => 'timeout',
  SpacetimeDbSchemaException() => 'schema',
  SpacetimeDbProtocolException() => 'protocol',
  SpacetimeDbSubscriptionException() => 'subscription',
  SpacetimeDbQueueFullException() => 'queue-full',
};

void main() {
  group('SpacetimeDbException hierarchy', () {
    test('exhaustive switch covers every subtype', () {
      final cases = <SpacetimeDbException, String>{
        SpacetimeDbAuthException('401'): 'auth',
        SpacetimeDbConnectionException(
              'lost',
              lastKnownState: const Disconnected(),
            ):
            'connection',
        SpacetimeDbReducerException(
              reducerName: 'create_note',
              message: 'validation',
              result: TransactionResult(
                status: Failed(Uint8List.fromList('validation'.codeUnits)),
                timestamp: DateTime.now(),
              ),
            ):
            'reducer',
        SpacetimeDbTimeoutException(
              'timed out',
              elapsed: const Duration(seconds: 1),
            ):
            'timeout',
        SpacetimeDbSchemaException('unknown shape'): 'schema',
        SpacetimeDbProtocolException('underflow'): 'protocol',
        SpacetimeDbSubscriptionException(
              '`note` is not a valid table',
              tableName: 'note',
            ):
            'subscription',
      };

      for (final entry in cases.entries) {
        expect(classify(entry.key), equals(entry.value));
      }
    });

    test('every subtype is catchable as SpacetimeDbException', () {
      final exceptions = <SpacetimeDbException>[
        SpacetimeDbAuthException('a'),
        SpacetimeDbConnectionException('c'),
        SpacetimeDbReducerException(
          reducerName: 'r',
          message: 'm',
          result: TransactionResult(
            status: Committed(),
            timestamp: DateTime.now(),
          ),
        ),
        SpacetimeDbTimeoutException('t', elapsed: Duration.zero),
        SpacetimeDbSchemaException('s'),
        SpacetimeDbProtocolException('p'),
        SpacetimeDbSubscriptionException('sub'),
      ];

      for (final e in exceptions) {
        try {
          throw e;
        } on SpacetimeDbException catch (caught) {
          expect(caught, same(e));
        }
      }
    });

    test('SpacetimeDbAuthException is a SpacetimeDbConnectionException', () {
      final e = SpacetimeDbAuthException('401');
      expect(e, isA<SpacetimeDbConnectionException>());
      expect(e, isA<SpacetimeDbException>());
    });
  });
}
