import 'dart:async';

import 'package:spacetimedb_sdk/spacetimedb_sdk.dart';
import 'package:test/test.dart';

import '../../helpers/test_jwt.dart';
import '../../mocks/silent_socket.dart';

class _GatedChannel extends SilentWebSocketChannel {
  _GatedChannel(this._ready);

  final Future<void> _ready;

  @override
  Future<void> get ready => _ready;
}

class _Harness {
  _Harness({
    String? initialToken,
    TokenProvider? tokenProvider,
    this.failWith,
    bool retryInitialConnect = false,
  }) {
    connection = SpacetimeDbConnection(
      host: 'localhost:3000',
      database: 'notesdb',
      initialToken: initialToken,
      tokenProvider: tokenProvider,
      config: ConnectionConfig(
        autoReconnect: true,
        retryInitialConnect: retryInitialConnect,
        baseReconnectDelay: const Duration(milliseconds: 10),
        maxReconnectDelay: const Duration(milliseconds: 10),
        maxReconnectAttempts: 20,
      ),
      socketFactory:
          (
            uri,
            protocols,
            headers, {
            connectTimeout = const Duration(seconds: 10),
            pingInterval,
          }) {
            final authorization = headers?['Authorization'];
            authHeaders.add(authorization is String ? authorization : null);
            final failure = failWith?.call(authHeaders.length);
            if (failure != null) throw failure;
            socket = SilentWebSocketChannel();
            return socket!;
          },
    );
    connection.onStateChanged.listen(states.add);
  }

  late final SpacetimeDbConnection connection;
  Object? Function(int call)? failWith;
  final List<String?> authHeaders = <String?>[];
  final List<ConnectionState> states = <ConnectionState>[];
  SilentWebSocketChannel? socket;

  Future<void> dropSocket() => socket!.sink.close();

  Future<void> waitFor(bool Function() condition) async {
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('condition not met; states: $states, headers: $authHeaders');
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  Future<void> waitForConnects(int count) => waitFor(
    () =>
        states.whereType<Connected>().length >= count &&
        connection.state is Connected,
  );
}

class _CountingProvider {
  _CountingProvider(this._results);

  final List<FutureOr<String> Function()> _results;
  int calls = 0;

  Future<String> call() async {
    final result = _results[calls.clamp(0, _results.length - 1)];
    calls++;
    return result();
  }
}

Exception _upgradeFailure(int status) => Exception(
  "WebSocketException: Connection to 'http://localhost:3000' was not "
  'upgraded to websocket, HTTP status code: $status',
);

void main() {
  final now = DateTime.now();
  final nearExpiry = testJwtExpiring(
    now,
    age: const Duration(hours: 1),
    remaining: const Duration(seconds: 5),
  );
  final farFromExpiry = testJwtExpiring(
    now,
    age: const Duration(minutes: 1),
    remaining: const Duration(hours: 1),
  );
  final provided = testJwt({
    'sub': 'provided',
    'iat': epochSeconds(now),
    'exp': epochSeconds(now.add(const Duration(hours: 1))),
  });
  final second = testJwt({
    'sub': 'second',
    'iat': epochSeconds(now),
    'exp': epochSeconds(now.add(const Duration(hours: 1))),
  });

  group('token provider before a reconnect', () {
    test('is not called for the first connect', () async {
      final provider = _CountingProvider([() => provided]);
      final harness = _Harness(
        initialToken: nearExpiry,
        tokenProvider: provider.call,
      );
      addTearDown(harness.connection.dispose);

      await harness.connection.connect();

      expect(provider.calls, 0);
      expect(harness.authHeaders.single, 'Bearer $nearExpiry');
    });

    test('refreshes a near-expiry token before the reconnect', () async {
      final provider = _CountingProvider([() => provided]);
      final harness = _Harness(
        initialToken: nearExpiry,
        tokenProvider: provider.call,
      );
      addTearDown(harness.connection.dispose);
      await harness.connection.connect();

      await harness.dropSocket();
      await harness.waitForConnects(2);

      expect(provider.calls, 1);
      expect(harness.authHeaders.last, 'Bearer $provided');
      expect(harness.connection.token, provided);
    });

    test('keeps a token far from expiry', () async {
      final provider = _CountingProvider([() => provided]);
      final harness = _Harness(
        initialToken: farFromExpiry,
        tokenProvider: provider.call,
      );
      addTearDown(harness.connection.dispose);
      await harness.connection.connect();

      await harness.dropSocket();
      await harness.waitForConnects(2);

      expect(provider.calls, 0);
      expect(harness.authHeaders.last, 'Bearer $farFromExpiry');
    });

    test('refreshes a token without exp before every reconnect', () async {
      final noExp = testJwt({'iat': epochSeconds(now)});
      final provider = _CountingProvider([() => noExp]);
      final harness = _Harness(
        initialToken: noExp,
        tokenProvider: provider.call,
      );
      addTearDown(harness.connection.dispose);
      await harness.connection.connect();

      await harness.dropSocket();
      await harness.waitForConnects(2);
      await harness.dropSocket();
      await harness.waitForConnects(3);

      expect(provider.calls, 2);
    });

    test('without a provider the reconnect sends the same token', () async {
      final harness = _Harness(initialToken: nearExpiry);
      addTearDown(harness.connection.dispose);
      await harness.connection.connect();

      await harness.dropSocket();
      await harness.waitForConnects(2);

      expect(harness.authHeaders.last, 'Bearer $nearExpiry');
    });

    test('a provider error is a failed attempt that backs off', () async {
      final provider = _CountingProvider([
        () => throw StateError('identity service down (401)'),
        () => provided,
      ]);
      final harness = _Harness(
        initialToken: nearExpiry,
        tokenProvider: provider.call,
      );
      addTearDown(harness.connection.dispose);
      await harness.connection.connect();

      await harness.dropSocket();
      await harness.waitForConnects(2);

      expect(provider.calls, 2);
      expect(harness.states.whereType<AuthError>(), isEmpty);
      expect(harness.authHeaders.last, 'Bearer $provided');
      expect(harness.authHeaders, hasLength(2));
    });

    test(
      'an empty provider result is a failed attempt that backs off',
      () async {
        final provider = _CountingProvider([() => '', () => provided]);
        final harness = _Harness(
          initialToken: nearExpiry,
          tokenProvider: provider.call,
        );
        addTearDown(harness.connection.dispose);
        await harness.connection.connect();

        await harness.dropSocket();
        await harness.waitForConnects(2);

        expect(provider.calls, 2);
        expect(harness.states.whereType<AuthError>(), isEmpty);
        expect(harness.authHeaders.last, 'Bearer $provided');
      },
    );

    test('a disconnect while the provider runs opens no socket', () async {
      final release = Completer<String>();
      final provider = _CountingProvider([() => release.future]);
      final harness = _Harness(
        initialToken: nearExpiry,
        tokenProvider: provider.call,
      );
      addTearDown(harness.connection.dispose);
      await harness.connection.connect();

      await harness.dropSocket();
      await harness.waitFor(() => provider.calls == 1);
      await harness.connection.disconnect();
      release.complete(provided);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(harness.authHeaders, hasLength(1));
      expect(harness.connection.state, isA<Disconnected>());
    });
  });

  group('token provider after a rejection', () {
    test('a 401 on reconnect recovers through one forced refresh', () async {
      final provider = _CountingProvider([() => provided]);
      final harness = _Harness(
        initialToken: farFromExpiry,
        tokenProvider: provider.call,
      );
      addTearDown(harness.connection.dispose);
      await harness.connection.connect();
      harness.failWith = (call) => call == 2 ? _upgradeFailure(401) : null;

      await harness.dropSocket();
      await harness.waitForConnects(2);

      expect(provider.calls, 1);
      expect(harness.states.whereType<AuthError>(), isEmpty);
      expect(harness.authHeaders, [
        'Bearer $farFromExpiry',
        'Bearer $farFromExpiry',
        'Bearer $provided',
      ]);
    });

    test('a rejected fresh token ends in AuthError', () async {
      final provider = _CountingProvider([() => provided]);
      final harness = _Harness(
        initialToken: farFromExpiry,
        tokenProvider: provider.call,
      );
      addTearDown(harness.connection.dispose);
      await harness.connection.connect();
      harness.failWith = (call) => _upgradeFailure(401);

      await harness.dropSocket();
      await harness.waitFor(() => harness.connection.state is AuthError);
      final dialsAtAuthError = harness.authHeaders.length;
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(provider.calls, 1);
      expect(dialsAtAuthError, 3);
      expect(harness.authHeaders, hasLength(dialsAtAuthError));
    });

    test('a 403 with a provider recovers through one forced refresh', () async {
      final provider = _CountingProvider([() => provided]);
      final harness = _Harness(
        initialToken: farFromExpiry,
        tokenProvider: provider.call,
      );
      addTearDown(harness.connection.dispose);
      await harness.connection.connect();
      harness.failWith = (call) => call == 2 ? _upgradeFailure(403) : null;

      await harness.dropSocket();
      await harness.waitForConnects(2);

      expect(provider.calls, 1);
      expect(harness.authHeaders.last, 'Bearer $provided');
    });

    test('without a provider a 401 on reconnect ends in AuthError', () async {
      final harness = _Harness(initialToken: farFromExpiry);
      addTearDown(harness.connection.dispose);
      await harness.connection.connect();
      harness.failWith = (call) => _upgradeFailure(401);

      await harness.dropSocket();
      await harness.waitFor(() => harness.connection.state is AuthError);

      expect(harness.authHeaders, hasLength(2));
    });

    test('without a provider a 403 on reconnect is retried', () async {
      final harness = _Harness(initialToken: farFromExpiry);
      addTearDown(harness.connection.dispose);
      await harness.connection.connect();
      harness.failWith = (call) => call == 2 ? _upgradeFailure(403) : null;

      await harness.dropSocket();
      await harness.waitForConnects(2);

      expect(harness.states.whereType<AuthError>(), isEmpty);
      expect(harness.authHeaders.last, 'Bearer $farFromExpiry');
    });

    test('a 401 on the first connect does not call the provider', () async {
      final provider = _CountingProvider([() => provided]);
      final harness = _Harness(
        initialToken: farFromExpiry,
        tokenProvider: provider.call,
        retryInitialConnect: true,
        failWith: (call) => _upgradeFailure(401),
      );
      addTearDown(harness.connection.dispose);

      await expectLater(
        harness.connection.connect(),
        throwsA(isA<SpacetimeDbAuthException>()),
      );

      expect(provider.calls, 0);
      expect(harness.authHeaders, hasLength(1));
    });

    test(
      'a manual reconnect after AuthError gets the same forced refresh',
      () async {
        final provider = _CountingProvider([() => provided, () => second]);
        final harness = _Harness(
          initialToken: farFromExpiry,
          tokenProvider: provider.call,
        );
        addTearDown(harness.connection.dispose);
        await harness.connection.connect();
        harness.failWith = (call) => call <= 3 ? _upgradeFailure(401) : null;
        await harness.dropSocket();
        await harness.waitFor(() => harness.connection.state is AuthError);

        harness.failWith = (call) => call == 4 ? _upgradeFailure(401) : null;
        await harness.connection.reconnect();

        expect(harness.connection.state, isA<Connected>());
        expect(provider.calls, 2);
        expect(harness.authHeaders.last, 'Bearer $second');
      },
    );
  });

  group('token provider with overlapping reconnects', () {
    late List<String?> headers;
    late List<Completer<void>> readies;
    late List<SilentWebSocketChannel> sockets;
    late List<ConnectionState> states;

    SpacetimeDbConnection build(
      TokenProvider provider, {
      bool gateReady = true,
    }) {
      headers = <String?>[];
      readies = <Completer<void>>[];
      sockets = <SilentWebSocketChannel>[];
      states = <ConnectionState>[];
      final connection = SpacetimeDbConnection(
        host: 'localhost:3000',
        database: 'notesdb',
        initialToken: nearExpiry,
        tokenProvider: provider,
        config: const ConnectionConfig(
          autoReconnect: true,
          retryInitialConnect: false,
          baseReconnectDelay: Duration(milliseconds: 10),
          maxReconnectDelay: Duration(milliseconds: 10),
          maxReconnectAttempts: 20,
        ),
        socketFactory:
            (
              uri,
              protocols,
              requestHeaders, {
              connectTimeout = const Duration(seconds: 10),
              pingInterval,
            }) {
              final authorization = requestHeaders?['Authorization'];
              headers.add(authorization is String ? authorization : null);
              final ready = Completer<void>();
              if (headers.length == 1 || !gateReady) ready.complete();
              readies.add(ready);
              final socket = _GatedChannel(ready.future);
              sockets.add(socket);
              return socket;
            },
      );
      connection.onStateChanged.listen(states.add);
      return connection;
    }

    Future<void> until(bool Function() condition) async {
      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while (!condition()) {
        if (DateTime.now().isAfter(deadline)) {
          fail('condition not met; states: $states, headers: $headers');
        }
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }

    test(
      'a manual reconnect while the provider runs opens one socket',
      () async {
        final timerToken = Completer<String>();
        final manualToken = Completer<String>();
        var calls = 0;
        final connection = build(() {
          calls++;
          return calls == 1 ? timerToken.future : manualToken.future;
        });
        addTearDown(connection.dispose);
        await connection.connect();

        await sockets.first.sink.close();
        await until(() => calls == 1);
        final manual = connection.reconnect();
        await until(() => calls == 2);
        timerToken.complete(provided);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        manualToken.complete(second);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        for (final ready in readies) {
          if (!ready.isCompleted) ready.complete();
        }
        await manual;

        expect(headers, ['Bearer $nearExpiry', 'Bearer $second']);
        expect(connection.state, isA<Connected>());
      },
    );

    test('a provider error from a superseded attempt leaves the manual '
        'reconnect connected', () async {
      final timerToken = Completer<String>();
      final manualToken = Completer<String>();
      var calls = 0;
      final connection = build(() {
        calls++;
        return calls == 1 ? timerToken.future : manualToken.future;
      }, gateReady: false);
      addTearDown(connection.dispose);
      await connection.connect();

      await sockets.first.sink.close();
      await until(() => calls == 1);
      final manual = connection.reconnect();
      await until(() => calls == 2);
      timerToken.completeError(Exception('refresh endpoint down'));
      await Future<void>.delayed(const Duration(milliseconds: 1));
      manualToken.complete(second);
      await manual;

      expect(connection.state, isA<Connected>());
      expect(headers, ['Bearer $nearExpiry', 'Bearer $second']);
    });
  });
}
