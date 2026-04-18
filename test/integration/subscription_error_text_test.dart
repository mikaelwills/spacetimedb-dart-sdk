// ignore_for_file: avoid_print
library;

import 'dart:async';

import 'package:test/test.dart';

import '../helpers/integration_test_helper.dart';
import '../helpers/test_env.dart';

/// W6 diagnostic: capture the actual text format of `SubscriptionError.error`
/// from the live server when a consumer subscribes to a non-existent table.
///
/// Why: `SubscriptionManager._handleSubscriptionError`
/// (subscription_manager.dart:359-395) parses the error text with the regex
/// `` `(\w+)` is not a valid table `` to extract the failing table name and
/// drop the matching query from `_activeSubscriptionQueries`. The literal
/// string " is not a valid table " does not appear anywhere in the
/// SpacetimeDB server source tree, so the regex may already be broken under
/// v1 — which would mean the error-recovery path is dead code today.
///
/// This test intentionally does NOT assert on the regex behaviour. It prints
/// the raw error text so we know what string format to target in the v2
/// rewrite of `_handleSubscriptionError`.

void main() {
  setUpAll(ensureTestEnvironment);
  tearDownAll(cleanupTestEnvironment);

  test(
    'capture SubscriptionError text for unknown table',
    timeout: const Timeout(Duration(seconds: 60)),
    () async {
      final env = await createTestEnv();
      await env.connection.connect();
      print('  Connection state: ${env.connection.state}');

      final connSub = env.connection.onStateChanged.listen((s) {
        print('  [connection state] $s');
      });

      String? capturedError;
      final subs = <StreamSubscription<Object?>>[
        env.subManager.onSubscriptionError.listen((event) {
          capturedError = event.error;
          print(
            '  [onSubscriptionError] "${event.error}" '
            '(requestId=${event.requestId}, queryId=${event.queryId})',
          );
        }),
        env.subManager.onSubscribeMultiApplied.listen((event) {
          print('  [onSubscribeMultiApplied] $event');
        }),
        env.subManager.onSubscribeApplied.listen((event) {
          print('  [onSubscribeApplied] $event');
        }),
        env.subManager.onInitialSubscription.listen((event) {
          print(
            '  [onInitialSubscription] '
            '${event.tableUpdates.length} tables',
          );
        }),
        env.subManager.onTransactionUpdate.listen((event) {
          print('  [onTransactionUpdate] $event');
        }),
      ];

      env.subManager.subscribeMulti(
        ['SELECT * FROM table_that_definitely_does_not_exist_xyz123'],
        requestId: 1,
        queryId: 1,
      );

      // Poll up to 10s for the error to arrive.
      for (var i = 0; i < 20 && capturedError == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }

      for (final s in subs) {
        await s.cancel();
      }
      await connSub.cancel();
      await env.disconnect();

      expect(
        capturedError,
        isNotNull,
        reason:
            'Server must emit a SubscriptionError for a bad table reference',
      );

      print('');
      print('  ============================================================');
      print('  W6 FINDING: server error text is:');
      print('  ${capturedError!}');
      print('');
      print('  Current regex: r\'`(\\w+)` is not a valid table\'');
      final regex = RegExp(r'`(\w+)` is not a valid table');
      final matches = regex.hasMatch(capturedError!);
      print('  Regex matches: $matches');
      if (matches) {
        print(
          '  Extracted table: '
          '"${regex.firstMatch(capturedError!)!.group(1)}"',
        );
      } else {
        print('  >>> REGEX IS STALE. Error-recovery path is DEAD CODE today.');
        print('  >>> Update `_handleSubscriptionError` or drop the recovery.');
      }
      print('  ============================================================');
    },
  );
}
