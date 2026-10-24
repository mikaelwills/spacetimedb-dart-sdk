@Tags(['integration'])
library;

import 'package:spacetimedb_sdk/src/messages/shared_types.dart';
import 'package:test/test.dart';

import '../helpers/integration_test_helper.dart';
import '../helpers/test_env.dart';

Future<TestEnv> _connected() async {
  final env = await createTestEnv();
  await env.connection.connect();
  await env.subManager.onInitialConnection.first.timeout(
    const Duration(seconds: 5),
  );
  return env;
}

class _Observer {
  _Observer(this.env) {
    env.noteTable.onInsert.listen((e) => events.add('insert'));
    env.noteTable.onUpdate.listen((e) => events.add('update'));
    env.noteTable.onDelete.listen((e) => events.add('delete'));
    env.subManager.onTransactionUpdate.listen((tx) {
      for (final querySet in tx.querySets) {
        for (final table in querySet.tables) {
          if (table.tableName != 'note') continue;
          wire.add([
            for (final group in table.rows)
              if (group is PersistentTableRows)
                'i${group.inserts.getRows().length}d${group.deletes.getRows().length}',
          ]);
        }
      }
    });
  }

  final TestEnv env;
  final events = <String>[];
  final wire = <List<String>>[];

  void clear() {
    events.clear();
    wire.clear();
  }
}

Future<void> _settle() => Future.delayed(const Duration(milliseconds: 500));

void main() {
  setUpAll(ensureTestEnvironment);
  tearDownAll(cleanupTestEnvironment);

  late TestEnv writer;
  late TestEnv reader;
  late _Observer observer;

  setUp(() async {
    writer = await _connected();
    reader = await _connected();
    await writer.subManager.subscribe(['SELECT * FROM note']);
  });

  tearDown(() async {
    writer.subManager.dispose();
    reader.subManager.dispose();
    await writer.disconnect();
    await reader.disconnect();
  });

  Future<int> createNote(String title, String content) async {
    final before = writer.noteTable.iter().map((n) => n.id).toSet();
    await writer.reducers
        .createNote(title: title, content: content)
        .timeout(const Duration(seconds: 5));
    await _settle();
    return writer.noteTable.iter().firstWhere((n) => !before.contains(n.id)).id;
  }

  Future<void> updateNote(int id, String title, String content) async {
    observer.clear();
    await writer.reducers
        .updateNote(noteId: id, title: title, content: content)
        .timeout(const Duration(seconds: 5));
    await _settle();
  }

  test(
    'a row moving between two WHERE queries of one query set stays cached, both directions',
    () async {
      const x = 'rowmove-x';
      const y = 'rowmove-y';
      await reader.subManager.subscribe([
        "SELECT * FROM note WHERE title = '$x'",
        "SELECT * FROM note WHERE title = '$y'",
      ]);
      observer = _Observer(reader);
      final id = await createNote(x, 'body');
      expect(reader.noteTable.getRow(id)?.title, x);

      await updateNote(id, y, 'body');
      final forwardWire = [...observer.wire];
      final forwardEvents = [...observer.events];
      final forwardRow = reader.noteTable.getRow(id)?.title;

      await updateNote(id, x, 'body');
      final backWire = [...observer.wire];
      final backEvents = [...observer.events];
      final backRow = reader.noteTable.getRow(id)?.title;

      printOnFailure('forward wire=$forwardWire events=$forwardEvents');
      printOnFailure('back wire=$backWire events=$backEvents');
      expect(
        forwardRow,
        y,
        reason: 'x -> y: wire=$forwardWire events=$forwardEvents',
      );
      expect(backRow, x, reason: 'y -> x: wire=$backWire events=$backEvents');
      expect(forwardEvents, ['update']);
      expect(backEvents, ['update']);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'a row leaving one of two overlapping WHERE queries of one set stays cached, both directions',
    () async {
      const x = 'overlap-x';
      const z = 'overlap-z';
      const c = 'overlap-c';
      await reader.subManager.subscribe([
        "SELECT * FROM note WHERE title = '$x'",
        "SELECT * FROM note WHERE content = '$c'",
      ]);
      observer = _Observer(reader);
      final leaveTitle = await createNote(x, c);
      final leaveContent = await createNote(x, c);
      expect(reader.noteTable.getRow(leaveTitle), isNotNull);
      expect(reader.noteTable.getRow(leaveContent), isNotNull);

      await updateNote(leaveTitle, z, c);
      final titleWire = [...observer.wire];
      final titleEvents = [...observer.events];
      final titleRow = reader.noteTable.getRow(leaveTitle)?.title;

      await updateNote(leaveContent, x, 'other');
      final contentWire = [...observer.wire];
      final contentEvents = [...observer.events];
      final contentRow = reader.noteTable.getRow(leaveContent)?.content;

      printOnFailure('leave title wire=$titleWire events=$titleEvents');
      printOnFailure('leave content wire=$contentWire events=$contentEvents');
      expect(
        titleRow,
        z,
        reason: 'leave title: wire=$titleWire events=$titleEvents',
      );
      expect(
        contentRow,
        'other',
        reason: 'leave content: wire=$contentWire events=$contentEvents',
      );
      expect(titleEvents, ['update']);
      expect(contentEvents, ['update']);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'the caller keeps a row its own reducer moves between two WHERE queries of one set, both directions',
    () async {
      const x = 'callermove-x';
      const y = 'callermove-y';
      await writer.subManager.subscribe([
        "SELECT * FROM note WHERE title = '$x'",
        "SELECT * FROM note WHERE title = '$y'",
      ]);
      final caller = await _connected();
      addTearDown(() async {
        caller.subManager.dispose();
        await caller.disconnect();
      });
      await caller.subManager.subscribe([
        "SELECT * FROM note WHERE title = '$x'",
        "SELECT * FROM note WHERE title = '$y'",
      ]);
      observer = _Observer(caller);
      final id = await createNote(x, 'body');
      expect(caller.noteTable.getRow(id)?.title, x);

      Future<(String?, List<String>)> move(String title) async {
        observer.clear();
        await caller.reducers
            .updateNote(noteId: id, title: title, content: 'body')
            .timeout(const Duration(seconds: 5));
        await _settle();
        return (caller.noteTable.getRow(id)?.title, [...observer.events]);
      }

      final (forwardRow, forwardEvents) = await move(y);
      final (backRow, backEvents) = await move(x);
      expect(forwardRow, y, reason: 'x -> y events=$forwardEvents');
      expect(backRow, x, reason: 'y -> x events=$backEvents');
      expect(forwardEvents, ['update']);
      expect(backEvents, ['update']);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test('a row leaving every WHERE query of one set is evicted once', () async {
    const x = 'leaveall-x';
    const c = 'leaveall-c';
    await reader.subManager.subscribe([
      "SELECT * FROM note WHERE title = '$x'",
      "SELECT * FROM note WHERE content = '$c'",
    ]);
    observer = _Observer(reader);
    final id = await createNote(x, c);
    expect(reader.noteTable.getRow(id), isNotNull);

    await updateNote(id, 'gone', 'gone');
    expect(
      reader.noteTable.getRow(id),
      isNull,
      reason: 'wire=${observer.wire}',
    );
    expect(observer.events, ['delete'], reason: 'wire=${observer.wire}');
  }, timeout: const Timeout(Duration(seconds: 60)));
}
