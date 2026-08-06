import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';
import 'package:spacetimedb_sdk/src/connection/keep_alive_monitor.dart';

void main() {
  group('KeepAliveMonitor arming', () {
    test('arms at construction: a socket silent from connect still pings', () {
      fakeAsync((async) {
        var pings = 0;
        var disconnects = 0;
        final monitor = KeepAliveMonitor(
          onSendPing: () => pings++,
          onDisconnect: () => disconnects++,
          idleThreshold: const Duration(seconds: 1),
          pongTimeout: const Duration(seconds: 1),
        );

        async.elapse(const Duration(milliseconds: 900));
        expect(
          pings,
          0,
          reason: 'no ping before the idle threshold elapses',
        );

        async.elapse(const Duration(milliseconds: 200));
        expect(
          pings,
          1,
          reason:
              'the monitor must arm its idle timer at construction — a socket '
              'that never delivers an inbound message would otherwise never be '
              'probed at all',
        );

        async.elapse(const Duration(seconds: 2));
        expect(
          disconnects,
          1,
          reason: 'no pong arrived within pongTimeout → declared dead',
        );

        monitor.stop();
      });
    });

    test('inbound traffic debounces the ping', () {
      fakeAsync((async) {
        var pings = 0;
        final monitor = KeepAliveMonitor(
          onSendPing: () => pings++,
          onDisconnect: () {},
          idleThreshold: const Duration(seconds: 1),
          pongTimeout: const Duration(seconds: 1),
        );

        for (var i = 0; i < 5; i++) {
          async.elapse(const Duration(milliseconds: 800));
          monitor.notifyMessageReceived();
        }
        expect(pings, 0, reason: 'traffic keeps resetting the idle timer');

        async.elapse(const Duration(milliseconds: 1100));
        expect(pings, 1, reason: 'traffic stopped → one ping');

        monitor.stop();
      });
    });

    test('a pong cancels the pending timeout — no false disconnect', () {
      fakeAsync((async) {
        var pings = 0;
        var disconnects = 0;
        late final KeepAliveMonitor monitor;
        monitor = KeepAliveMonitor(
          onSendPing: () {
            pings++;
            monitor.notifyMessageReceived();
          },
          onDisconnect: () => disconnects++,
          idleThreshold: const Duration(seconds: 1),
          pongTimeout: const Duration(seconds: 1),
        );

        monitor.notifyMessageReceived();
        async.elapse(const Duration(milliseconds: 1100));
        expect(pings, 1, reason: 'idle → one ping');

        async.elapse(const Duration(milliseconds: 500));
        expect(
          disconnects,
          0,
          reason: 'the reply arrived inside pongTimeout',
        );

        monitor.stop();
      });
    });

    test('stop() is final — no ping or disconnect after it', () {
      fakeAsync((async) {
        var pings = 0;
        var disconnects = 0;
        final monitor = KeepAliveMonitor(
          onSendPing: () => pings++,
          onDisconnect: () => disconnects++,
          idleThreshold: const Duration(seconds: 1),
          pongTimeout: const Duration(seconds: 1),
        );

        monitor.stop();
        monitor.notifyMessageReceived();
        async.elapse(const Duration(seconds: 30));

        expect(pings, 0);
        expect(disconnects, 0);
      });
    });
  });
}
