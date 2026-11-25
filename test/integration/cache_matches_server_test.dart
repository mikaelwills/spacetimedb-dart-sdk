@Tags(['integration'])
library;

import 'dart:io';

import 'package:spacetimedb_sdk/codegen.dart';
import 'package:spacetimedb_sdk/diagnostics.dart';
import 'package:test/test.dart';

import '../generated/note.dart';
import '../helpers/integration_test_helper.dart';
import '../helpers/test_env.dart';

const _host = 'localhost:3000';
const _database = 'notesdb';
const _noteTable = 'note';
const _settleStep = Duration(milliseconds: 250);
const _settleAttempts = 20;
const _leavingRowCount = 5;
const _reducerTimeout = Duration(seconds: 5);
const _connectTimeout = Duration(seconds: 5);
const _inside = 'lab-in';
const _outside = 'lab-out';
const _scopeA = 'lab-scope-a';
const _scopeB = 'lab-scope-b';
const _insideQuery = "SELECT * FROM note WHERE content = '$_inside'";
const _scopeAQuery = "SELECT * FROM note WHERE title = '$_scopeA'";
const _scopeBQuery = "SELECT * FROM note WHERE title = '$_scopeB'";
const _scopeAQueryReworded =
    "SELECT * FROM note WHERE title = '$_scopeA' AND timestamp = 0";
const _overwatchLikeConfig = ConnectionConfig(
  pingInterval: Duration(seconds: 10),
  pongTimeout: Duration(seconds: 5),
  autoReconnect: true,
  appLevelKeepAlive: true,
  retryInitialConnect: true,
);

class _Reader {
  _Reader(this.connection, this.subscriptions);

  final SpacetimeDbConnection connection;
  final SubscriptionManager subscriptions;

  static Future<_Reader> coldStartFrom(Directory cacheFolder) async {
    final connection = SpacetimeDbConnection(host: _host, database: _database);
    final subscriptions = SubscriptionManager(
      connection,
      offlineStorage: JsonFileStorage(basePath: cacheFolder.path),
      retainRowsOnUnsubscribe: true,
    );
    return _started(connection, subscriptions);
  }

  static Future<_Reader> withoutCache() {
    final connection = SpacetimeDbConnection(
      host: _host,
      database: _database,
      config: _overwatchLikeConfig,
    );
    return _started(connection, SubscriptionManager(connection));
  }

  static Future<_Reader> _started(
    SpacetimeDbConnection connection,
    SubscriptionManager subscriptions,
  ) async {
    subscriptions.cache.registerDecoder<Note>(_noteTable, NoteDecoder());
    await subscriptions.loadFromOfflineCache();
    await connection.connect();
    await subscriptions.onInitialConnection.first.timeout(_connectTimeout);
    return _Reader(connection, subscriptions);
  }

  Iterable<Note> get notes =>
      subscriptions.cache.getTableByTypedName<Note>(_noteTable).iter();

  Future<void> subscribeEach(List<String> queries) async {
    for (final query in queries) {
      await subscriptions.subscribe([query]);
    }
  }

  Future<void> shutDown() async {
    await subscriptions.flushOfflineSnapshots();
    await subscriptions.dispose();
    await connection.disconnect();
  }

  Future<List<Map<String, Object?>>> settledFaults() async {
    var faults = <Map<String, Object?>>[];
    for (var attempt = 0; attempt < _settleAttempts; attempt++) {
      final audits = await CacheAudit(subscriptions).auditHeldTables();
      faults = [
        for (final audit in audits)
          if (audit.isMismatch || !audit.wasCompared) audit.toJson(),
      ];
      if (faults.isEmpty) return faults;
      await Future<void>.delayed(_settleStep);
    }
    return faults;
  }
}

void main() {
  setUpAll(ensureTestEnvironment);
  tearDownAll(cleanupTestEnvironment);

  late TestEnv writer;
  late Directory cacheFolder;
  late _Reader reader;

  setUp(() async {
    writer = await createTestEnv();
    await writer.connection.connect();
    await writer.subManager.onInitialConnection.first.timeout(_connectTimeout);
    await writer.subManager.subscribe(['SELECT * FROM note']);
    await writer.reducers.deleteAllNotes().timeout(_reducerTimeout);
    cacheFolder = await Directory.systemTemp.createTemp('cache_matches_');
    reader = await _Reader.coldStartFrom(cacheFolder);
  });

  tearDown(() async {
    await reader.shutDown();
    writer.subManager.dispose();
    await writer.disconnect();
    await cacheFolder.delete(recursive: true);
  });

  Future<int> create(String title, String content) async {
    final before = writer.noteTable.iter().map((note) => note.id).toSet();
    await writer.reducers
        .createNote(title: title, content: content)
        .timeout(_reducerTimeout);
    for (var attempt = 0; attempt < _settleAttempts; attempt++) {
      final created = writer.noteTable.iter().where(
        (note) => !before.contains(note.id),
      );
      if (created.isNotEmpty) return created.first.id;
      await Future<void>.delayed(_settleStep);
    }
    fail('the writer never saw the note it created');
  }

  Future<void> update(int id, String title, String content) => writer.reducers
      .updateNote(noteId: id, title: title, content: content)
      .timeout(_reducerTimeout);

  Future<void> delete(int id) =>
      writer.reducers.deleteNote(noteId: id).timeout(_reducerTimeout);

  Future<void> expectCacheMatchesServer(String step) async {
    expect(await reader.settledFaults(), isEmpty, reason: 'after: $step');
  }

  Future<void> coldStartReader() async {
    await reader.shutDown();
    reader = await _Reader.coldStartFrom(cacheFolder);
  }

  Future<void> useReaderWithoutCache() async {
    await reader.shutDown();
    reader = await _Reader.withoutCache();
  }

  test(
    'a filtered query follows inserts, updates out and in, and deletes',
    () async {
      await reader.subscribeEach([_insideQuery]);
      final id = await create(_scopeA, _inside);
      await expectCacheMatchesServer('a row inserted into the filter');
      await update(id, _scopeA, _outside);
      await expectCacheMatchesServer('a row updated out of the filter');
      await update(id, _scopeA, _inside);
      await expectCacheMatchesServer('a row updated back into the filter');
      await delete(id);
      await expectCacheMatchesServer('a row deleted');
    },
  );

  test(
    'a change in one scope never evicts the rows of another scope',
    () async {
      final inA = await create(_scopeA, _inside);
      await create(_scopeB, _inside);
      await reader.subscribeEach([_scopeAQuery, _scopeBQuery]);
      await delete(inA);
      await create(_scopeA, _outside);
      await expectCacheMatchesServer('a delete and an insert in scope A');
      expect(reader.notes.where((note) => note.title == _scopeB), hasLength(1));
    },
  );

  test('a row two query sets cover leaves when neither matches it', () async {
    await reader.subscribeEach([_insideQuery, _scopeAQuery]);
    final id = await create(_scopeA, _inside);
    await expectCacheMatchesServer('a row both sets cover');
    await update(id, _scopeA, _outside);
    await expectCacheMatchesServer('the row left the content filter only');
    await update(id, _scopeB, _outside);
    await expectCacheMatchesServer('the row left both filters');
  });

  test('a primary key deleted and used again holds the new row', () async {
    await reader.subscribeEach([_insideQuery, _scopeAQuery]);
    await create(_scopeB, _outside);
    final reused = await create(_scopeA, _inside);
    await delete(reused);
    expect(await create(_scopeA, _outside), reused);
    await expectCacheMatchesServer('the key came back outside one filter');
    await delete(reused);
    expect(await create(_scopeB, _outside), reused);
    await expectCacheMatchesServer('the key came back outside both filters');
  });

  test(
    'rows deleted while their query was unsubscribed leave on resubscribe',
    () async {
      final kept = await create(_scopeA, _inside);
      final deleted = await create(_scopeA, _inside);
      final scopeA = await reader.subscriptions.subscribe([_scopeAQuery]);
      await reader.subscribeEach([_scopeBQuery]);
      reader.subscriptions.unsubscribe(scopeA);
      await expectCacheMatchesServer('unsubscribe keeps rows of no held query');
      await delete(deleted);
      await update(kept, _scopeA, _outside);
      await reader.subscribeEach([_scopeAQuery]);
      await expectCacheMatchesServer('resubscribe after an unsubscribe');
    },
  );

  test(
    'changes made while the reader was offline apply on reconnect',
    () async {
      final deleted = await create(_scopeA, _inside);
      final movedOut = await create(_scopeA, _inside);
      await reader.subscribeEach([_insideQuery, _scopeAQuery]);
      await expectCacheMatchesServer('subscribe');
      await reader.connection.disconnect();
      await delete(deleted);
      await update(movedOut, _scopeB, _outside);
      await create(_scopeA, _inside);
      await reader.connection.connect();
      await expectCacheMatchesServer('reconnect after offline changes');
    },
  );

  test(
    'a reader with no offline cache drops rows that left while offline',
    () async {
      await useReaderWithoutCache();
      final leaving = [
        for (var index = 0; index < _leavingRowCount; index++)
          await create(_scopeA, _inside),
      ];
      await reader.subscribeEach([_insideQuery]);
      await expectCacheMatchesServer('subscribe');
      await reader.connection.disconnect();
      for (final id in leaving) {
        await update(id, _scopeA, _outside);
      }
      await reader.connection.connect();
      await expectCacheMatchesServer('rows updated out while disconnected');
      final returning = await create(_scopeA, _inside);
      await reader.connection.reconnect();
      await update(returning, _scopeA, _outside);
      await expectCacheMatchesServer(
        'a row updated out right after a reconnect',
      );
    },
  );

  test('changes made while the app was closed apply on a cold start', () async {
    final deleted = await create(_scopeA, _inside);
    final movedOut = await create(_scopeA, _inside);
    await reader.subscribeEach([_insideQuery, _scopeAQuery]);
    await expectCacheMatchesServer('subscribe');
    await reader.shutDown();
    await delete(deleted);
    await update(movedOut, _scopeB, _outside);
    reader = await _Reader.coldStartFrom(cacheFolder);
    await reader.subscribeEach([_insideQuery, _scopeAQuery]);
    await expectCacheMatchesServer('cold start from the offline cache');
  });

  test(
    'a changed query text across a cold start leaves no stranded rows',
    () async {
      final deleted = await create(_scopeA, _inside);
      final movedOut = await create(_scopeA, _inside);
      await create(_scopeA, _inside);
      await reader.subscribeEach([_scopeAQuery]);
      await expectCacheMatchesServer('subscribe with the old query text');
      await reader.shutDown();
      await delete(deleted);
      await update(movedOut, _scopeB, _inside);
      reader = await _Reader.coldStartFrom(cacheFolder);
      await reader.subscribeEach([_scopeAQueryReworded]);
      await expectCacheMatchesServer('cold start with a new query text');
      await coldStartReader();
      await reader.subscribeEach([_scopeAQueryReworded]);
      await expectCacheMatchesServer('a second cold start with the new text');
    },
  );
}
