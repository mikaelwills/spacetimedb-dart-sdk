import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';
import 'package:spacetimedb_sdk/src/connection/keep_alive_monitor.dart';

const _second = Duration(seconds: 1);
const _settleMargin = Duration(milliseconds: 100);
const _pastPongTimeout = Duration(milliseconds: 2100);
const _latePongCycles = 500;

KeepAliveMonitor _monitor({
  required void Function() onDisconnect,
  required Future<bool> Function() confirmServerAlive,
  void Function()? onSendPing,
}) => KeepAliveMonitor(
  onSendPing: onSendPing ?? () {},
  onDisconnect: onDisconnect,
  confirmServerAlive: confirmServerAlive,
  idleThreshold: _second,
  pongTimeout: _second,
);

void main() {
  group('KeepAliveMonitor with a server check', () {
    test('keeps the socket when the server answers the check', () {
      fakeAsync((async) {
        var pings = 0;
        var disconnects = 0;
        final monitor = _monitor(
          onSendPing: () => pings++,
          onDisconnect: () => disconnects++,
          confirmServerAlive: () async => true,
        );

        async.elapse(_pastPongTimeout);
        expect(disconnects, 0);

        async.elapse(_second);
        expect(
          pings,
          2,
          reason: 'the monitor pings again after keeping the socket',
        );
        monitor.stop();
      });
    });

    test('declares the socket dead when the server check fails', () {
      fakeAsync((async) {
        var disconnects = 0;
        final monitor = _monitor(
          onDisconnect: () => disconnects++,
          confirmServerAlive: () async => false,
        );

        async.elapse(_pastPongTimeout);
        expect(disconnects, 1);
        monitor.stop();
      });
    });

    test('a check that throws counts as a failed check', () {
      fakeAsync((async) {
        var disconnects = 0;
        final monitor = _monitor(
          onDisconnect: () => disconnects++,
          confirmServerAlive: () async => throw StateError('no network'),
        );

        async.elapse(_pastPongTimeout);
        expect(disconnects, 1);
        monitor.stop();
      });
    });

    test('a frame that arrives during the check keeps the socket', () {
      fakeAsync((async) {
        var disconnects = 0;
        final check = Completer<bool>();
        final monitor = _monitor(
          onDisconnect: () => disconnects++,
          confirmServerAlive: () => check.future,
        );

        async.elapse(_pastPongTimeout);
        monitor.notifyMessageReceived();
        check.complete(false);
        async.flushMicrotasks();
        expect(disconnects, 0);
        monitor.stop();
      });
    });

    test('keeps the socket however many late pongs the server answers for', () {
      fakeAsync((async) {
        var disconnects = 0;
        final monitor = _monitor(
          onDisconnect: () => disconnects++,
          confirmServerAlive: () async => true,
        );

        final cycle = _second * 2;
        async.elapse(cycle * _latePongCycles);
        expect(disconnects, 0);
        monitor.stop();
      });
    });
  });
}
