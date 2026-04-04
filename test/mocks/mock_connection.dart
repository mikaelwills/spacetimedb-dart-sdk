import 'dart:async';
import 'dart:typed_data';

import 'package:spacetimedb_dart_sdk/spacetimedb_dart_sdk.dart';

/// Mock WebSocket connection for deterministic testing
///
/// Allows precise control over:
/// - What messages the SDK sends (captured in sentMessages)
/// - What messages the SDK receives (injected via simulateIncoming)
/// - Timing (no network variability)
class MockConnection implements SpacetimeDbConnection {
  // Capture outgoing messages
  final List<Uint8List> sentMessages = [];

  // Control incoming messages
  final StreamController<Uint8List> _incomingController =
      StreamController<Uint8List>.broadcast();

  // Track connection state
  ConnectionState _state = ConnectionState.disconnected;
  final StreamController<ConnectionState> _stateController =
      StreamController<ConnectionState>.broadcast();

  // Track status
  ConnectionStatus _status = ConnectionStatus.disconnected;
  final StreamController<ConnectionStatus> _statusController =
      StreamController<ConnectionStatus>.broadcast();

  set mockStatus(ConnectionStatus newStatus) {
    _status = newStatus;
    _statusController.add(newStatus);
  }

  void setStatusSilently(ConnectionStatus newStatus) {
    _status = newStatus;
  }

  // Track quality
  final StreamController<ConnectionQuality> _qualityController =
      StreamController<ConnectionQuality>.broadcast();

  // Track errors
  final StreamController<String> _errorController =
      StreamController<String>.broadcast();

  MockConnection();

  @override
  Stream<Uint8List> get onMessage => _incomingController.stream;

  @override
  Stream<ConnectionState> get onStateChanged => _stateController.stream;

  @override
  ConnectionState get state => _state;

  @override
  bool get isConnected => _state == ConnectionState.connected;

  @override
  ConnectionStatus get status => _status;

  @override
  Stream<ConnectionStatus> get connectionStatus => _statusController.stream;

  @override
  Stream<ConnectionQuality> get connectionQuality => _qualityController.stream;

  @override
  Stream<String> get onError => _errorController.stream;

  @override
  void send(Uint8List data) {
    sentMessages.add(data);
  }

  @override
  Future<void> connect() async {
    _state = ConnectionState.connected;
    _stateController.add(_state);
  }

  @override
  Future<void> disconnect() async {
    _state = ConnectionState.disconnected;
    _status = ConnectionStatus.disconnected;
    _stateController.add(_state);
    _statusController.add(_status);
  }

  @override
  Future<void> dispose() async {
    await _incomingController.close();
    await _stateController.close();
    await _statusController.close();
    await _qualityController.close();
    await _errorController.close();
  }

  @override
  Future<void> reconnect() async {
    await connect();
  }

  @override
  Future<void> retryConnection() async {
    await connect();
  }

  @override
  void enableAutoReconnect(bool enabled) {
    // Stub - no-op for mock
  }

  @override
  void updateToken(String token) {
    // Stub - no-op for mock
  }

  /// Simulate server sending a message to the client
  void simulateIncoming(Uint8List data) {
    _incomingController.add(data);
  }

  /// Helper to extract requestId from last sent CallReducerMessage
  int getLastSentRequestId() {
    if (sentMessages.isEmpty) {
      throw StateError('No messages sent yet');
    }
    return _extractRequestId(sentMessages.last);
  }

  /// Helper to extract requestId from sent message by index
  int getSentRequestId(int index) {
    if (index >= sentMessages.length) {
      throw StateError(
        'Index $index out of bounds (${sentMessages.length} messages sent)',
      );
    }
    return _extractRequestId(sentMessages[index]);
  }

  /// Extract requestId from CallReducerMessage binary data
  /// CallReducerMessage format: [tag: u8][reducer_name: String][args: Bytes][request_id: u32][flags: u8]
  int _extractRequestId(Uint8List data) {
    final decoder = BsatnDecoder(data);

    // Skip tag (u8)
    decoder.readU8();

    // Skip reducer name (String = u32 length + bytes)
    decoder.readString();

    // Skip args (Bytes = u32 length + bytes)
    final argsLen = decoder.readU32();
    decoder.readBytes(argsLen);

    // Read request_id (u32)
    return decoder.readU32();
  }

  /// Clear sent messages (for test isolation)
  void clearSent() {
    sentMessages.clear();
  }

  // Stub implementations for required interface members
  @override
  String get host => 'mock://localhost';

  @override
  String get database => 'mock_db';

  @override
  String? get initialToken => null;

  @override
  String? get token => null;

  @override
  bool get ssl => false;

  @override
  ConnectionConfig get config => const ConnectionConfig();

  Identity? get identity =>
      null; // Null for tests unless testing identity filtering

  String? get address =>
      null; // Null for tests unless testing address filtering

  @override
  Future<void> callReducer(
    String reducerName,
    Uint8List args, {
    int? requestId,
  }) async {
    // Stub - not used in our tests (we test ReducerCaller directly)
    throw UnimplementedError('Use ReducerCaller directly in tests');
  }
}
