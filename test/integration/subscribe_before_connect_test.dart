import 'dart:async';

import 'package:test/test.dart';

import '../helpers/integration_test_helper.dart';
import '../helpers/test_env.dart';

const _timeout = Duration(seconds: 10);

Future<void> _waitUntil(bool Function() condition, String reason) async {
  final deadline = DateTime.now().add(_timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail(reason);
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  setUpAll(ensureTestEnvironment);
  tearDownAll(cleanupTestEnvironment);

  test('a set subscribed before the first connect is sent when it lands, '
      'delivers its initial rows and stays live', () async {
    final writer = await createTestEnv();
    addTearDown(writer.disconnect);
    await writer.connection.connect();
    final seededTitle =
        'before-connect-${DateTime.now().microsecondsSinceEpoch}';
    await writer.reducers
        .createNote(title: seededTitle, content: 'seeded')
        .timeout(_timeout);

    final env = await createTestEnv();
    addTearDown(env.disconnect);
    final subscribed = env.subManager.subscribe(['SELECT * FROM note']);
    await env.connection.connect();
    await subscribed.timeout(_timeout);

    await _waitUntil(
      () => env.noteTable.iter().any((n) => n.title == seededTitle),
      'initial rows of the set subscribed before connect never arrived',
    );

    final liveTitle = 'after-connect-${DateTime.now().microsecondsSinceEpoch}';
    await writer.reducers
        .createNote(title: liveTitle, content: 'live')
        .timeout(_timeout);
    await _waitUntil(
      () => env.noteTable.iter().any((n) => n.title == liveTitle),
      'a row inserted after connect never arrived on the early set',
    );
  });
}
