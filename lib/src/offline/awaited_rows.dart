import 'package:spacetimedb_sdk/src/cache/client_cache.dart';
import 'package:spacetimedb_sdk/src/cache/table_cache.dart';
import 'package:spacetimedb_sdk/src/offline/pending_mutation.dart';

class AwaitedRows {
  AwaitedRows(this._cache);

  final ClientCache _cache;
  final Map<String, Set<dynamic>> _keysByTable = {};

  bool get isEmpty => _keysByTable.isEmpty;

  void clear() => _keysByTable.clear();

  bool remove(String tableName, dynamic primaryKey) {
    final keys = _keysByTable[tableName];
    if (keys == null || !keys.remove(primaryKey)) return false;
    if (keys.isEmpty) _keysByTable.remove(tableName);
    return true;
  }

  bool blocks(PendingMutation mutation) {
    if (isEmpty) return false;
    return _changesOf(mutation).any(_isAwaited);
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
      _keysByTable.putIfAbsent(change.tableName, () => <dynamic>{}).add(
        primaryKey,
      );
    }
  }

  List<OptimisticChange> _changesOf(PendingMutation mutation) {
    return mutation.optimisticChanges ?? const <OptimisticChange>[];
  }

  bool _isAwaited(OptimisticChange change) {
    final keys = _keysByTable[change.tableName];
    if (keys == null) return false;
    final table = _cache.getTableByName(change.tableName);
    if (table == null) return false;
    final primaryKey = _primaryKeyOf(
      table,
      change.newRowJson ?? change.oldRowJson,
    );
    return primaryKey != null && keys.contains(primaryKey);
  }

  dynamic _primaryKeyOf(TableCache<dynamic> table, Map<String, dynamic>? json) {
    if (json == null || !table.decoder.supportsJsonSerialization) return null;
    final row = table.decoder.fromJson(json);
    if (row == null) return null;
    return table.decoder.getPrimaryKey(row);
  }
}
