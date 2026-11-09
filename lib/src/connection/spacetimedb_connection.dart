import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';
import 'package:spacetimedb_sdk/src/auth/token_provider.dart';
import 'package:spacetimedb_sdk/src/auth/token_refresh.dart';
import 'package:spacetimedb_sdk/src/connection/connection_state.dart';
import 'package:spacetimedb_sdk/src/exceptions.dart';
import 'package:spacetimedb_sdk/src/connection/connection_quality.dart';
import 'package:spacetimedb_sdk/src/connection/connection_config.dart';
import 'package:spacetimedb_sdk/src/connection/keep_alive_monitor.dart';
import 'package:spacetimedb_sdk/src/messages/client_messages.dart';
import 'package:spacetimedb_sdk/src/messages/decompress.dart';
import 'package:spacetimedb_sdk/src/utils/sdk_logger.dart';

import 'platform.dart' show kIsWeb;

import 'package:web_socket_channel/web_socket_channel.dart';

import 'websocket.dart' as ws;
import 'websocket_protocols.dart';
import 'websocket_v3_frames.dart';

typedef WebSocketFactory = WebSocketChannel Function(
  Uri uri,
  Iterable<String>? protocols,
  Map<String, dynamic>? headers, {
  Duration connectTimeout,
  Duration? pingInterval,
});

final Expando<void Function(String reason)> _reconnectClosers = Expando();

@internal
void closeForReconnect(SpacetimeDbConnection connection, String reason) {
  _reconnectClosers[connection]?.call(reason);
}

@internal
void setReconnectCloser(
  SpacetimeDbConnection connection,
  void Function(String reason) closer,
) {
  _reconnectClosers[connection] = closer;
}

final Expando<bool Function()> _connectSentTokenReaders = Expando();

@internal
bool connectSentToken(SpacetimeDbConnection connection) {
  final readConnectSentToken = _connectSentTokenReaders[connection];
  return readConnectSentToken != null && readConnectSentToken();
}

final Expando<void Function(String reason)> _identityChangeStoppers = Expando();

@internal
void stopForIdentityChange(SpacetimeDbConnection connection, String reason) {
  _identityChangeStoppers[connection]?.call(reason);
}

final Expando<bool> _subscribeBatchesInFlight = Expando();

final Expando<bool> _subscribeBatchesUnsupported = Expando();

@internal
void setSubscribeBatchInFlight(
  SpacetimeDbConnection connection,
  bool inFlight,
) {
  _subscribeBatchesInFlight[connection] = inFlight;
}

@internal
bool subscribeBatchUnsupported(SpacetimeDbConnection connection) =>
    _subscribeBatchesUnsupported[connection] ?? false;

const _internalErrorCloseCode = 1011;

const _sessionBusyCloseCode = 4000;

const _sessionBusyMinDelay = Duration(milliseconds: 500);

final RegExp _unknownClientMessageTag = RegExp(
  r'unknown tag 0x[0-9a-fA-F]+ for sum type ClientMessage',
);

@internal
@visibleForTesting
void noteSocketClosed(
  SpacetimeDbConnection connection, {
  int? closeCode,
  String? closeReason,
}) {
  final batchInFlight = _subscribeBatchesInFlight[connection] ?? false;
  if (!batchInFlight ||
      closeCode != _internalErrorCloseCode ||
      closeReason == null) {
    return;
  }
  if (!_unknownClientMessageTag.hasMatch(closeReason)) return;
  _subscribeBatchesUnsupported[connection] = true;
}

@internal
@visibleForTesting
void setSubscribeBatchUnsupported(
  SpacetimeDbConnection connection,
  bool unsupported,
) {
  _subscribeBatchesUnsupported[connection] = unsupported;
}

final Expando<double Function()> _reconnectRandoms = Expando();

@visibleForTesting
void setReconnectRandom(
  SpacetimeDbConnection connection,
  double Function() random,
) {
  _reconnectRandoms[connection] = random;
}

@visibleForTesting
Duration reconnectDelay(
  int attempt,
  double random, {
  required Duration base,
  required Duration max,
}) {
  final baseMs = base.inMilliseconds;
  final maxMs = max.inMilliseconds;
  final exponent = (attempt - 1).clamp(0, 30);
  final cappedMs = math.min(baseMs * math.pow(2, exponent), maxMs);
  final jitteredMs = cappedMs * (0.5 + random);
  return Duration(milliseconds: jitteredMs.toInt().clamp(baseMs, maxMs));
}

String _newSessionId() {
  final random = math.Random.secure();
  return [
    for (var i = 0; i < 16; i++)
      random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ].join();
}

class SpacetimeDbConnection {
  final String host;
  final String database;
  final String? initialToken;
  final bool ssl;
  final ConnectionConfig config;
  final WebSocketFactory _socketFactory;
  final TokenProvider? _tokenProvider;
  bool _hasEverConnected = false;
  bool _forceTokenRefresh = false;
  bool _usedFreshToken = false;
  int _connectAttempt = 0;

  int _reconnectAttempts = 0;
  final math.Random _reconnectRandom = math.Random();
  final String _sessionId = _newSessionId();
  int _attemptsAtDial = 0;
  bool _socketReceivedFrame = false;
  bool _connectSentToken = false;
  Timer? _reconnectTimer;
  bool _shouldReconnect = false;
  int _nextRequestId = 1;

  String? _currentToken;

  KeepAliveMonitor? _keepAlive;
  DateTime? _lastMessageReceived;
  DateTime? _lastPingSent;

  WebSocketChannel? _channel;
  NegotiatedWsProtocol _negotiatedProtocol = NegotiatedWsProtocol.v2;

  final List<Uint8List> _outboundQueue = <Uint8List>[];
  bool _isOutboundFlushScheduled = false;

  ConnectionState _state = const Disconnected();
  final StreamController<ConnectionState> _stateController =
      StreamController<ConnectionState>.broadcast();

  final StreamController<ConnectionQuality> _qualityController =
      StreamController<ConnectionQuality>.broadcast();
  String? _lastError;
  DateTime? _lastSuccessfulConnection;
  ConnectionState? _lastLoggedState;

  final StreamController<Uint8List> _messageController =
      StreamController<Uint8List>.broadcast();
  final StreamController<String> _errorController =
      StreamController<String>.broadcast();

  Stream<ConnectionState> get onStateChanged => _stateController.stream;

  Stream<ConnectionQuality> get connectionQuality => _qualityController.stream;

  ConnectionState get state => _state;

  Stream<Uint8List> get onMessage => _messageController.stream;

  Stream<String> get onError => _errorController.stream;

  bool get isConnected => _state is Connected;

  String? get token => _currentToken;

  NegotiatedWsProtocol get negotiatedProtocol => _negotiatedProtocol;

  SpacetimeDbConnection({
    required this.host,
    required this.database,
    this.initialToken,
    this.ssl = false,
    this.config = const ConnectionConfig(),
    this._tokenProvider,
    WebSocketFactory? socketFactory,
  }) : _currentToken = initialToken,
       _socketFactory = socketFactory ?? ws.connectWebSocket {
    _shouldReconnect = config.autoReconnect;
    setReconnectCloser(this, _closeForReconnect);
    _connectSentTokenReaders[this] = () => _connectSentToken;
    _identityChangeStoppers[this] = _stopForIdentityChange;
    scheduleMicrotask(() => _updateQuality());
  }

  void updateToken(String token) {
    _currentToken = token;
    SdkLogger.i('Authentication token updated');
  }

  void clearToken() {
    _currentToken = null;
    SdkLogger.i('Authentication token cleared');
  }

  Future<void> connect() async {
    try {
      return await _connectWithRetry();
    } on SpacetimeDbAuthException {
      if (!_canRetryWithFreshToken) rethrow;
      SdkLogger.w('Token rejected; retrying once with a provided token');
      _forceTokenRefresh = true;
      return _connectWithRetry();
    }
  }

  Future<void> disconnect() async {
    if (_state is Disconnected) {
      return;
    }
    _shouldReconnect = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _keepAlive?.stop();
    _updateState(const Disconnected());
    await _channel?.sink.close();
    _channel = null;
    _negotiatedProtocol = NegotiatedWsProtocol.v2;
    if (_outboundQueue.isNotEmpty) {
      SdkLogger.w(
        'Dropping ${_outboundQueue.length} queued outbound message(s) on '
        'disconnect',
      );
      _outboundQueue.clear();
    }
  }

  void send(Uint8List data) {
    if (!isConnected) {
      SdkLogger.i('Cannot send: not connected');
      return;
    }
    if (!_socketReceivedFrame) {
      _outboundQueue.add(Uint8List.fromList(data));
      return;
    }
    _write(data);
  }

  void setKeepAliveWorkInFlight(bool inFlight) {
    _keepAlive?.setWorkInFlight(inFlight);
  }

  void enableAutoReconnect(bool enabled) {
    _shouldReconnect = enabled;
  }

  Future<void> reconnect() async {
    await disconnect();
    _reconnectAttempts = 0;
    _updateQuality();
    _shouldReconnect = true;
    await connect();
  }

  Future<void> retryConnection() async {
    if (_state is! FatalError && _state is! Disconnected) {
      throw StateError('Cannot retry when state is $_state');
    }

    SdkLogger.i('Manual retry initiated');
    _reconnectAttempts = 0;
    _updateQuality();
    _shouldReconnect = true;
    await connect();
  }

  @Deprecated('Use SubscriptionManager.reducers.call() for async/await support')
  Future<void> callReducer(
    String reducerName,
    Uint8List args, {
    int? requestId,
  }) async {
    final message = CallReducerMessage(
      reducerName: reducerName,
      args: args,
      requestId: requestId ?? _nextRequestId++,
    );

    send(message.encode());
  }

  Future<void> dispose() async {
    _keepAlive?.stop();
    await disconnect();
    await _qualityController.close();
    await _stateController.close();
    await _messageController.close();
    await _errorController.close();
  }

  bool get _canRetryWithFreshToken =>
      _tokenProvider != null && _hasEverConnected && !_usedFreshToken;

  Future<void> _connectWithRetry() async {
    if (!config.retryInitialConnect) {
      return _connectOnce();
    }
    var attempt = 0;
    while (true) {
      attempt++;
      try {
        return await _connectOnce();
      } on SpacetimeDbAuthException {
        rethrow;
      } catch (e) {
        if (attempt >= config.maxReconnectAttempts) {
          SdkLogger.e(
            'Initial connect failed after $attempt attempt(s); giving up',
          );
          _updateState(
            const FatalError(message: 'Max initial connect attempts reached'),
          );
          rethrow;
        }
        _reconnectAttempts = attempt - 1;
        final delay = _getReconnectDelay(attempt);
        SdkLogger.w(
          'Initial connect attempt $attempt failed ($e); '
          'retrying in ${delay.inSeconds}s',
        );
        _updateState(Reconnecting(attempt: attempt, nextDelay: delay));
        await Future<void>.delayed(delay);
        if (_state is FatalError) rethrow;
      }
    }
  }

  Future<void> _connectOnce() async {
    if (_state is! Disconnected && _state is! Reconnecting) {
      SdkLogger.i('Already connected or connecting');
      return;
    }
    _attemptsAtDial = _reconnectAttempts;
    _socketReceivedFrame = false;
    _shouldReconnect = true;
    _updateState(const Connecting());

    final attempt = ++_connectAttempt;
    await _refreshTokenIfNeeded(attempt);
    if (_state is! Connecting || attempt != _connectAttempt) return;

    try {
      final protocol = ssl ? 'wss' : 'ws';
      var uri = Uri.parse('$protocol://$host/v1/database/$database/subscribe');

      final headers = <String, dynamic>{};

      final queryParams = <String, String>{};
      if (!brotliNativelySupported) {
        // Server default is Brotli; pure-Dart `package:brotli` miscompiles on
        // dart2js; older browsers lack DecompressionStream('br') (Chrome 138+
        // / Firefox 142+). Ask server to skip compression when we can't
        // decompress Brotli ourselves.
        queryParams['compression'] = 'None';
      }
      if (kIsWeb && _currentToken != null) {
        final wsToken = await _getWebSocketToken();
        if (wsToken != null) {
          queryParams['token'] = wsToken;
        }
      } else if (_currentToken != null) {
        headers['Authorization'] = 'Bearer $_currentToken';
      }
      if (config.autoReconnect) {
        queryParams['session_id'] = _sessionId;
      }
      if (queryParams.isNotEmpty) {
        uri = uri.replace(queryParameters: queryParams);
      }
      _connectSentToken =
          headers.containsKey('Authorization') ||
          queryParams.containsKey('token');

      _channel = _socketFactory(
        uri,
        kPreferredWsProtocols,
        headers,
        connectTimeout: config.connectTimeout,
        // On VM, IOWebSocketChannel uses this to send WS-level Ping
        // frames. On web it's ignored (HtmlWebSocketChannel doesn't
        // expose WS ping/pong to JS).
        pingInterval: kIsWeb ? null : config.pingInterval,
      );
      await _channel!.ready;
      _negotiatedProtocol = normalizeWsProtocol(_channel!.protocol);
      SdkLogger.i('Negotiated WebSocket protocol: ${_negotiatedProtocol.name}');
      _setupMessageListener();
      if (kIsWeb || config.appLevelKeepAlive) {
        _setupKeepAlive();
      }
      _updateState(const Connected());
      _hasEverConnected = true;
      _reconnectAttempts = 0;
      _updateQuality();
    } catch (e) {
      SdkLogger.e('Connection failed: $e');
      _updateState(const Disconnected());
      _channel = null;

      if (_isAuthFailure(e.toString())) {
        throw SpacetimeDbAuthException(
          'Authentication failed (401). Token may be invalid or expired.',
        );
      }

      throw SpacetimeDbConnectionException(
        'Connection failed: $e',
        lastKnownState: const Disconnected(),
      );
    }
  }

  static final _httpStatus = RegExp(r'HTTP status code: (\d+)$');

  bool _isAuthFailure(String error) {
    final status = int.tryParse(_httpStatus.firstMatch(error)?.group(1) ?? '');
    if (status == 401 || error.contains('Unauthorized')) return true;
    return _tokenProvider != null && status == 403;
  }

  Future<void> _refreshTokenIfNeeded(int attempt) async {
    _usedFreshToken = false;
    final provider = _tokenProvider;
    if (provider == null || !_hasEverConnected) return;
    if (!_forceTokenRefresh &&
        !tokenNeedsRefresh(_currentToken, DateTime.now())) {
      return;
    }

    final String fresh;
    try {
      fresh = await provider();
    } catch (e) {
      if (attempt != _connectAttempt) return;
      _failTokenRefresh('$e');
    }
    if (attempt != _connectAttempt) return;
    if (fresh.isEmpty) _failTokenRefresh('empty token');

    updateToken(fresh);
    _forceTokenRefresh = false;
    _usedFreshToken = true;
  }

  Never _failTokenRefresh(String reason) {
    SdkLogger.e('Token provider failed: $reason');
    if (_state is Connecting) _updateState(const Disconnected());
    throw SpacetimeDbConnectionException(
      'Token provider failed: $reason',
      lastKnownState: const Disconnected(),
    );
  }

  Future<String?> _getWebSocketToken() async {
    if (_currentToken == null) return null;

    try {
      final httpProtocol = ssl ? 'https' : 'http';
      final url = Uri.parse(
        '$httpProtocol://$host/v1/identity/websocket-token',
      );

      final response = await http.post(
        url,
        headers: {'Authorization': 'Bearer $_currentToken'},
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data is! Map) return null;
        final String token = data['token'] ?? '';
        return token.isEmpty ? null : token;
      } else {
        SdkLogger.e('Failed to get WebSocket token: ${response.statusCode}');
        return null;
      }
    } catch (e) {
      SdkLogger.e('Error getting WebSocket token: $e');
      return null;
    }
  }

  void _updateState(ConnectionState newState) {
    final previous = _state;
    if (previous.runtimeType != newState.runtimeType) {
      _state = newState;
      _stateController.add(_state);
      SdkLogger.i('Connection state: ${newState.displayName}');

      if (newState is Connected) {
        _lastSuccessfulConnection = DateTime.now();
      }

      _updateQuality();
    } else if (newState is Reconnecting &&
        previous is Reconnecting &&
        newState.attempt != previous.attempt) {
      _state = newState;
      _stateController.add(_state);
      _updateQuality();
    }
  }

  void _updateQuality() {
    final quality = ConnectionQuality(
      status: _state,
      reconnectAttempts: _reconnectAttempts,
      timeSinceLastConnection: _lastSuccessfulConnection != null
          ? DateTime.now().difference(_lastSuccessfulConnection!)
          : null,
      lastError: _lastError,
      lastPingSent: _lastPingSent,
      lastPongReceived: _lastMessageReceived,
    );

    if (_state.runtimeType != _lastLoggedState?.runtimeType) {
      SdkLogger.i(
        'Connection: ${quality.status.displayName} (health=${quality.healthScore.toStringAsFixed(1)})',
      );
      _lastLoggedState = _state;
    }
    _qualityController.add(quality);
  }

  void _setupMessageListener() {
    _channel!.stream.listen(
      (dynamic data) {
        if (!_socketReceivedFrame) {
          _socketReceivedFrame = true;
          _releaseHeldOutbound();
        }
        _keepAlive?.notifyMessageReceived();
        _lastMessageReceived = DateTime.now();

        if (data is Uint8List) {
          SdkLogger.d(
            'WS_RX: ${data.length} bytes, head=${data.take(64).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}',
          );
          _messageController.add(data);
        } else if (data is List<int>) {
          final bytes = Uint8List.fromList(data);
          SdkLogger.d(
            'WS_RX: ${bytes.length} bytes, head=${bytes.take(8).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}',
          );
          _messageController.add(bytes);
        }
      },
      onError: (error) {
        final errorMsg = 'WebSocket error: $error';
        SdkLogger.e(errorMsg);
        _lastError = errorMsg;
        _errorController.add(errorMsg);
        _updateState(const Disconnected());
      },
      onDone: () {
        noteSocketClosed(
          this,
          closeCode: _channel?.closeCode,
          closeReason: _channel?.closeReason,
        );
        SdkLogger.i('WebSocket closed');
        _keepAlive?.stop();
        _dropHeldOutbound();

        if (_isSessionBusyRefusal) {
          _retrySessionBusy();
          return;
        }

        if (_state is Connecting) {
          _updateState(const Disconnected());
        } else if (_state is Connected) {
          _updateState(
            Reconnecting(
              attempt: _reconnectAttempts,
              nextDelay: _getReconnectDelay(_reconnectAttempts),
            ),
          );
        }

        _channel = null;
        _attemptReconnect();
      },
    );
  }

  Duration _getReconnectDelay(int attempt) {
    final random = _reconnectRandoms[this] ?? _reconnectRandom.nextDouble;
    return reconnectDelay(
      attempt,
      random(),
      base: config.baseReconnectDelay,
      max: config.maxReconnectDelay,
    );
  }

  Future<void> _attemptReconnect() async {
    if (!config.autoReconnect || !_shouldReconnect) return;

    if (_reconnectAttempts >= config.maxReconnectAttempts) {
      SdkLogger.e('Max reconnection attempts reached. Giving up.');
      _updateState(
        const FatalError(message: 'Max reconnection attempts reached'),
      );
      _shouldReconnect = false;
      return;
    }

    _reconnectAttempts++;
    _updateQuality();
    final delay = _getReconnectDelay(_reconnectAttempts);
    SdkLogger.i(
      'Reconnecting in ${delay.inSeconds}s (attempt $_reconnectAttempts/${config.maxReconnectAttempts})',
    );

    _updateState(Reconnecting(attempt: _reconnectAttempts, nextDelay: delay));
    _scheduleReconnectTimer(delay);
  }

  bool get _isSessionBusyRefusal =>
      config.autoReconnect &&
      _shouldReconnect &&
      _state is Connected &&
      !_socketReceivedFrame &&
      _channel?.closeCode == _sessionBusyCloseCode;

  void _retrySessionBusy() {
    _reconnectAttempts = _attemptsAtDial;
    _channel = null;
    final backoff = _getReconnectDelay(math.max(_reconnectAttempts, 1));
    final delay = backoff < _sessionBusyMinDelay
        ? _sessionBusyMinDelay
        : backoff;
    SdkLogger.w(
      'Session busy (close code $_sessionBusyCloseCode); retrying in '
      '${delay.inMilliseconds}ms without counting an attempt',
    );
    _updateState(Reconnecting(attempt: _reconnectAttempts, nextDelay: delay));
    _scheduleReconnectTimer(delay);
  }

  void _scheduleReconnectTimer(Duration delay) {
    _reconnectTimer = Timer(delay, () async {
      _updateState(const Disconnected());
      try {
        await connect();
      } on SpacetimeDbAuthException {
        SdkLogger.e(
          'Authentication failed during reconnect - token may be invalid',
        );
        _shouldReconnect = false;
        _updateState(const AuthError(message: 'Token invalid or expired'));
      } catch (e) {
        await _attemptReconnect();
      }
    });
  }

  void _setupKeepAlive() {
    _keepAlive?.stop();
    _keepAlive = KeepAliveMonitor(
      onSendPing: () {
        try {
          const pingQuery = 'SELECT * FROM __spacetime_dart_sdk_keepalive__';

          final message = OneOffQueryMessage(queryString: pingQuery);
          if (isConnected) _write(message.encode());
          _lastPingSent = DateTime.now();
          final sinceLastRx = _lastMessageReceived != null
              ? DateTime.now().difference(_lastMessageReceived!).inMilliseconds
              : null;
          SdkLogger.i(
            'KEEPALIVE_PING sent (last inbound ${sinceLastRx}ms ago)',
          );
        } catch (e) {
          SdkLogger.e('Failed to send keep-alive ping: $e');
        }
      },
      onDisconnect: () {
        final sinceLastRx = _lastMessageReceived != null
            ? DateTime.now().difference(_lastMessageReceived!).inMilliseconds
            : null;
        _closeForReconnect(
          'keep-alive timeout, connection declared dead '
          '(last inbound ${sinceLastRx}ms ago)',
        );
      },
      idleThreshold: config.pingInterval,
      pongTimeout: config.pongTimeout,
    );
  }

  void _stopForIdentityChange(String reason) {
    SdkLogger.e('Stopping reconnect: $reason');
    _shouldReconnect = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _keepAlive?.stop();
    _updateState(FatalError(message: reason));
    _channel?.sink.close();
  }

  void _closeForReconnect(String reason) {
    SdkLogger.w('Closing socket for reconnect: $reason');
    _keepAlive?.stop();
    _channel?.sink.close();
  }

  void _write(Uint8List data) {
    if (!_shouldBatch || !_socketReceivedFrame) {
      _channel!.sink.add(data);
      return;
    }
    _outboundQueue.add(Uint8List.fromList(data));
    _scheduleOutboundFlush();
  }

  bool get _shouldBatch =>
      _negotiatedProtocol == NegotiatedWsProtocol.v3 &&
      config.outboundBatching == OutboundBatchingPolicy.opportunistic;

  void _releaseHeldOutbound() {
    if (_outboundQueue.isEmpty) return;
    if (_shouldBatch) {
      _scheduleOutboundFlush();
      return;
    }
    final held = List.of(_outboundQueue);
    _outboundQueue.clear();
    held.forEach(_channel!.sink.add);
  }

  void _dropHeldOutbound() {
    if (_outboundQueue.isEmpty) return;
    SdkLogger.w(
      'Dropping ${_outboundQueue.length} outbound message(s) queued for a '
      'socket that closed',
    );
    _outboundQueue.clear();
  }

  void _scheduleOutboundFlush() {
    if (_isOutboundFlushScheduled) return;
    _isOutboundFlushScheduled = true;
    scheduleMicrotask(_flushOutboundQueue);
  }

  void _flushOutboundQueue() {
    _isOutboundFlushScheduled = false;
    if (_outboundQueue.isEmpty) return;
    if (!isConnected || _channel == null) {
      SdkLogger.w(
        'Dropping ${_outboundQueue.length} queued outbound message(s): '
        'not connected',
      );
      _outboundQueue.clear();
      return;
    }
    final count = countClientMessagesForV3Frame(
      _outboundQueue,
      config.maxV3OutboundFrameBytes,
    );
    final frame = encodeClientMessagesV3(_outboundQueue, count);
    _channel!.sink.add(frame);
    _outboundQueue.removeRange(0, count);
    if (_outboundQueue.isNotEmpty) {
      Timer(Duration.zero, _flushOutboundQueue);
    }
  }
}
