import 'package:spacetimedb_sdk/src/cache/client_cache.dart';
import 'package:spacetimedb_sdk/src/cache/table_cache.dart';
import 'package:spacetimedb_sdk/src/offline/pending_mutation.dart';

class AwaitedRows {
  AwaitedRows(this._cache);

  final ClientCache _cache;
  final Map<String, _RowKeys> _awaitedByRequest = {};
  final _RowKeys _heldThisPass = _RowKeys();
  bool _holdingRowsUnknown = false;

  void clear() {
    _awaitedByRequest.clear();
    _heldThisPass.clear();
    _holdingRowsUnknown = false;
  }

  bool releaseOwnedRow(String tableName, dynamic primaryKey) {
    final fullyOwned = <String>[];
    for (final MapEntry(key: requestId, value: keys)
        in _awaitedByRequest.entries) {
      if (keys.remove(tableName, primaryKey) && keys.isEmpty) {
        fullyOwned.add(requestId);
      }
    }
    fullyOwned.forEach(_awaitedByRequest.remove);
    return fullyOwned.isNotEmpty;
  }

  bool holdIfBlocked(PendingMutation mutation) {
    if (!_isHoldingAnything) return false;
    final keys = _rowKeysOf(mutation);
    if (keys == null) {
      _holdingRowsUnknown = true;
      return true;
    }
    if (!_holdingRowsUnknown && !keys.any(_isHeld)) return false;
    keys.forEach(_heldThisPass.add);
    return true;
  }

  void trackUnownedInserts(PendingMutation mutation) {
    for (final change in _changesOf(mutation)) {
      if (change.type != OptimisticChangeType.insert) continue;
      final table = _cache.getTableByName(change.tableName);
      if (table == null) continue;
      final primaryKey = _primaryKeyOf(table, change.newRowJson);
      if (primaryKey == null || table.ownedKeys(primaryKey).isNotEmpty) {
        continue;
      }
      _awaitedByRequest
          .putIfAbsent(mutation.requestId, _RowKeys.new)
          .add(_rowKey(change.tableName, primaryKey));
    }
  }

  bool get _isHoldingAnything =>
      _holdingRowsUnknown ||
      _awaitedByRequest.isNotEmpty ||
      _heldThisPass.isNotEmpty;

  bool _isHeld(_RowKey key) {
    return _heldThisPass.contains(key) ||
        _awaitedByRequest.values.any((keys) => keys.contains(key));
  }

  List<OptimisticChange> _changesOf(PendingMutation mutation) {
    return mutation.optimisticChanges ?? const <OptimisticChange>[];
  }

  List<_RowKey>? _rowKeysOf(PendingMutation mutation) {
    final changes = _changesOf(mutation);
    if (changes.isEmpty) return null;
    final keys = <_RowKey>[];
    for (final change in changes) {
      final key = _rowKeyOf(change);
      if (key == null) return null;
      keys.add(key);
    }
    return keys;
  }

  _RowKey? _rowKeyOf(OptimisticChange change) {
    final table = _cache.getTableByName(change.tableName);
    if (table == null) return null;
    final primaryKey = _primaryKeyOf(
      table,
      change.newRowJson ?? change.oldRowJson,
    );
    if (primaryKey == null) return null;
    return _rowKey(change.tableName, primaryKey);
  }

  _RowKey _rowKey(String tableName, dynamic primaryKey) {
    return (tableName: tableName, primaryKey: primaryKey);
  }

  dynamic _primaryKeyOf(TableCache<dynamic> table, Map<String, dynamic>? json) {
    if (json == null || !table.decoder.supportsJsonSerialization) return null;
    final row = table.decoder.fromJson(json);
    if (row == null) return null;
    return table.decoder.getPrimaryKey(row);
  }
}

typedef _RowKey = ({String tableName, dynamic primaryKey});

class _RowKeys {
  final Map<String, Set<dynamic>> _keysByTable = {};

  bool get isEmpty => _keysByTable.isEmpty;

  bool get isNotEmpty => _keysByTable.isNotEmpty;

  void clear() => _keysByTable.clear();

  void add(_RowKey key) {
    _keysByTable.putIfAbsent(key.tableName, () => <dynamic>{}).add(
      key.primaryKey,
    );
  }

  bool contains(_RowKey key) {
    final keys = _keysByTable[key.tableName];
    if (keys == null) return false;
    return keys.contains(key.primaryKey);
  }

  bool remove(String tableName, dynamic primaryKey) {
    final keys = _keysByTable[tableName];
    if (keys == null || !keys.remove(primaryKey)) return false;
    if (keys.isEmpty) _keysByTable.remove(tableName);
    return true;
  }
}
