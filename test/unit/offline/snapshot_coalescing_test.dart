import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';
import 'package:spacetimedb_sdk/codegen.dart';

import '../../generated/folder.dart';
import '../../mocks/mock_connection.dart';

const _timeout = Duration(seconds: 2);
const _query = "SELECT * FROM folder WHERE path LIKE '/a/%'";

class _CountingStorage extends InMemoryOfflineStorage {
  final Map<String, int> savesByTable = {};

  int savesOf(String tableName) => savesByTable[tableName] ?? 0;

  void reset() => savesByTable.clear();

  @override
  Future<void> saveTableSnapshot(
    String tableName,
    List<Map<String, dynamic>> rows,
  ) {
    savesByTable.update(tableName, (v) => v + 1, ifAbsent: () => 1);
    return super.saveTableSnapshot(tableName, rows);
  }
}

void _writeFolderRowList(BsatnEncoder encoder, List<Folder> folders) {
  final encodedRows =
      folders.map((folder) {
        final rowEncoder = BsatnEncoder();
        folder.encodeBsatn(rowEncoder);
        return rowEncoder.toBytes();
      }).toList();

  final offsets = <int>[];
  var currentOffset = 0;
  for (final row in encodedRows) {
    offsets.add(currentOffset);
    currentOffset += row.length;
  }

  encoder.writeU8(1);
  encoder.writeU32(offsets.length);
  for (final offset in offsets) {
    encoder.writeU64(Int64(offset));
  }

  final combined = Uint8List(currentOffset);
  var writeOffset = 0;
  for (final row in encodedRows) {
    combined.setRange(writeOffset, writeOffset + row.length, row);
    writeOffset += row.length;
  }
  encoder.writeU32(combined.length);
  encoder.writeBytes(combined);
}

Uint8List _subscribeApplied({required int querySetId}) {
  final encoder = BsatnEncoder();
  encoder.writeU8(0);
  encoder.writeU8(1);
  encoder.writeU32(0);
  encoder.writeU32(querySetId);
  encoder.writeU32(0);
  return encoder.toBytes();
}

class _GatedFileStorage extends JsonFileStorage {
  _GatedFileStorage({required super.basePath});

  Completer<void>? gate;
  final Completer<void> firstWriteDone = Completer<void>();

  @override
  Future<void> saveTableSnapshot(
    String tableName,
    List<Map<String, dynamic>> rows,
  ) async {
    await super.saveTableSnapshot(tableName, rows);
    final held = gate;
    if (held == null) return;
    gate = null;
    firstWriteDone.complete();
    await held.future;
  }
}

Uint8List _transactionUpdate({
  required int querySetId,
  String table = 'folder',
  List<Folder> inserts = const [],
}) {
  final encoder = BsatnEncoder();
  encoder.writeU8(0);
  encoder.writeU8(4);
  encoder.writeU32(1);
  encoder.writeU32(querySetId);
  encoder.writeU32(1);
  encoder.writeString(table);
  encoder.writeU32(1);
  encoder.writeU8(0);
  _writeFolderRowList(encoder, inserts);
  _writeFolderRowList(encoder, const []);
  return encoder.toBytes();
}

Uint8List _reducerResultOkEmpty({required int requestId}) {
  final encoder = BsatnEncoder();
  encoder.writeU8(0);
  encoder.writeU8(6);
  encoder.writeU32(requestId);
  encoder.writeU64(Int64(0));
  encoder.writeU8(1);
  return encoder.toBytes();
}

Uint8List _reducerResultCommittedNoQuerySets({required int requestId}) {
  final encoder = BsatnEncoder();
  encoder.writeU8(0);
  encoder.writeU8(6);
  encoder.writeU32(requestId);
  encoder.writeU64(Int64(0));
  encoder.writeU8(0);
  encoder.writeU32(0);
  encoder.writeU32(0);
  return encoder.toBytes();
}

Folder _folder(int i) =>
    Folder(path: '/a/f$i', name: 'Folder $i', createdAt: Int64(0));

SubscriptionManager _managerOn(MockConnection connection, OfflineStorage s) {
  final manager = SubscriptionManager(connection, offlineStorage: s);
  manager.cache.registerDecoder<Folder>('folder', FolderDecoder());
  return manager;
}

Iterable<String> _paths(List<Map<String, dynamic>>? rows) =>
    (rows ?? const []).map((r) => r['path'] ?? '');

void main() {
  late MockConnection connection;
  late _CountingStorage storage;
  late SubscriptionManager manager;

  setUp(() {
    connection = MockConnection();
    storage = _CountingStorage();
    manager = _managerOn(connection, storage);
  });

  tearDown(() async {
    await manager.dispose();
  });

  Future<void> subscribe() async {
    connection.mockState = const Connected();
    final applied = manager.subscribe([_query]);
    connection.simulateIncoming(_subscribeApplied(querySetId: 1));
    await applied.timeout(_timeout);
    storage.reset();
  }

  Future<void> burst(int count, {int from = 0}) async {
    for (var i = from; i < from + count; i++) {
      connection.simulateIncoming(
        _transactionUpdate(querySetId: 1, inserts: [_folder(i)]),
      );
    }
    await pumpEventQueue();
  }

  test('a burst of broadcast transactions does not rewrite the table '
      'snapshot once per transaction', () async {
    await subscribe();

    await burst(50);

    expect(manager.cache.getTableByName('folder')!.count(), 50);
    expect(storage.savesOf('folder'), 0);

    await manager.flushOfflineSnapshots();

    expect(storage.savesOf('folder'), 1);
    expect(_paths(await storage.loadTableSnapshot('folder')), hasLength(50));
  });

  test('a burst inside one window is written exactly once when the window '
      'elapses', () {
    fakeAsync((async) {
      final c = MockConnection();
      final s = _CountingStorage();
      final m = _managerOn(c, s);
      c.mockState = const Connected();
      m.subscribe([_query]);
      c.simulateIncoming(_subscribeApplied(querySetId: 1));
      async.flushMicrotasks();
      s.reset();

      for (var i = 0; i < 30; i++) {
        c.simulateIncoming(
          _transactionUpdate(querySetId: 1, inserts: [_folder(i)]),
        );
      }
      async.flushMicrotasks();
      expect(s.savesOf('folder'), 0);

      async.elapse(MutationSyncer.snapshotFlushWindow);
      expect(s.savesOf('folder'), 1);

      async.elapse(MutationSyncer.snapshotFlushWindow * 3);
      expect(s.savesOf('folder'), 1);
      m.dispose();
      async.flushMicrotasks();
    });
  });

  test('transactions arriving every second still flush once per window '
      '(throttle, not a resetting debounce)', () {
    fakeAsync((async) {
      final c = MockConnection();
      final s = _CountingStorage();
      final m = _managerOn(c, s);
      c.mockState = const Connected();
      m.subscribe([_query]);
      c.simulateIncoming(_subscribeApplied(querySetId: 1));
      async.flushMicrotasks();
      s.reset();

      for (var i = 0; i < 10; i++) {
        c.simulateIncoming(
          _transactionUpdate(querySetId: 1, inserts: [_folder(i)]),
        );
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 1));
        if (i == 1) expect(s.savesOf('folder'), 1);
      }

      expect(s.savesOf('folder'), 5);
      m.dispose();
      async.flushMicrotasks();
    });
  });

  for (final (name, state) in [
    ('Disconnected', const Disconnected() as ConnectionState),
    ('FatalError', const FatalError(message: 'boom') as ConnectionState),
    ('AuthError', const AuthError(message: 'denied') as ConnectionState),
  ]) {
    test('a pending dirty table is written on $name', () async {
      await subscribe();
      await burst(5);
      expect(storage.savesOf('folder'), 0);

      connection.mockState = state;
      await pumpEventQueue();

      expect(storage.savesOf('folder'), 1);
      expect(_paths(await storage.loadTableSnapshot('folder')), hasLength(5));
    });
  }

  test('a pending dirty table is written on dispose', () async {
    await subscribe();
    await burst(5);
    expect(storage.savesOf('folder'), 0);

    await manager.dispose();

    expect(storage.savesOf('folder'), 1);
    expect(_paths(await storage.loadTableSnapshot('folder')), hasLength(5));
  });

  test('dispose while a disconnect flush is still writing waits for it, so '
      'every pending table reaches disk', () async {
    final dir = await Directory.systemTemp.createTemp('snapshot_dispose_race_');
    addTearDown(() => dir.delete(recursive: true));
    final c = MockConnection();
    final s = _GatedFileStorage(basePath: dir.path);
    final m = SubscriptionManager(c, offlineStorage: s);
    m.cache.registerDecoder<Folder>('folder', FolderDecoder());
    m.cache.registerDecoder<Folder>('archive', FolderDecoder());
    c.mockState = const Connected();
    final folders = m.subscribe([_query]);
    c.simulateIncoming(_subscribeApplied(querySetId: 1));
    await folders.timeout(_timeout);
    final archive = m.subscribe(['SELECT * FROM archive']);
    c.simulateIncoming(_subscribeApplied(querySetId: 2));
    await archive.timeout(_timeout);

    c.simulateIncoming(
      _transactionUpdate(querySetId: 1, inserts: [_folder(1)]),
    );
    c.simulateIncoming(
      _transactionUpdate(
        querySetId: 2,
        table: 'archive',
        inserts: [_folder(2)],
      ),
    );
    await pumpEventQueue();

    final release = Completer<void>();
    s.gate = release;
    c.mockState = const Disconnected();
    await s.firstWriteDone.future.timeout(_timeout);

    final disposing = m.dispose();
    await pumpEventQueue();
    release.complete();
    await disposing.timeout(_timeout);

    final reloaded = JsonFileStorage(basePath: dir.path);
    expect(_paths(await reloaded.loadTableSnapshot('folder')), ['/a/f1']);
    expect(_paths(await reloaded.loadTableSnapshot('archive')), ['/a/f2']);
    await reloaded.dispose();
  });

  test('a relaunch after a flush loads the flushed rows from the warm '
      'cache', () async {
    await subscribe();
    await burst(20);
    await manager.flushOfflineSnapshots();

    final relaunched = _managerOn(MockConnection(), storage);
    await relaunched.loadFromOfflineCache();

    expect(relaunched.cache.getTableByName('folder')!.count(), 20);
    await relaunched.dispose();
  });

  test('a queued mutation survives a kill inside the window: the journal '
      'replays it with no snapshot write', () async {
    await subscribe();
    connection.setStateSilently(const Disconnected());

    unawaited(
      manager.reducers.call(
        'create_folder',
        Uint8List(0),
        optimisticChanges: [
          OptimisticChange.insert('folder', _folder(7).toJson()),
        ],
      ),
    );
    await pumpEventQueue();
    expect(storage.savesOf('folder'), 0);

    final relaunched = _managerOn(MockConnection(), storage);
    await relaunched.loadFromOfflineCache();

    expect(await relaunched.getPendingMutations(), hasLength(1));
    expect(
      relaunched.cache.getTableByName('folder')!.iter().map((f) => f.path),
      contains('/a/f7'),
    );
    await relaunched.dispose();
  });

  test('a direct-send commit is written immediately and clears the pending '
      'mark, so no second write follows', () async {
    await subscribe();
    await burst(3);

    unawaited(
      manager.reducers
          .call(
            'create_folder',
            Uint8List(0),
            dropIfOffline: true,
            optimisticChanges: [
              OptimisticChange.insert('folder', _folder(99).toJson()),
            ],
          )
          .catchError((_) => TransactionResult.dropped(reducerName: 'x')),
    );
    await pumpEventQueue();
    connection.simulateIncoming(
      _reducerResultOkEmpty(requestId: connection.getLastSentRequestId()),
    );
    await pumpEventQueue();

    expect(storage.savesOf('folder'), 1);
    expect(
      _paths(await storage.loadTableSnapshot('folder')),
      containsAll(['/a/f0', '/a/f1', '/a/f2', '/a/f99']),
    );

    await manager.flushOfflineSnapshots();

    expect(storage.savesOf('folder'), 1);
  });

  test('a retained unowned insert that gains an owner is released when the '
      'table is marked, before any flush', () async {
    await subscribe();

    unawaited(
      manager.reducers.call(
        'create_folder',
        Uint8List(0),
        optimisticChanges: [
          OptimisticChange.insert('folder', _folder(5).toJson()),
        ],
      ),
    );
    await pumpEventQueue();
    connection.simulateIncoming(
      _reducerResultCommittedNoQuerySets(
        requestId: connection.getLastSentRequestId(),
      ),
    );
    await pumpEventQueue();
    expect(manager.retainedUnownedInsertCountFor('folder'), 1);

    connection.simulateIncoming(
      _transactionUpdate(querySetId: 1, inserts: [_folder(5)]),
    );
    await pumpEventQueue();

    expect(manager.retainedUnownedInsertCountFor('folder'), 0);
    expect(storage.savesOf('folder'), 0);
  });
}
