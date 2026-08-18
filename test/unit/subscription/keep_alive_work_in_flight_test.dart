import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';
import 'package:spacetimedb_sdk/codegen.dart';

import '../../mocks/mock_connection.dart';

const _timeout = Duration(seconds: 2);

Uint8List _createSubscribeApplied({
  required int requestId,
  required int querySetId,
}) {
  final encoder = BsatnEncoder();
  encoder.writeU8(0);
  encoder.writeU8(1);
  encoder.writeU32(requestId);
  encoder.writeU32(querySetId);
  encoder.writeU32(0);
  return encoder.toBytes();
}

void main() {
  group('keep-alive work-in-flight signal follows the subscribe window', () {
    test('a normal subscribe asserts then clears the signal', () async {
      final mockConnection = MockConnection();
      final subscriptionManager = SubscriptionManager(mockConnection);
      addTearDown(subscriptionManager.dispose);

      await mockConnection.connect();
      final future = subscriptionManager.subscribe(['SELECT * FROM notes']);
      await pumpEventQueue();

      expect(
        mockConnection.keepAliveWorkInFlight,
        isTrue,
        reason:
            'the Subscribe is on the wire and the SubscribeApplied has not '
            'arrived; the monitor must be told work is in flight',
      );

      mockConnection.simulateIncoming(
        _createSubscribeApplied(requestId: 0, querySetId: 1),
      );
      await future.timeout(_timeout);
      await pumpEventQueue();

      expect(
        mockConnection.keepAliveWorkInFlight,
        isFalse,
        reason: 'the snapshot landed, so normal liveness rules must resume',
      );
    });

    test('a resubscribe that hits its 30s timeout does not leave the signal '
        'latched on', () {
      fakeAsync((async) {
        final mockConnection = MockConnection();
        final subscriptionManager = SubscriptionManager(mockConnection);

        mockConnection.connect();
        async.flushMicrotasks();

        subscriptionManager.subscribe(['SELECT * FROM notes']);
        async.flushMicrotasks();
        mockConnection.simulateIncoming(
          _createSubscribeApplied(requestId: 0, querySetId: 1),
        );
        async.elapse(const Duration(milliseconds: 10));
        expect(
          mockConnection.keepAliveWorkInFlight,
          isFalse,
          reason: 'baseline: the first subscribe applied and cleared',
        );

        mockConnection.disconnect();
        async.elapse(const Duration(milliseconds: 10));
        mockConnection.connect();
        async.elapse(const Duration(milliseconds: 10));

        expect(
          mockConnection.keepAliveWorkInFlight,
          isTrue,
          reason: 'the resubscribe is in flight, deferral must be armed',
        );

        async.elapse(const Duration(seconds: 45));

        expect(
          mockConnection.keepAliveWorkInFlight,
          isFalse,
          reason:
              'the 30s resubscribe timeout at subscription_manager.dart:380 '
              'has elapsed and _onReconnected has given up on this query '
              'set — no snapshot is coming, so the keep-alive deferral must '
              'not stay armed. If it latches, a socket that dies later gets '
              'maxDeferredPings of free grace instead of being killed on '
              'the first missed pong, and normal liveness detection never '
              'returns for the life of the connection.',
        );

        subscriptionManager.dispose();
        async.flushTimers();
      });
    });
  });
}
