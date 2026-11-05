import 'dart:async';

import 'package:spacetimedb_sdk/protocol.dart';
import 'package:spacetimedb_sdk/src/connection/spacetimedb_connection.dart'
    show closeForReconnect;
import 'package:test/test.dart';

import '../helpers/integration_test_helper.dart';
import '../helpers/test_env.dart';

const _timeout = Duration(seconds: 10);
const _myOwnedItems = 'SELECT * FROM my_owned_items';
const _evictedMyOwnedItems = 'RECONNECT_EVICT: my_owned_items';

Future<void> _waitUntil(bool Function() condition, String reason) async {
  final deadline = DateTime.now().add(_timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail(reason);
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

Future<TestEnv> _connect({String? token}) async {
  final env = await createTestEnv(
    registerNote: false,
    registerViews: true,
    initialToken: token,
  );
  final initial = env.subManager.onInitialConnection.first;
  await env.connection.connect();
  env.connection.updateToken((await initial.timeout(_timeout)).token);
  return env;
}

Set<String> _labels(TestEnv env) => {
  for (final item in env.myOwnedItemsTable.iter()) item.label,
};

void main() {
  setUpAll(ensureTestEnvironment);
  tearDownAll(cleanupTestEnvironment);

  final logs = <String>[];
  SdkLogCallback? previousLog;

  setUp(() {
    logs.clear();
    previousLog = SdkLogger.onLog;
    SdkLogger.onLog = (_, message) => logs.add(message);
  });

  tearDown(() => SdkLogger.onLog = previousLog);

  Future<TestEnv> subscribeOwnerWith(
    Set<String> labels, {
    bool forgetOnDisconnect = false,
  }) async {
    final owner = await _connect();
    addTearDown(owner.disconnect);
    if (forgetOnDisconnect) {
      await owner.reducers.optIntoForgetOnDisconnect().timeout(_timeout);
    }
    for (final label in labels) {
      await owner.reducers.addOwnedItem(label: label).timeout(_timeout);
    }
    await owner.subManager.subscribe([_myOwnedItems]).timeout(_timeout);
    await _waitUntil(
      () => _labels(owner).length == labels.length,
      'initial snapshot of my_owned_items never arrived',
    );
    expect(_labels(owner), labels);
    return owner;
  }

  Future<void> forceReconnectAndFinalize(TestEnv env) async {
    final identityBefore = env.subManager.identity;
    final readyTransitions = <bool>[];
    void recordReady() =>
        readyTransitions.add(env.subManager.subscriptionsReady.value);
    env.subManager.subscriptionsReady.addListener(recordReady);
    addTearDown(
      () => env.subManager.subscriptionsReady.removeListener(recordReady),
    );
    final reconnected = env.connection.onStateChanged
        .where((state) => state is Connected)
        .first;
    closeForReconnect(env.connection, 'test: force a reconnect');
    await reconnected.timeout(_timeout);
    await _waitUntil(
      () => readyTransitions.length == 2,
      'reconnect generation never finalized',
    );
    expect(readyTransitions, [false, true]);
    expect(env.subManager.identity, identityBefore);
  }

  Future<void> expectLiveFromSibling(TestEnv owner, String label) async {
    final sibling = await _connect(token: owner.connection.token);
    addTearDown(sibling.disconnect);
    expect(sibling.subManager.identity, owner.subManager.identity);
    await sibling.reducers.addOwnedItem(label: label).timeout(_timeout);
    await _waitUntil(
      () => _labels(owner).contains(label),
      'a row written after the reconnect never reached my_owned_items',
    );
  }

  test('a sender-scoped view keeps its rows and stays live across a '
      'reconnect', () async {
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final labels = {'a-$stamp', 'b-$stamp'};
    final owner = await subscribeOwnerWith(labels);

    await forceReconnectAndFinalize(owner);

    expect(
      logs.where((line) => line.startsWith(_evictedMyOwnedItems)),
      isEmpty,
    );
    expect(_labels(owner), labels);
    await expectLiveFromSibling(owner, 'c-$stamp');
    expect(_labels(owner), {...labels, 'c-$stamp'});
  });

  test('a module that forgets the identity on its last disconnect empties '
      'the view; the eviction is correct and the view stays live', () async {
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final owner = await subscribeOwnerWith({
      'a-$stamp',
      'b-$stamp',
    }, forgetOnDisconnect: true);

    await forceReconnectAndFinalize(owner);

    expect(
      logs,
      contains(
        '$_evictedMyOwnedItems evicted 2 of 2 previously-owned rows not '
        're-delivered',
      ),
    );
    expect(owner.myOwnedItemsTable.count(), 0);
    await expectLiveFromSibling(owner, 'after-$stamp');
    expect(_labels(owner), {'after-$stamp'});
  });
}
