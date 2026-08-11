import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

class OpCounter {
  int visited = 0;
}

class CurrentAlgoTable {
  final Map<int, int> rowsByPk;
  Map<int, Set<int>> rowOwners;

  CurrentAlgoTable(this.rowsByPk, this.rowOwners);

  Set<int> get primaryKeys => rowsByPk.keys.toSet();

  Set<int> ownedKeys(int pk) => rowOwners[pk] ?? const {};

  void clearOwners() => rowOwners = {};

  int reconnect(List<int> reported, int querySetId, OpCounter ops) {
    final oldKeys = <int>{};
    for (final pk in primaryKeys) {
      ops.visited++;
      if (ownedKeys(pk).isNotEmpty) oldKeys.add(pk);
    }
    clearOwners();

    for (final pk in reported) {
      ops.visited++;
      rowOwners.putIfAbsent(pk, () => <int>{}).add(querySetId);
    }

    final toEvict = <int>[];
    for (final pk in oldKeys) {
      ops.visited++;
      if (ownedKeys(pk).isEmpty) toEvict.add(pk);
    }

    final evictSet = toEvict.toSet();
    final matched = <int>[];
    for (final pk in rowsByPk.keys) {
      ops.visited++;
      if (evictSet.contains(pk)) matched.add(pk);
    }
    for (final pk in matched) {
      rowsByPk.remove(pk);
      rowOwners.remove(pk);
    }
    return matched.length;
  }
}

class SwapAlgoTable {
  final Map<int, int> rowsByPk;
  Map<int, Set<int>> rowOwners;
  Map<int, Set<int>> previousOwners = {};

  SwapAlgoTable(this.rowsByPk, this.rowOwners);

  void beginGeneration() {
    if (previousOwners.isEmpty) {
      previousOwners = rowOwners;
    } else {
      previousOwners.addAll(rowOwners);
    }
    rowOwners = {};
  }

  Set<int> ownedKeys(int pk) =>
      rowOwners[pk] ?? previousOwners[pk] ?? const {};

  void applyReported(List<int> reported, int querySetId, OpCounter ops) {
    for (final pk in reported) {
      ops.visited++;
      rowOwners.putIfAbsent(pk, () => <int>{}).add(querySetId);
      previousOwners.remove(pk);
    }
  }

  int finalizeGeneration(OpCounter ops) {
    var evicted = 0;
    for (final pk in previousOwners.keys) {
      ops.visited++;
      rowsByPk.remove(pk);
      evicted++;
    }
    previousOwners = {};
    return evicted;
  }
}

({Map<int, int> rows, Map<int, Set<int>> owners}) buildState({
  required int held,
  required int owned,
}) {
  final rows = <int, int>{for (var i = 0; i < held; i++) i: i};
  final owners = <int, Set<int>>{
    for (var i = 0; i < owned; i++) i: {1},
  };
  return (rows: rows, owners: owners);
}

void runScenario({
  required String name,
  required int held,
  required int owned,
  required int deletedOnServer,
}) {
  final reported = List<int>.generate(
    owned - deletedOnServer,
    (i) => i + deletedOnServer,
  );

  final a = buildState(held: held, owned: owned);
  final current = CurrentAlgoTable(a.rows, a.owners);
  final currentOps = OpCounter();
  final swA = Stopwatch()..start();
  final currentEvicted = current.reconnect(reported, 1, currentOps);
  swA.stop();

  final b = buildState(held: held, owned: owned);
  final swap = SwapAlgoTable(b.rows, b.owners);
  final swapOps = OpCounter();
  final swB = Stopwatch()..start();
  swap.beginGeneration();
  swap.applyReported(reported, 1, swapOps);
  final swapEvicted = swap.finalizeGeneration(swapOps);
  swB.stop();

  expect(currentEvicted, deletedOnServer);
  expect(swapEvicted, deletedOnServer);
  expect(current.rowsByPk.length, swap.rowsByPk.length);
  expect(
    setEquals(current.rowsByPk.keys.toSet(), swap.rowsByPk.keys.toSet()),
    isTrue,
  );
  for (final pk in reported) {
    expect(setEquals(current.ownedKeys(pk), swap.ownedKeys(pk)), isTrue);
  }

  final reportedCount = reported.length;
  debugPrint(
    '$name: held=$held owned=$owned reported=$reportedCount '
    'deleted=$deletedOnServer | current ops=${currentOps.visited} '
    '(${swA.elapsedMicroseconds}us) | swap ops=${swapOps.visited} '
    '(${swB.elapsedMicroseconds}us) | '
    'ratio=${(currentOps.visited / swapOps.visited).toStringAsFixed(1)}x',
  );
}

void main() {
  test('spike: disk-heavy cache, small live subscription', () {
    runScenario(
      name: 'disk-heavy',
      held: 500000,
      owned: 5000,
      deletedOnServer: 10,
    );
  });

  test('spike: fully-owned cache, tiny server-side delta', () {
    runScenario(
      name: 'fully-owned',
      held: 200000,
      owned: 200000,
      deletedOnServer: 10,
    );
  });

  test('spike: fully-owned cache, large server-side delta', () {
    runScenario(
      name: 'large-delta',
      held: 200000,
      owned: 200000,
      deletedOnServer: 100000,
    );
  });

  test('spike: bounce mid-generation never evicts and guards stay live', () {
    final b = buildState(held: 1000, owned: 1000);
    final swap = SwapAlgoTable(b.rows, b.owners);
    final ops = OpCounter();

    swap.beginGeneration();
    swap.applyReported(List<int>.generate(400, (i) => i), 1, ops);

    expect(swap.ownedKeys(700), isNotEmpty);
    expect(swap.rowsByPk.length, 1000);

    swap.beginGeneration();
    swap.applyReported(List<int>.generate(990, (i) => i), 1, ops);
    final evicted = swap.finalizeGeneration(ops);

    expect(evicted, 10);
    expect(swap.rowsByPk.length, 990);
  });
}
