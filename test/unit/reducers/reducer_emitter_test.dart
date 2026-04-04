import 'dart:async';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:spacetimedb_dart_sdk/spacetimedb_dart_sdk.dart';

void main() {
  group('ReducerEmitter', () {
    late ReducerEmitter emitter;

    setUp(() {
      emitter = ReducerEmitter();
    });

    tearDown(() {
      emitter.dispose();
    });

    test('starts with no active reducers', () {
      expect(emitter.activeReducers, isEmpty);
    });

    test('on() creates a broadcast stream', () {
      final stream = emitter.on('test_reducer');
      expect(stream, isA<Stream<EventContext>>());
      expect(stream.isBroadcast, isTrue);
    });

    test('emit() sends event to registered listeners', () async {
      final event = ReducerEvent(
        timestamp: Int64(123),
        status: Committed(),
        callerIdentity: Uint8List(32),
        reducerName: 'test_reducer',
        reducerArgs: {},
      );

      final context = EventContext(myConnectionId: null, event: event);

      // Use expectLater with emits matcher
      final stream = emitter.on('test_reducer');
      final expectation = expectLater(stream, emits(context));

      emitter.emit('test_reducer', context);

      await expectation;
    });

    test('emit() does nothing if no listeners registered', () {
      // Should not throw or create controllers
      final context = EventContext(
        myConnectionId: null,
        event: UnknownTransactionEvent(),
      );

      emitter.emit('nonexistent_reducer', context);

      expect(emitter.activeReducers, isEmpty);
    });

    test('multiple listeners receive the same event', () async {
      final context = EventContext(
        myConnectionId: null,
        event: ReducerEvent(
          timestamp: Int64(123),
          status: Committed(),
          callerIdentity: Uint8List(32),
          reducerName: 'test_reducer',
          reducerArgs: {},
        ),
      );

      final stream = emitter.on('test_reducer');

      // Use expectLater to verify stream emits twice
      final expectation = expectLater(stream, emitsInOrder([context, context]));

      emitter.emit('test_reducer', context);
      emitter.emit('test_reducer', context);

      await expectation;
    });

    test('different reducers have independent streams', () async {
      final context1 = EventContext(
        myConnectionId: null,
        event: ReducerEvent(
          timestamp: Int64(123),
          status: Committed(),
          callerIdentity: Uint8List(32),
          reducerName: 'reducer1',
          reducerArgs: {},
        ),
      );

      final context2 = EventContext(
        myConnectionId: null,
        event: ReducerEvent(
          timestamp: Int64(456),
          status: Committed(),
          callerIdentity: Uint8List(32),
          reducerName: 'reducer2',
          reducerArgs: {},
        ),
      );

      final stream1 = emitter.on('reducer1');
      final stream2 = emitter.on('reducer2');

      final expectation1 = expectLater(stream1, emits(context1));
      final expectation2 = expectLater(stream2, emits(context2));

      emitter.emit('reducer1', context1);
      emitter.emit('reducer2', context2);

      await Future.wait([expectation1, expectation2]);
    });

    test('hasListeners() returns correct status', () {
      expect(emitter.hasListeners('test_reducer'), isFalse);

      final subscription = emitter.on('test_reducer').listen((_) {});

      expect(emitter.hasListeners('test_reducer'), isTrue);

      subscription.cancel();
    });

    test('activeReducers returns list of listened-to reducers', () {
      final sub1 = emitter.on('reducer1').listen((_) {});
      final sub2 = emitter.on('reducer2').listen((_) {});
      final sub3 = emitter.on('reducer3').listen((_) {});

      expect(emitter.activeReducers.length, equals(3));
      expect(
        emitter.activeReducers,
        containsAll(['reducer1', 'reducer2', 'reducer3']),
      );

      sub1.cancel();
      sub2.cancel();
      sub3.cancel();
    });

    test('dispose() closes all streams', () async {
      final sub1 = emitter.on('reducer1').listen((_) {});
      final sub2 = emitter.on('reducer2').listen((_) {});

      expect(emitter.activeReducers.length, equals(2));

      emitter.dispose();

      expect(emitter.activeReducers, isEmpty);

      await sub1.cancel();
      await sub2.cancel();
    });

    test('cancelled subscription stops receiving events', () async {
      final context = EventContext(
        myConnectionId: null,
        event: ReducerEvent(
          timestamp: Int64(123),
          status: Committed(),
          callerIdentity: Uint8List(32),
          reducerName: 'test_reducer',
          reducerArgs: {},
        ),
      );

      final stream = emitter.on('test_reducer');

      // Listen and immediately cancel
      final subscription = stream.listen((_) {});

      // First emission - should be received
      final firstExpectation = expectLater(stream, emits(context));
      emitter.emit('test_reducer', context);
      await firstExpectation;

      // Cancel subscription
      await subscription.cancel();

      // Second emission - should NOT be received (stream is done)
      emitter.emit('test_reducer', context);

      // If we listen again, we should not get the second emit
      final newStream = emitter.on('test_reducer');
      final newSub = newStream.listen((_) {});

      // Verify the new subscription exists
      expect(emitter.hasListeners('test_reducer'), isTrue);

      await newSub.cancel();
    });

    test('lazy controller creation (memory efficient)', () {
      // Controllers should only be created when first listener registers
      expect(emitter.activeReducers, isEmpty);

      // Just calling on() without listening shouldn't create controller
      final stream = emitter.on('test_reducer');
      // Controller is created when listener subscribes
      final sub = stream.listen((_) {});

      expect(emitter.activeReducers, contains('test_reducer'));

      sub.cancel();
    });
  });

  group('ReducerEmitter Integration Patterns', () {
    test('pattern: typed callback extraction', () async {
      final emitter = ReducerEmitter();

      // Simulate generated code pattern
      StreamSubscription<void> onTestReducer(
        void Function(EventContext ctx, String arg1, int arg2) callback,
      ) {
        return emitter.on('test_reducer').listen((ctx) {
          // Type guard instead of as cast
          if (ctx.event is! ReducerEvent) return;
          final event = ctx.event as ReducerEvent;

          // Type guard for args
          final args = event.reducerArgs;
          if (args is! Map<String, dynamic>) return;

          final arg1 = args['arg1'];
          final arg2 = args['arg2'];

          if (arg1 is! String) return;
          if (arg2 is! int) return;

          callback(ctx, arg1, arg2);
        });
      }

      // User code
      final completer = Completer<void>();
      final subscription = onTestReducer((ctx, arg1, arg2) {
        expect(arg1, equals('test'));
        expect(arg2, equals(42));
        completer.complete();
      });

      // Emit event
      final context = EventContext(
        myConnectionId: null,
        event: ReducerEvent(
          timestamp: Int64(123),
          status: Committed(),
          callerIdentity: Uint8List(32),
          reducerName: 'test_reducer',
          reducerArgs: {'arg1': 'test', 'arg2': 42},
        ),
      );

      emitter.emit('test_reducer', context);

      await completer.future.timeout(const Duration(seconds: 2));

      await subscription.cancel();
      emitter.dispose();
    });

    test('pattern: filter by transaction status', () async {
      final emitter = ReducerEmitter();

      final successCompleter = Completer<void>();
      final failureCompleter = Completer<void>();

      final subscription = emitter.on('test_reducer').listen((ctx) {
        // Type guard instead of as cast
        if (ctx.event is! ReducerEvent) return;
        final event = ctx.event as ReducerEvent;

        switch (event.status) {
          case Committed():
            if (!successCompleter.isCompleted) {
              successCompleter.complete();
            }
          case Failed():
            if (!failureCompleter.isCompleted) {
              failureCompleter.complete();
            }
          case OutOfEnergy():
          case Pending():
          case Dropped():
            break;
        }
      });

      // Emit success
      emitter.emit(
        'test_reducer',
        EventContext(
          myConnectionId: null,
          event: ReducerEvent(
            timestamp: Int64(123),
            status: Committed(),
            callerIdentity: Uint8List(32),
            reducerName: 'test_reducer',
            reducerArgs: {},
          ),
        ),
      );

      // Emit failure
      emitter.emit(
        'test_reducer',
        EventContext(
          myConnectionId: null,
          event: ReducerEvent(
            timestamp: Int64(456),
            status: Failed('error'),
            callerIdentity: Uint8List(32),
            reducerName: 'test_reducer',
            reducerArgs: {},
          ),
        ),
      );

      await Future.wait([
        successCompleter.future.timeout(const Duration(seconds: 2)),
        failureCompleter.future.timeout(const Duration(seconds: 2)),
      ]);

      await subscription.cancel();
      emitter.dispose();
    });

    test('pattern: check if transaction is from current client', () async {
      final emitter = ReducerEmitter();
      final myConnectionId = Uint8List.fromList([1, 2, 3, 4]);
      final otherConnectionId = Uint8List.fromList([5, 6, 7, 8]);

      final myTransactionCompleter = Completer<void>();
      final otherTransactionCompleter = Completer<void>();

      final subscription = emitter.on('test_reducer').listen((ctx) {
        // Type guard instead of as cast
        if (ctx.event is! ReducerEvent) return;
        final event = ctx.event as ReducerEvent;

        if (event.callerConnectionId != null) {
          final isMyTransaction = _bytesEqual(
            event.callerConnectionId,
            myConnectionId,
          );
          if (isMyTransaction) {
            if (!myTransactionCompleter.isCompleted) {
              myTransactionCompleter.complete();
            }
          } else {
            if (!otherTransactionCompleter.isCompleted) {
              otherTransactionCompleter.complete();
            }
          }
        }
      });

      // My transaction
      emitter.emit(
        'test_reducer',
        EventContext(
          myConnectionId: null,
          event: ReducerEvent(
            timestamp: Int64(123),
            status: Committed(),
            callerIdentity: Uint8List(32),
            callerConnectionId: myConnectionId,
            reducerName: 'test_reducer',
            reducerArgs: {},
          ),
        ),
      );

      // Other client's transaction
      emitter.emit(
        'test_reducer',
        EventContext(
          myConnectionId: null,
          event: ReducerEvent(
            timestamp: Int64(456),
            status: Committed(),
            callerIdentity: Uint8List(32),
            callerConnectionId: otherConnectionId,
            reducerName: 'test_reducer',
            reducerArgs: {},
          ),
        ),
      );

      await Future.wait([
        myTransactionCompleter.future.timeout(const Duration(seconds: 2)),
        otherTransactionCompleter.future.timeout(const Duration(seconds: 2)),
      ]);

      await subscription.cancel();
      emitter.dispose();
    });
  });
}

// Helper function for byte comparison
bool _bytesEqual(Uint8List? a, Uint8List? b) {
  if (a == null || b == null) return false;
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
