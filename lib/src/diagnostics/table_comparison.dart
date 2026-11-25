import '../cache/table_cache.dart';
import 'held_query.dart';
import 'row_predicate.dart';
import 'table_audit.dart';

class TableComparison {
  TableComparison(this._table, this._held, this._serverRows);

  final TableCache _table;
  final List<HeldQuery> _held;
  final Map<Object, Object> _serverRows;

  TableAudit audit() {
    final cachedRows = _cachedRowsByKey();
    final absentFromServer = _keysAbsentFromServer(cachedRows);
    final retained = <Object>{
      for (final entry in cachedRows.entries)
        if (!_serverRows.containsKey(entry.key) &&
            _isRetainedForAnotherQuery(entry.key, entry.value))
          entry.key,
    };
    return TableAudit(
      tableName: _table.tableName,
      queries: [for (final query in _held) query.sql],
      cachedCount: cachedRows.length,
      serverCount: _serverRows.length,
      leakedKeys: absentFromServer.where((k) => !retained.contains(k)).toList(),
      missingKeys: _keysAbsentFromCache(cachedRows),
      staleKeys: _keysWithOtherContent(cachedRows),
      retainedForOtherQueriesCount: retained.length,
    );
  }

  Map<Object, Object> _cachedRowsByKey() {
    final rowsByKey = <Object, Object>{};
    for (final Object row in _table.iter()) {
      final Object? key = _table.decoder.getPrimaryKey(row);
      if (key != null) rowsByKey[key] = row;
    }
    return rowsByKey;
  }

  List<Object> _keysAbsentFromServer(Map<Object, Object> cachedRows) => [
    for (final key in cachedRows.keys)
      if (!_serverRows.containsKey(key)) key,
  ];

  List<Object> _keysAbsentFromCache(Map<Object, Object> cachedRows) => [
    for (final key in _serverRows.keys)
      if (!cachedRows.containsKey(key)) key,
  ];

  List<Object> _keysWithOtherContent(Map<Object, Object> cachedRows) => [
    for (final entry in cachedRows.entries)
      if (_serverRows.containsKey(entry.key) &&
          _serverRows[entry.key] != entry.value)
        entry.key,
  ];

  bool _isRetainedForAnotherQuery(Object key, Object row) {
    final hasRetainTags = _table.retainedTagsFor(key).isNotEmpty;
    if (!hasRetainTags) return false;
    final rowJson = _table.decoder.toJson(row);
    final cannotBeTestedAgainstQueries = rowJson == null;
    if (cannotBeTestedAgainstQueries) return true;
    return !_held.any((query) => _claims(query, rowJson));
  }

  bool _claims(HeldQuery query, Map<String, dynamic> rowJson) {
    if (!query.canTestRows) return false;
    try {
      return query.matches(rowJson);
    } on UnsupportedPredicate {
      return false;
    }
  }
}
