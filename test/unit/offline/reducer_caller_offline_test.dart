import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:spacetimedb_sdk/codegen.dart';

const _timeout = Duration(seconds: 5);

class MockOfflineConnection implements SpacetimeDbConnection {
  final List<Uint8List> sentMessages = [];
  ConnectionState _state = const Disconnected();

  final _stateController = StreamController<ConnectionState>.broadcast();
  final _incomingController = StreamController<Uint8List>.broadcast();
  final _qualityController = StreamController<ConnectionQuality>.broadcast();
  final _errorController = StreamController<String>.broadcast();

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
  void send(Uint8List data) => sentMessages.add(data);

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
  Future<void> reconnect() async => connect();
  @override
  Future<void> retryConnection() async => connect();
  @override
  void enableAutoReconnect(bool enabled) {}
  @override
  void updateToken(String token) {}
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
  @override
  Future<void> callReducer(
    String reducerName,
    Uint8List args, {
    int? requestId,
  }) async {
    throw UnimplementedError();
  }

  void setOnline() {
    _state = const Connected();
    _stateController.add(_state);
  }

  void setOffline() {
    _state = const Disconnected();
    _stateController.add(_state);
  }
}

class MockMutationHandler implements MutationHandler {
  bool syncTriggered = false;
  final List<String> queuedRequestIds = [];
  final List<String> optimisticRequestIds = [];
  final List<String> rolledBackRequestIds = [];

  @override
  void trySyncNow() => syncTriggered = true;

  @override
  void onMutationQueued(String requestId, List<OptimisticChange>? changes) {
    queuedRequestIds.add(requestId);
  }

  @override
  void onOptimisticChanges(String requestId, List<OptimisticChange>? changes) {
    optimisticRequestIds.add(requestId);
  }

  @override
  void onRollbackOptimistic(String requestId) {
    rolledBackRequestIds.add(requestId);
  }
}

void main() {
  group('ReducerCaller Offline Queue', () {
    late MockOfflineConnection connection;
    late InMemoryOfflineStorage storage;
    late MockMutationHandler handler;
    late ReducerCaller caller;

    setUp(() {
      connection = MockOfflineConnection();
      storage = InMemoryOfflineStorage();
      handler = MockMutationHandler();
      caller = ReducerCaller(
        connection,
        offlineStorage: storage,
        mutationHandler: handler,
      );
    });

    tearDown(() async {
      caller.dispose();
      await connection.dispose();
      await storage.dispose();
    });

    test(
      'queues first then triggers sync when online (offline-first)',
      () async {
        connection.setOnline();

        final result = await caller.call(
          'create_note',
          Uint8List.fromList([1, 2, 3]),
        );

        expect(result.isPending, isTrue);
        expect(handler.syncTriggered, isTrue);
        final pending = await storage.getPendingMutations().timeout(_timeout);
        expect(pending.length, equals(1));
      },
    );

    test('queues mutation when offline', () async {
      connection.setOffline();

      final result = await caller
          .call('create_note', Uint8List.fromList([1, 2, 3]))
          .timeout(_timeout);

      expect(result.isPending, isTrue);
      expect(result.pendingRequestId, isNotNull);
      expect(connection.sentMessages, isEmpty);

      final pending = await storage.getPendingMutations().timeout(_timeout);
      expect(pending.length, equals(1));
      expect(pending.first.reducerName, equals('create_note'));
    });

    test('stores optimistic changes with queued mutation', () async {
      connection.setOffline();

      await caller
          .call(
            'create_note',
            Uint8List.fromList([1, 2, 3]),
            optimisticChanges: [
              OptimisticChange.insert('notes', {'id': 1, 'title': 'Test'}),
            ],
          )
          .timeout(_timeout);

      final pending = await storage.getPendingMutations().timeout(_timeout);
      expect(pending.first.optimisticChanges, isNotNull);
      expect(pending.first.optimisticChanges!.length, equals(1));
    });

    test('without storage sends directly even when offline', () async {
      final noStorageCaller = ReducerCaller(connection);
      connection.setOffline();

      final future = noStorageCaller.call(
        'create_note',
        Uint8List.fromList([1, 2, 3]),
      );

      expect(connection.sentMessages.length, equals(1));

      noStorageCaller.dispose();
      future.ignore();
    });

    test('generates unique request IDs for queued mutations', () async {
      connection.setOffline();

      final r1 = await caller
          .call('r1', Uint8List.fromList([1]))
          .timeout(_timeout);
      final r2 = await caller
          .call('r2', Uint8List.fromList([2]))
          .timeout(_timeout);

      expect(r1.pendingRequestId, isNot(equals(r2.pendingRequestId)));
    });
  });
}
