import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:math' show Random;
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:spacetimedb_dart_sdk/src/connection/connection_state.dart';
import 'package:spacetimedb_dart_sdk/src/connection/connection_status.dart';
import 'package:spacetimedb_dart_sdk/src/connection/connection_quality.dart';
import 'package:spacetimedb_dart_sdk/src/connection/connection_config.dart';
import 'package:spacetimedb_dart_sdk/src/connection/keep_alive_monitor.dart';
import 'package:spacetimedb_dart_sdk/src/messages/client_messages.dart';
import 'package:spacetimedb_dart_sdk/src/utils/sdk_logger.dart';
import 'platform.dart' show kIsWeb;
import 'package:web_socket_channel/web_socket_channel.dart';

import 'websocket.dart' as ws;

/// Factory function for creating WebSocket channels
/// Allows dependency injection for testing
typedef WebSocketFactory =
    WebSocketChannel Function(
      Uri uri,
      Iterable<String>? protocols,
      Map<String, dynamic>? headers, {
      Duration connectTimeout,
    });

/// WebSocket connection to a SpacetimeDB database
///
/// Manages the lifecycle of a WebSocket connection including:
/// - Initial connection and authentication
/// - Automatic reconnection with exponential backoff
/// - Binary message sending/receiving
/// - Connection state tracking
///
/// Example:
/// ```dart
/// final connection = SpacetimeDbConnection(
///   host: 'localhost:3000',
///   database: 'mydb',
///   initialToken: 'optional-token',
/// );
///
/// // Listen to connection state changes
/// connection.onStateChanged.listen((state) {
///   print('Connection state: $state');
/// });
///
/// // Connect
/// await connection.connect();
///
/// // Send binary data
/// connection.send(myBsatnData);
///
/// // Disconnect
/// await connection.disconnect();
/// ```
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

  // Current authentication token
  String? _currentToken;

  // Keep-alive monitoring
  KeepAliveMonitor? _keepAlive;
  DateTime? _lastMessageReceived;
  DateTime? _lastPingSent;

  WebSocketChannel? _channel;
  ConnectionState _state = ConnectionState.disconnected;

  // Public connection status (for UI binding)
  ConnectionStatus _currentStatus = ConnectionStatus.disconnected;
  final StreamController<ConnectionStatus> _statusController =
      StreamController<ConnectionStatus>.broadcast();

  // Connection quality tracking
  final StreamController<ConnectionQuality> _qualityController =
      StreamController<ConnectionQuality>.broadcast();
  String? _lastError;
  DateTime? _lastSuccessfulConnection;
  ConnectionStatus? _lastLoggedStatus;

  final StreamController<ConnectionState> _stateController =
      StreamController<ConnectionState>.broadcast();
  final StreamController<Uint8List> _messageController =
      StreamController<Uint8List>.broadcast();
  final StreamController<String> _errorController =
      StreamController<String>.broadcast();

  /// Stream of connection status changes for UI binding
  Stream<ConnectionStatus> get connectionStatus => _statusController.stream;

  /// Stream of connection quality metrics
  Stream<ConnectionQuality> get connectionQuality => _qualityController.stream;

  /// Current connection status
  ConnectionStatus get status => _currentStatus;

  Stream<ConnectionState> get onStateChanged => _stateController.stream;

  Stream<Uint8List> get onMessage => _messageController.stream;

  Stream<String> get onError => _errorController.stream;

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
    // Emit initial quality after allowing time for subscribers to attach
    // Use scheduleMicrotask to emit after constructor completes
    scheduleMicrotask(() => _updateQuality());
  }

  ConnectionState get state => _state;

  bool get isConnected => _state == ConnectionState.connected;

  /// The current authentication token, if any
  String? get token => _currentToken;

  /// Updates the current authentication token
  ///
  /// This is typically called automatically when an IdentityToken message
  /// is received from the server.
  void updateToken(String token) {
    _currentToken = token;
    SdkLogger.i('Authentication token updated');
  }

  /// Exchange auth token for a short-lived WebSocket token (for web platform)
  ///
  /// On web, we can't send custom headers with WebSocket connections,
  /// so we need to get a temporary token and pass it as a query parameter.
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
        return data['token'] as String?;
      } else {
        SdkLogger.e('Failed to get WebSocket token: ${response.statusCode}');
        return null;
      }
    } catch (e) {
      SdkLogger.e('Error getting WebSocket token: $e');
      return null;
    }
  }

  Future<void> connect() async {
    if (_state != ConnectionState.disconnected) {
      SdkLogger.i('Already connected or connecting');
      return;
    }
    _shouldReconnect = true;
    _updateState(ConnectionState.connecting);
    _updateStatus(ConnectionStatus.connecting);

    try {
      final protocol = ssl ? 'wss' : 'ws';
      var uri = Uri.parse('$protocol://$host/v1/database/$database/subscribe');

      final headers = <String, dynamic>{};

      // On web, we need to use query parameter for auth since WebSocket API
      // doesn't support custom headers. Get a temporary token first.
      if (kIsWeb && _currentToken != null) {
        final wsToken = await _getWebSocketToken();
        if (wsToken != null) {
          uri = uri.replace(queryParameters: {'token': wsToken});
        }
      } else if (_currentToken != null) {
        // On native platforms, use Authorization header
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
      _updateState(ConnectionState.connected);
      _updateStatus(ConnectionStatus.connected);
      _reconnectAttempts = 0; // Reset on successful connection
      _updateQuality(); // Emit quality update after reconnect counter reset
    } catch (e) {
      SdkLogger.e('Connection failed: $e');

      // FIX: Update BOTH State and Status to prevent desynchronization
      _updateState(ConnectionState.disconnected);
      _updateStatus(ConnectionStatus.disconnected);

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

  /// Closes the WebSocket connection and stops reconnection attempts
  ///
  /// Example:
  /// ```dart
  /// await connection.disconnect();
  /// print('Disconnected');
  /// ```
  Future<void> disconnect() async {
    if (_state == ConnectionState.disconnected) {
      return;
    }
    _shouldReconnect = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _keepAlive?.stop(); // Stop keep-alive monitoring
    _updateState(ConnectionState.disconnected);
    await _channel?.sink.close();
    _channel = null;
  }

  void _updateState(ConnectionState newState) {
    if (_state != newState) {
      _state = newState;
      _stateController.add(_state);
    }
  }

  void _updateStatus(ConnectionStatus newStatus) {
    if (_currentStatus != newStatus) {
      _currentStatus = newStatus;
      _statusController.add(newStatus);
      SdkLogger.i('Connection status: $newStatus');

      if (newStatus == ConnectionStatus.connected) {
        _lastSuccessfulConnection = DateTime.now();
      }

      _updateQuality();
    }
  }

  void _updateQuality() {
    final quality = ConnectionQuality(
      status: _currentStatus,
      reconnectAttempts: _reconnectAttempts,
      timeSinceLastConnection:
          _lastSuccessfulConnection != null
              ? DateTime.now().difference(_lastSuccessfulConnection!)
              : null,
      lastError: _lastError,
      lastPingSent: _lastPingSent,
      lastPongReceived: _lastMessageReceived,
    );

    if (_currentStatus != _lastLoggedStatus) {
      SdkLogger.i(
        'Connection: ${quality.status.name} (health=${quality.healthScore.toStringAsFixed(1)})',
      );
      _lastLoggedStatus = _currentStatus;
    }
    _qualityController.add(quality);
  }

  /// Sends binary data to the SpacetimeDB server
  ///
  /// The data must be BSATN-encoded. Use [BsatnEncoder] to create properly formatted messages.
  ///
  /// Example:
  /// ```dart
  /// final encoder = BsatnEncoder();
  /// encoder.writeString('Hello, SpacetimeDB!');
  /// connection.send(encoder.toBytes());
  /// ```
  void send(Uint8List data) {
    if (!isConnected) {
      SdkLogger.i('Cannot send: not connected');
      return;
    }
    // Debug: Log message type
    // if (data.isNotEmpty) {
    //   final msgType = data[0];
    //   SdkLogger.d('Sending message type $msgType, length ${data.length} bytes');
    // }
    _channel!.sink.add(data);
  }

  void _setupMessageListener() {
    _channel!.stream.listen(
      (dynamic data) {
        _keepAlive?.notifyMessageReceived();
        _lastMessageReceived = DateTime.now();
        _updateQuality();

        if (data is Uint8List) {
          // if (data.isNotEmpty) {
          //   SdkLogger.d('Received message type ${data[0]}, length ${data.length} bytes');
          // }
          _messageController.add(data);
        } else if (data is List<int>) {
          final bytes = Uint8List.fromList(data);
          // if (bytes.isNotEmpty) {
          //   SdkLogger.d('Received message type ${bytes[0]}, length ${bytes.length} bytes');
          // }
          _messageController.add(bytes);
        }
      },
      onError: (error) {
        final errorMsg = 'WebSocket error: $error';
        SdkLogger.e(errorMsg);
        _lastError = errorMsg;
        _errorController.add(errorMsg);
        _updateState(ConnectionState.disconnected);
        _updateQuality();
      },
      onDone: () {
        SdkLogger.i('WebSocket closed');
        _keepAlive?.stop();
        _updateState(ConnectionState.disconnected);

        // Determine if this is first disconnect or a reconnection scenario
        if (_currentStatus == ConnectionStatus.connecting) {
          // First connection failed
          _updateStatus(ConnectionStatus.disconnected);
        } else if (_currentStatus == ConnectionStatus.connected) {
          // Was connected, now lost connection
          _updateStatus(ConnectionStatus.reconnecting);
        }

        _channel = null;
        _attemptReconnect();
      },
    );
  }

  Duration _getReconnectDelay() {
    // Exponential backoff based on config
    final baseSeconds = config.baseReconnectDelay.inMilliseconds;
    final delayMs = baseSeconds * math.pow(2, _reconnectAttempts);
    final maxMs = config.maxReconnectDelay.inMilliseconds;
    return Duration(milliseconds: delayMs.toInt().clamp(baseSeconds, maxMs));
  }

  Future<void> _attemptReconnect() async {
    if (!config.autoReconnect || !_shouldReconnect) return;

    // Check for fatal error condition
    if (_reconnectAttempts >= config.maxReconnectAttempts) {
      SdkLogger.e('Max reconnection attempts reached. Giving up.');
      _updateStatus(ConnectionStatus.fatalError);
      _shouldReconnect = false;
      return;
    }

    _reconnectAttempts++;
    _updateQuality(); // Emit quality update after reconnect attempt increment
    final delay = _getReconnectDelay();
    SdkLogger.i(
      'Reconnecting in ${delay.inSeconds}s (attempt $_reconnectAttempts/${config.maxReconnectAttempts})',
    );

    _updateState(ConnectionState.reconnecting);
    _updateStatus(ConnectionStatus.reconnecting);
    _reconnectTimer = Timer(delay, () async {
      _updateState(ConnectionState.disconnected);
      try {
        await connect();
      } on SpacetimeDbAuthException {
        SdkLogger.e(
          'Authentication failed during reconnect - token may be invalid',
        );
        _shouldReconnect = false;
        _updateStatus(ConnectionStatus.authError);
      } catch (e) {
        await _attemptReconnect();
      }
    });
  }

  /// Enables or disables automatic reconnection on connection loss
  ///
  /// When enabled, the connection will automatically attempt to reconnect
  /// using exponential backoff (up to 5 attempts).
  ///
  /// Example:
  /// ```dart
  /// connection.enableAutoReconnect(true);
  /// await connection.connect();
  /// // Connection will auto-reconnect if dropped
  /// ```
  void enableAutoReconnect(bool enabled) {
    _shouldReconnect = enabled;
  }

  /// Manually triggers a reconnection
  ///
  /// Disconnects and immediately reconnects, resetting the reconnection attempt counter.
  ///
  /// Example:
  /// ```dart
  /// await connection.reconnect();
  /// ```
  Future<void> reconnect() async {
    await disconnect();
    _reconnectAttempts = 0;
    _updateQuality(); // Emit quality update after reconnect counter reset
    _shouldReconnect = true;
    await connect();
  }

  /// Manually retry connection after fatal error
  ///
  /// Resets the reconnection counter and attempts to connect again.
  /// Should only be called when status is [ConnectionStatus.fatalError] or
  /// [ConnectionStatus.disconnected].
  ///
  /// Example:
  /// ```dart
  /// if (connection.status == ConnectionStatus.fatalError) {
  ///   await connection.retryConnection();
  /// }
  /// ```
  Future<void> retryConnection() async {
    if (_currentStatus != ConnectionStatus.fatalError &&
        _currentStatus != ConnectionStatus.disconnected) {
      throw StateError('Cannot retry when status is $_currentStatus');
    }

    SdkLogger.i('Manual retry initiated');
    _reconnectAttempts = 0;
    _updateQuality(); // Emit quality update after reconnect counter reset
    _shouldReconnect = true;
    await connect();
  }

  /// Calls a reducer with BSATN-encoded arguments
  ///
  /// Sends a reducer call to the SpacetimeDB server. The reducer will execute
  /// server-side and may modify database state.
  ///
  /// Example:
  /// ```dart
  /// final encoder = BsatnEncoder();
  /// encoder.writeString('My Note');
  /// encoder.writeString('Note content');
  ///
  /// await connection.callReducer('create_note', encoder.toBytes());
  /// ```
  ///
  /// **Note:** This is a low-level method that sends the message but doesn't
  /// track the response. For full async/await support with TransactionResult,
  /// use `SubscriptionManager.reducers.call()` instead.
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

  // Keep-alive monitoring

  void _setupKeepAlive() {
    _keepAlive = KeepAliveMonitor(
      onSendPing: () {
        try {
          final messageId = Uint8List(16);
          for (var i = 0; i < 16; i++) {
            messageId[i] = _rng.nextInt(256);
          }
          const pingQuery = 'SELECT * FROM __spacetime_dart_sdk_keepalive__';

          // 3. Send the keep-alive query
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

  /// Disposes of resources used by this connection
  ///
  /// Closes all stream controllers and disconnects from the server.
  /// Should be called when the connection is no longer needed.
  ///
  /// Example:
  /// ```dart
  /// await connection.dispose();
  /// ```
  Future<void> dispose() async {
    _keepAlive?.stop();
    await disconnect();
    await _statusController.close();
    await _qualityController.close();
    await _stateController.close();
    await _messageController.close();
    await _errorController.close();
  }
}

class SpacetimeDbAuthException implements Exception {
  final String message;

  SpacetimeDbAuthException(this.message);

  @override
  String toString() => 'SpacetimeDbAuthException: $message';
}
