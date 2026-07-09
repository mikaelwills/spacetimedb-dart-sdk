import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:spacetimedb_sdk/codegen.dart';
import 'package:spacetimedb_sdk/protocol.dart';

import '../../mocks/mock_connection.dart';

/// Proves the requestId-tag design keeps the tag aligned to its row across
/// mid-list removal, interleaved server deletes, identical rows, bulk clear,
/// and snapshot round-trips — the failure modes a parallel-array design would
/// hit and the reason the `_CachedRow` wrapper exists.

class _StringDecoder extends RowDecoder<String> {
  @override
  bool get hasPrimaryKey => false;
  @override
  String decode(BsatnDecoder decoder) => decoder.readString();
  @override
  dynamic getPrimaryKey(String row) => null;
  @override
  bool get supportsJsonSerialization => true;
  @override
  Map<String, dynamic> toJson(String row) => {'v': row};
  @override
  String fromJson(Map<String, dynamic> json) => json['v'] as String;
}

Uint8List _enc(String v) {
  final e = BsatnEncoder();
  e.writeString(v);
  return e.toBytes();
}

BsatnRowList _rowList(List<String> values) {
  if (values.isEmpty) return BsatnRowList.empty();
  final encoded = values.map(_enc).toList();
  final offsets = <int>[];
  var cursor = 0;
  for (final r in encoded) {
    offsets.add(cursor);
    cursor += r.length;
  }
  final combined = Uint8List(cursor);
  var w = 0;
  for (final r in encoded) {
    combined.setRange(w, w + r.length, r);
    w += r.length;
  }
  return BsatnRowList(
    sizeHint: RowSizeHint.rowOffsets(offsets),
    rowsData: combined,
  );
}

OptimisticChange _insert(String v) =>
    OptimisticChange.insert('logs', {'v': v});

({ClientCache cache, TableCache<String> table, OptimisticStateManager opt})
_env() {
  final cache = ClientCache();
  cache.registerDecoder<String>('logs', _StringDecoder());
  final table = cache.getTableByTypedName<String>('logs');
  return (cache: cache, table: table, opt: OptimisticStateManager(cache));
}

MutationSyncer _syncer(
  MockConnection connection,
  InMemoryOfflineStorage storage,
  ClientCache cache,
  OptimisticStateManager opt,
) {
  return MutationSyncer(
    connection: connection,
    storage: storage,
    optimisticState: opt,
    cache: cache,
    send: (reducerName, args, {requestId}) async => TransactionResult(
      status: Committed(),
      timestamp: DateTime.now(),
      reducerName: reducerName,
    ),
  );
}

void main() {
  test('1. mid-list rollback removes only the middle overlay, tag stays '
      'aligned', () {
    final e = _env();
    e.opt.applyOptimisticChanges('r1', [_insert('a')]);
    e.opt.applyOptimisticChanges('r2', [_insert('b')]);
    e.opt.applyOptimisticChanges('r3', [_insert('c')]);
    expect(e.table.iter().toList(), ['a', 'b', 'c']);

    e.opt.rollbackOptimisticChanges('r2');
    expect(e.table.iter().toList(), ['a', 'c'],
        reason: 'only r2 removed, r1 and r3 untouched');

    e.opt.rollbackOptimisticChanges('r1');
    e.opt.rollbackOptimisticChanges('r3');
    expect(e.table.iter(), isEmpty);
  });

  test('2. interleaved server-delete removes the committed copy, not a pending '
      'overlay', () {
    final e = _env();
    e.table.applyTransactionUpdate(BsatnRowList.empty(), _rowList(['x']),
        EventContext.optimistic(requestId: 'srv'));
    e.opt.applyOptimisticChanges('r1', [_insert('x')]);
    expect(e.table.count(), 2, reason: 'committed x + pending overlay x');

    e.table.applyDeletes(_rowList(['x']));
    expect(e.table.count(), 1, reason: 'server delete eats the UNTAGGED copy');

    e.opt.rollbackOptimisticChanges('r1');
    expect(e.table.iter(), isEmpty, reason: 'rollback removes the overlay');
  });

  test('3. two identical rows: rolling back one removes THAT one, not the '
      'other', () {
    final e = _env();
    e.opt.applyOptimisticChanges('r1', [_insert('same')]);
    e.opt.applyOptimisticChanges('r2', [_insert('same')]);
    expect(e.table.count(), 2);

    e.opt.rollbackOptimisticChanges('r1');
    expect(e.table.count(), 1, reason: 'exactly one identical row remains');

    e.opt.rollbackOptimisticChanges('r2');
    expect(e.table.iter(), isEmpty, reason: 'r2 still identifiable by tag');
  });

  test('4. two identical PENDING overlays + server delete (no committed copy) '
      'is a NO-OP, then each rolls back its own', () {
    final e = _env();
    e.opt.applyOptimisticChanges('r1', [_insert('dup')]);
    e.opt.applyOptimisticChanges('r2', [_insert('dup')]);
    expect(e.table.count(), 2);

    e.table.applyDeletes(_rowList(['dup']));
    expect(e.table.count(), 2,
        reason: 'server delete must NOT touch tagged overlays (no-op)');

    e.opt.rollbackOptimisticChanges('r1');
    expect(e.table.count(), 1);
    e.opt.rollbackOptimisticChanges('r2');
    expect(e.table.iter(), isEmpty,
        reason: 'neither rollback ate the other overlay');
  });

  test('5. bulk clear leaves no orphaned tags: reinsert same requestId works',
      () {
    final e = _env();
    e.opt.applyOptimisticChanges('r1', [_insert('a')]);
    e.table.clear();
    expect(e.table.iter(), isEmpty);

    e.opt.applyOptimisticChanges('r1', [_insert('b')]);
    expect(e.table.iter().toList(), ['b']);
    e.opt.rollbackOptimisticChanges('r1');
    expect(e.table.iter(), isEmpty, reason: 'no orphaned tag from the clear');
  });

  test('6. snapshot round-trip: overlay excluded from snapshot, replay re-tags, '
      'rollback removes exactly the replayed row', () async {
    final connection = MockConnection();
    connection.setStateSilently(const Connected());
    final storage = InMemoryOfflineStorage();

    final e1 = _env();
    final s1 = _syncer(connection, storage, e1.cache, e1.opt);
    await s1.ensureInitialized();

    await storage.enqueueMutation(PendingMutation(
      requestId: 'r1',
      reducerName: 'push',
      encodedArgs: Uint8List(0),
      createdAt: DateTime.now(),
      optimisticChanges: [_insert('pending')],
    ));
    s1.onOptimisticChanges('r1', [_insert('pending')]);
    await Future<void>.delayed(Duration.zero);
    expect(e1.table.iter().toList(), ['pending']);

    final e2 = _env();
    final s2 = _syncer(connection, storage, e2.cache, e2.opt);
    await s2.loadFromOfflineCache();

    expect(e2.table.iter().toList(), ['pending'],
        reason: 'snapshot excluded the overlay; replay re-applied it once');
    e2.opt.rollbackOptimisticChanges('r1');
    expect(e2.table.iter(), isEmpty,
        reason: 'replayed row was re-tagged so rollback finds it');
  });
}
