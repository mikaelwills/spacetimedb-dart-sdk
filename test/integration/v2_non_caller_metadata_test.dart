import 'dart:async';

import 'package:test/test.dart';
import 'package:spacetimedb_sdk/codegen.dart';

import '../generated/note.dart';
import '../generated/reducer_args.dart';
import '../helpers/integration_test_helper.dart';
import '../helpers/test_env.dart';

void main() {
  setUpAll(ensureTestEnvironment);
  tearDownAll(cleanupTestEnvironment);

  group('v2 non-caller reducer metadata', () {
    late TestEnv callerEnv;
    late TestEnv observerEnv;
    late TableCache<Note> callerNotes;
    late TableCache<Note> observerNotes;

    setUp(() async {
      callerEnv = await createTestEnv();
      observerEnv = await createTestEnv();

      // Pre-arm listeners BEFORE connect() so we don't miss the
      // InitialConnection event on a broadcast stream.
      final callerReady = callerEnv.subManager.onInitialConnection.first;
      final observerReady = observerEnv.subManager.onInitialConnection.first;

      await callerEnv.connection.connect();
      await observerEnv.connection.connect();

      await callerReady.timeout(const Duration(seconds: 10));
      await observerReady.timeout(const Duration(seconds: 10));

      await callerEnv.subManager
          .subscribe(['SELECT * FROM note'])
          .timeout(const Duration(seconds: 10));
      await observerEnv.subManager
          .subscribe(['SELECT * FROM note'])
          .timeout(const Duration(seconds: 10));

      callerNotes = callerEnv.noteTable;
      observerNotes = observerEnv.noteTable;
    });

    tearDown(() async {
      callerEnv.subManager.dispose();
      observerEnv.subManager.dispose();
      await callerEnv.disconnect();
      await observerEnv.disconnect();
    });

    test('caller sees ReducerEvent + isMyTransaction=true; '
        'observer sees insert event but no reducer metadata', () async {
      final uniqueTitle =
          'non-caller-metadata-${DateTime.now().microsecondsSinceEpoch}';

      // Caller-side observations.
      final callerOnInsertCtx = Completer<EventContext>();
      final callerOnReducerArgs = Completer<({String title, String content})>();
      final callerOnReducerCtx = Completer<EventContext>();

      final callerInsertSub = callerNotes.onInsert.listen((event) {
        if (event.row.title == uniqueTitle && !callerOnInsertCtx.isCompleted) {
          callerOnInsertCtx.complete(event.context);
        }
      });

      final callerReducerSub = callerEnv.reducers.onCreateNote((
        ctx,
        title,
        content,
      ) {
        if (title == uniqueTitle && !callerOnReducerArgs.isCompleted) {
          callerOnReducerArgs.complete((title: title, content: content));
          callerOnReducerCtx.complete(ctx);
        }
      });

      // Observer-side observations.
      final observerOnInsertCtx = Completer<EventContext>();
      var observerOnReducerFired = false;

      final observerInsertSub = observerNotes.onInsert.listen((event) {
        if (event.row.title == uniqueTitle &&
            !observerOnInsertCtx.isCompleted) {
          observerOnInsertCtx.complete(event.context);
        }
      });

      final observerReducerSub = observerEnv.reducers.onCreateNote((
        ctx,
        title,
        content,
      ) {
        if (title == uniqueTitle) {
          observerOnReducerFired = true;
        }
      });

      // Caller fires the reducer.
      await callerEnv.reducers
          .createNote(title: uniqueTitle, content: 'body')
          .timeout(const Duration(seconds: 5));

      // Both clients must observe the row insert.
      final callerCtx = await callerOnInsertCtx.future.timeout(
        const Duration(seconds: 5),
      );
      final observerCtx = await observerOnInsertCtx.future.timeout(
        const Duration(seconds: 5),
      );

      // Caller side: full reducer metadata.
      expect(
        callerCtx.event,
        isA<ReducerEvent>(),
        reason: 'caller cache event must carry ReducerEvent',
      );
      expect(
        callerCtx.isMyTransaction,
        isTrue,
        reason: 'caller connection initiated this transaction',
      );

      final callerReducerEvent = callerCtx.event as ReducerEvent;
      expect(callerReducerEvent.reducerName, equals('create_note'));
      expect(callerReducerEvent.reducerArgs, isA<CreateNoteArgs>());

      // Caller's onCreateNote listener fires with decoded args.
      final callerArgs = await callerOnReducerArgs.future.timeout(
        const Duration(seconds: 2),
      );
      expect(callerArgs.title, equals(uniqueTitle));
      expect(callerArgs.content, equals('body'));

      final callerReducerCtx = await callerOnReducerCtx.future;
      expect(callerReducerCtx.isMyTransaction, isTrue);

      // Observer side: row insert observed but no reducer metadata.
      expect(
        observerCtx.event,
        isNot(isA<ReducerEvent>()),
        reason:
            'v2 deliberately drops reducer metadata for non-callers — '
            'observer must see UnknownTransactionEvent, not ReducerEvent',
      );
      expect(
        observerCtx.isMyTransaction,
        isFalse,
        reason: 'observer did not call this reducer',
      );

      // Give any in-flight reducer-emitter dispatch a chance to land before
      // asserting the observer's onCreateNote listener stayed silent.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(
        observerOnReducerFired,
        isFalse,
        reason:
            'v2 broadcasts row mutations without reducer metadata, so '
            'generated onXxx listeners on non-callers must not fire',
      );

      await callerInsertSub.cancel();
      await callerReducerSub.cancel();
      await observerInsertSub.cancel();
      await observerReducerSub.cancel();
    });
  });
}
