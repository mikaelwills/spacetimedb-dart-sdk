import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:spacetimedb_sdk/spacetimedb_sdk.dart';

import '../../mocks/silent_socket.dart';

void main() {
  group('VM app-level keep-alive', () {
    late SilentWebSocketChannel socket;

    SpacetimeDbConnection build(ConnectionConfig config) {
      socket = SilentWebSocketChannel();
      return SpacetimeDbConnection(
        host: 'localhost:3000',
        database: 'notesdb',
        config: config,
        socketFactory: (uri, protocols, headers, {
          connectTimeout = const Duration(seconds: 10),
          pingInterval,
        }) => socket,
      );
    }

    test(
      'appLevelKeepAlive: a socket that accepts sends and never replies is '
      'detected and closed',
      () async {
        final connection = build(
          const ConnectionConfig(
            autoReconnect: false,
            pingInterval: Duration(milliseconds: 40),
            pongTimeout: Duration(milliseconds: 40),
            appLevelKeepAlive: true,
          ),
        );
        addTearDown(connection.dispose);

        await connection.connect();
        expect(connection.isConnected, isTrue);

        await Future<void>.delayed(const Duration(milliseconds: 300));

        expect(
          socket.sent,
          isNotEmpty,
          reason:
              'with the app-level keep-alive on, the SDK must send at least '
              'one application-level ping into a silent socket — without it '
              'nothing in the SDK ever probes liveness on the VM',
        );
        expect(
          socket.closeCalls,
          greaterThan(0),
          reason:
              'no reply arrived within pongTimeout, so the SDK must declare '
              'the socket stale and close the sink, which is what feeds the '
              'existing onDone → reconnect path',
        );
      },
    );

    test(
      'the keep-alive arms without any inbound message ever arriving',
      () async {
        final connection = build(
          const ConnectionConfig(
            autoReconnect: false,
            pingInterval: Duration(milliseconds: 40),
            pongTimeout: Duration(seconds: 30),
            appLevelKeepAlive: true,
          ),
        );
        addTearDown(connection.dispose);

        await connection.connect();
        await Future<void>.delayed(const Duration(milliseconds: 200));

        expect(
          socket.sent,
          isNotEmpty,
          reason:
              'zero inbound messages were delivered; the monitor must still '
              'have armed at setup',
        );
      },
    );

    test('inbound traffic suppresses the ping', () async {
      final connection = build(
        const ConnectionConfig(
          autoReconnect: false,
          pingInterval: Duration(milliseconds: 120),
          pongTimeout: Duration(milliseconds: 120),
          appLevelKeepAlive: true,
        ),
      );
      addTearDown(connection.dispose);

      await connection.connect();

      for (var i = 0; i < 6; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        socket.deliver(Uint8List.fromList([0]));
      }

      expect(
        socket.sent,
        isEmpty,
        reason: 'traffic proves health — the debounce must suppress pings',
      );
      expect(socket.closeCalls, 0);
    });

    test(
      'default config: no app-level ping is sent (flag is off by default)',
      () async {
        final connection = build(
          const ConnectionConfig(
            autoReconnect: false,
            pingInterval: Duration(milliseconds: 40),
            pongTimeout: Duration(milliseconds: 40),
          ),
        );
        addTearDown(connection.dispose);

        await connection.connect();
        await Future<void>.delayed(const Duration(milliseconds: 300));

        expect(
          socket.sent,
          isEmpty,
          reason:
              'appLevelKeepAlive defaults to false — behaviour must be '
              'byte-identical to today so this stays a MINOR bump',
        );
        expect(socket.closeCalls, 0);
      },
    );

    test(
      'a long silent gap with work in flight does not close a healthy socket',
      () async {
        final connection = build(
          const ConnectionConfig(
            autoReconnect: false,
            pingInterval: Duration(milliseconds: 40),
            pongTimeout: Duration(milliseconds: 40),
            appLevelKeepAlive: true,
          ),
        );
        addTearDown(connection.dispose);

        await connection.connect();
        connection.setKeepAliveWorkInFlight(true);

        await Future<void>.delayed(const Duration(milliseconds: 300));

        expect(
          socket.sent,
          isNotEmpty,
          reason:
              'deferral must not disable probing — the monitor keeps pinging '
              'on its normal cadence while work is in flight',
        );
        expect(
          socket.closeCalls,
          0,
          reason:
              'the server is assembling a subscription snapshot, so there is '
              'zero inbound traffic to re-arm on; a connection that is '
              'provably alive must not be declared dead inside this window',
        );
      },
    );

    test(
      'a dead socket with work in flight is still detected once the deferral '
      'bound elapses',
      () async {
        final connection = build(
          const ConnectionConfig(
            autoReconnect: false,
            pingInterval: Duration(milliseconds: 40),
            pongTimeout: Duration(milliseconds: 40),
            appLevelKeepAlive: true,
          ),
        );
        addTearDown(connection.dispose);

        await connection.connect();
        connection.setKeepAliveWorkInFlight(true);

        await Future<void>.delayed(const Duration(milliseconds: 1500));

        expect(
          socket.closeCalls,
          greaterThan(0),
          reason:
              'the deferral is bounded — a socket that never answers any ping '
              'must still be declared dead, otherwise liveness detection is '
              'lost whenever a subscribe is in flight',
        );
      },
    );

    test(
      'the deferral budget is spent per gap, not per connection: traffic '
      'between two long gaps restores the full budget',
      () async {
        final connection = build(
          const ConnectionConfig(
            autoReconnect: false,
            pingInterval: Duration(milliseconds: 40),
            pongTimeout: Duration(milliseconds: 40),
            appLevelKeepAlive: true,
          ),
        );
        addTearDown(connection.dispose);

        await connection.connect();
        connection.setKeepAliveWorkInFlight(true);

        for (var gap = 0; gap < 3; gap++) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
          expect(
            socket.closeCalls,
            0,
            reason:
                'gap $gap: the snapshot for the previous query set landed, so '
                'the deferral budget must have been reset — a consumer with '
                'many query sets in one resubscribe must not accumulate its '
                'way to a spurious kill',
          );
          socket.deliver(Uint8List.fromList([0]));
        }
      },
    );

    test(
      'clearing the in-flight signal restores immediate dead-socket detection',
      () async {
        final connection = build(
          const ConnectionConfig(
            autoReconnect: false,
            pingInterval: Duration(milliseconds: 40),
            pongTimeout: Duration(milliseconds: 40),
            appLevelKeepAlive: true,
          ),
        );
        addTearDown(connection.dispose);

        await connection.connect();
        connection.setKeepAliveWorkInFlight(true);
        await Future<void>.delayed(const Duration(milliseconds: 120));
        expect(socket.closeCalls, 0);

        connection.setKeepAliveWorkInFlight(false);
        await Future<void>.delayed(const Duration(milliseconds: 300));

        expect(
          socket.closeCalls,
          greaterThan(0),
          reason:
              'once the subscribe completes the connection is back to normal '
              'rules — a silent socket must be killed on the first missed '
              'pong, exactly as it was before this change',
        );
      },
    );

    test('ConnectionConfig.mobile does not opt in', () {
      expect(
        ConnectionConfig.mobile.appLevelKeepAlive,
        isFalse,
        reason:
            'turning it on for mobile by default changes runtime behaviour '
            'with no compile error — that is a MAJOR, and is Mikael\'s call',
      );
    });
  });
}
