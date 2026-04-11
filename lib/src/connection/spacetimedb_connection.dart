import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:math' show Random;
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:spacetimedb_dart_sdk/src/connection/connection_state.dart';
import 'package:spacetimedb_dart_sdk/src/connection/connection_quality.dart';
import 'package:spacetimedb_dart_sdk/src/connection/connection_config.dart';
import 'package:spacetimedb_dart_sdk/src/connection/keep_alive_monitor.dart';
import 'package:spacetimedb_dart_sdk/src/messages/client_messages.dart';
import 'package:spacetimedb_dart_sdk/src/utils/sdk_logger.dart';
import 'platform.dart' show kIsWeb;
import 'package:web_socket_channel/web_socket_channel.dart';

import 'websocket.dart' as ws;

typedef WebSocketFactory =
    WebSocketChannel Function(
      Uri uri,
      Iterable<String>? protocols,
      Map<String, dynamic>? headers, {
      Duration connectTimeout,
    });

class SpacetimeDbConnection {
  final String host;
  final String database;
  final String? initialToken;
  final bool ssl;
  final ConnectionConfig config;
  final WebSocketFactory _socketFactory;

  static final _rng = Random.secure();

  int _reconnectAttempts = 0;
  Timer? _reconnectTimer;
  bool _shouldReconnect = false;
  int _nextRequestId = 1;

  String? _currentToken;

  KeepAliveMonitor? _keepAlive;
  DateTime? _lastMessageReceived;
  DateTime? _lastPingSent;

  WebSocketChannel? _channel;

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

  SpacetimeDbConnection({
    required this.host,
    required this.database,
    this.initialToken,
    this.ssl = false,
    this.config = const ConnectionConfig(),
    WebSocketFactory? socketFactory,
  }) : _currentToken = initialToken,
       _socketFactory = socketFactory ?? ws.connectWebSocket {
    _shouldReconnect = config.autoReconnect;
    scheduleMicrotask(() => _updateQuality());
  }

  void updateToken(String token) {
    _currentToken = token;
    SdkLogger.i('Authentication token updated');
  }

  Future<void> connect() async {
    if (_state is! Disconnected) {
      SdkLogger.i('Already connected or connecting');
      return;
    }
    _shouldReconnect = true;
    _updateState(const Connecting());

    try {
      final protocol = ssl ? 'wss' : 'ws';
      var uri = Uri.parse('$protocol://$host/v1/database/$database/subscribe');

      final headers = <String, dynamic>{};

      if (kIsWeb && _currentToken != null) {
        final wsToken = await _getWebSocketToken();
        if (wsToken != null) {
          uri = uri.replace(queryParameters: {'token': wsToken});
        }
      } else if (_currentToken != null) {
        headers['Authorization'] = 'Bearer $_currentToken';
      }

      _channel = _socketFactory(
        uri,
        ['v1.bsatn.spacetimedb'],
        headers,
        connectTimeout: config.connectTimeout,
      );
      await _channel!.ready;
      _setupMessageListener();
      _setupKeepAlive();
      _updateState(const Connected());
      _reconnectAttempts = 0;
      _updateQuality();
    } catch (e) {
      SdkLogger.e('Connection failed: $e');
      _updateState(const Disconnected());
      _channel = null;

      final errorString = e.toString();
      if (errorString.contains('401') || errorString.contains('Unauthorized')) {
        throw SpacetimeDbAuthException(
          'Authentication failed (401). Token may be invalid or expired.',
        );
      }

      rethrow;
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
  }

  void send(Uint8List data) {
    if (!isConnected) {
      SdkLogger.i('Cannot send: not connected');
      return;
    }
    _channel!.sink.add(data);
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
      timeSinceLastConnection:
          _lastSuccessfulConnection != null
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
        _keepAlive?.notifyMessageReceived();
        _lastMessageReceived = DateTime.now();

        if (data is Uint8List) {
          _messageController.add(data);
        } else if (data is List<int>) {
          final bytes = Uint8List.fromList(data);
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
        SdkLogger.i('WebSocket closed');
        _keepAlive?.stop();

        if (_state is Connecting) {
          _updateState(const Disconnected());
        } else if (_state is Connected) {
          _updateState(
            Reconnecting(
              attempt: _reconnectAttempts,
              nextDelay: _getReconnectDelay(),
            ),
          );
        }

        _channel = null;
        _attemptReconnect();
      },
    );
  }

  Duration _getReconnectDelay() {
    final baseSeconds = config.baseReconnectDelay.inMilliseconds;
    final delayMs = baseSeconds * math.pow(2, _reconnectAttempts);
    final maxMs = config.maxReconnectDelay.inMilliseconds;
    return Duration(milliseconds: delayMs.toInt().clamp(baseSeconds, maxMs));
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
    final delay = _getReconnectDelay();
    SdkLogger.i(
      'Reconnecting in ${delay.inSeconds}s (attempt $_reconnectAttempts/${config.maxReconnectAttempts})',
    );

    _updateState(Reconnecting(attempt: _reconnectAttempts, nextDelay: delay));
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
    _keepAlive = KeepAliveMonitor(
      onSendPing: () {
        try {
          final messageId = Uint8List(16);
          for (var i = 0; i < 16; i++) {
            messageId[i] = _rng.nextInt(256);
          }
          const pingQuery = 'SELECT * FROM __spacetime_dart_sdk_keepalive__';

          final message = OneOffQueryMessage(
            messageId: messageId,
            queryString: pingQuery,
          );
          send(message.encode());
          _lastPingSent = DateTime.now();
        } catch (e) {
          SdkLogger.e('Failed to send keep-alive ping: $e');
        }
      },
      onDisconnect: () {
        SdkLogger.i('Keep-alive timeout - connection declared dead');
        _handleStaleConnection();
      },
      idleThreshold: config.pingInterval,
      pongTimeout: config.pongTimeout,
    );
  }

  void _handleStaleConnection() {
    _keepAlive?.stop();
    _channel?.sink.close();
  }
}

class SpacetimeDbAuthException implements Exception {
  final String message;

  SpacetimeDbAuthException(this.message);

  @override
  String toString() => 'SpacetimeDbAuthException: $message';
}
