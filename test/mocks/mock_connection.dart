import 'dart:async';
import 'dart:typed_data';

import 'package:spacetimedb_dart_sdk/spacetimedb_dart_sdk.dart';

class MockConnection implements SpacetimeDbConnection {
  final List<Uint8List> sentMessages = [];

  final StreamController<Uint8List> _incomingController =
      StreamController<Uint8List>.broadcast();

  ConnectionState _state = const Disconnected();
  final StreamController<ConnectionState> _stateController =
      StreamController<ConnectionState>.broadcast();

  final StreamController<ConnectionQuality> _qualityController =
      StreamController<ConnectionQuality>.broadcast();

  final StreamController<String> _errorController =
      StreamController<String>.broadcast();

  set mockState(ConnectionState newState) {
    _state = newState;
    _stateController.add(newState);
  }

  void setStateSilently(ConnectionState newState) {
    _state = newState;
  }

  MockConnection();

  @override
  Stream<Uint8List> get onMessage => _incomingController.stream;

  @override
  Stream<ConnectionState> get onStateChanged => _stateController.stream;

  @override
  ConnectionState get state => _state;

  @override
  bool get isConnected => _state is Connected;

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
    _state = const Connected();
    _stateController.add(_state);
  }

  @override
  Future<void> disconnect() async {
    _state = const Disconnected();
    _stateController.add(_state);
  }

  @override
  Future<void> dispose() async {
    await _incomingController.close();
    await _stateController.close();
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
  void enableAutoReconnect(bool enabled) {}

  @override
  void updateToken(String token) {}

  void simulateIncoming(Uint8List data) {
    _incomingController.add(data);
  }

  int getLastSentRequestId() {
    if (sentMessages.isEmpty) {
      throw StateError('No messages sent yet');
    }
    return _extractRequestId(sentMessages.last);
  }

  int getSentRequestId(int index) {
    if (index >= sentMessages.length) {
      throw StateError(
        'Index $index out of bounds (${sentMessages.length} messages sent)',
      );
    }
    return _extractRequestId(sentMessages[index]);
  }

  int _extractRequestId(Uint8List data) {
    final decoder = BsatnDecoder(data);
    decoder.readU8();
    decoder.readString();
    final argsLen = decoder.readU32();
    decoder.readBytes(argsLen);
    return decoder.readU32();
  }

  void clearSent() {
    sentMessages.clear();
  }

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

  Identity? get identity => null;

  String? get address => null;

  @override
  Future<void> callReducer(
    String reducerName,
    Uint8List args, {
    int? requestId,
  }) async {
    throw UnimplementedError('Use ReducerCaller directly in tests');
  }
}
