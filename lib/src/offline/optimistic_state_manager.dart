import 'package:spacetimedb_sdk/src/cache/client_cache.dart';
import 'package:spacetimedb_sdk/src/events/event_context.dart';
import 'package:spacetimedb_sdk/src/events/transaction_batch.dart';
import 'package:spacetimedb_sdk/src/utils/sdk_logger.dart';

import 'optimistic_change.dart';

class OptimisticEntry {
  final String tableName;
  final OptimisticChangeType type;
  final dynamic primaryKey;
  final Map<String, dynamic>? oldRowJson;
  final Map<String, dynamic>? newRowJson;

  OptimisticEntry({
    required this.tableName,
    required this.type,
    required this.primaryKey,
    this.oldRowJson,
    this.newRowJson,
  });
}

class _StashedCommit {
  final Map<String, dynamic>? rowJson;

  const _StashedCommit(this.rowJson);
}

class OptimisticStateManager {
  final ClientCache _cache;
  final Map<String, List<OptimisticEntry>> _entries = {};
  final Map<String, Map<dynamic, _StashedCommit>> _committedStash = {};

  OptimisticStateManager(this._cache);

  bool hasOptimisticChange(String requestId) => _entries.containsKey(requestId);

  Set<String> get activeRequestIds => _entries.keys.toSet();

  Set<dynamic> optimisticPrimaryKeysForTable(String tableName) {
    final keys = <dynamic>{};
    for (final entries in _entries.values) {
      for (final entry in entries) {
        if (entry.tableName == tableName && entry.primaryKey != null) {
          keys.add(entry.primaryKey);
        }
      }
    }
    return keys;
  }

  void applyOptimisticChanges(
    String requestId,
    List<OptimisticChange>? changes,
  ) {
    if (changes == null) return;

    final entries = <OptimisticEntry>[];
    final specsByTable = <String, List<TableEventSpec>>{};
    final context = EventContext.optimistic(requestId: requestId);

    for (final change in changes) {
      final table = _cache.getTableByName(change.tableName);
      if (table == null) {
        SdkLogger.w(
          'Table "${change.tableName}" not found and no decoder registered',
        );
        continue;
      }
      if (!table.decoder.supportsJsonSerialization) continue;

      switch (change.type) {
        case OptimisticChangeType.insert:
          final row = table.decoder.fromJson(change.newRowJson!);
          if (row != null) {
            final pk = table.decoder.getPrimaryKey(row);
            entries.add(
              OptimisticEntry(
                tableName: change.tableName,
                type: OptimisticChangeType.insert,
                primaryKey: pk,
                newRowJson: change.newRowJson,
              ),
            );
            table.insertRow(row);
            (specsByTable[change.tableName] ??= []).add(
              TableEventSpec.insert(row),
            );
          }
        case OptimisticChangeType.update:
          final oldRow = table.decoder.fromJson(change.oldRowJson!);
          final newRow = table.decoder.fromJson(change.newRowJson!);
          if (oldRow != null && newRow != null) {
            final pk = table.decoder.getPrimaryKey(newRow);
            entries.add(
              OptimisticEntry(
                tableName: change.tableName,
                type: OptimisticChangeType.update,
                primaryKey: pk,
                oldRowJson: change.oldRowJson,
                newRowJson: change.newRowJson,
              ),
            );
            table.updateRow(newRow);
            (specsByTable[change.tableName] ??= []).add(
              TableEventSpec.update(oldRow, newRow),
            );
          }
        case OptimisticChangeType.delete:
          final row = table.decoder.fromJson(change.oldRowJson!);
          if (row != null) {
            final pk = table.decoder.getPrimaryKey(row);
            entries.add(
              OptimisticEntry(
                tableName: change.tableName,
                type: OptimisticChangeType.delete,
                primaryKey: pk,
                oldRowJson: change.oldRowJson,
              ),
            );
            table.deleteRow(pk);
            (specsByTable[change.tableName] ??= []).add(
              TableEventSpec.delete(row),
            );
          }
      }
    }

    for (final entry in specsByTable.entries) {
      final table = _cache.getTableByName(entry.key);
      if (table != null) {
        table.emitBatch(entry.value, context);
      }
    }

    if (entries.isNotEmpty) {
      _entries.putIfAbsent(requestId, () => []).addAll(entries);
    }
  }

  List<OptimisticEntry> confirmOptimisticChange(String requestId) {
    final entries = _entries.remove(requestId) ?? const [];
    for (final entry in entries) {
      _releaseStashIfNoLongerOptimistic(entry.tableName, entry.primaryKey);
    }
    return entries;
  }

  void confirmOrRollbackWithTouchedKeys(
    String requestId,
    Map<String, Set<dynamic>> touchedKeysByTable,
  ) {
    final entries = _entries.remove(requestId);
    if (entries == null) return;

    SdkLogger.d('confirmOrRollbackWithTouchedKeys requestId="$requestId"');

    for (final entry in entries.reversed) {
      final touchedKeys = touchedKeysByTable[entry.tableName] ?? {};
      final wasTouched = touchedKeys.contains(entry.primaryKey);

      SdkLogger.d(
        'Change: ${entry.type.name}, table="${entry.tableName}", PK: "${entry.primaryKey}", wasTouched: $wasTouched',
      );

      if (wasTouched) {
        SdkLogger.d('CONFIRMED (key was touched)');
      } else {
        SdkLogger.d('ROLLING BACK (key NOT in touchedKeys)');
        _rollbackEntry(entry);
      }

      _releaseStashIfNoLongerOptimistic(entry.tableName, entry.primaryKey);
    }
  }

  Set<String> rollbackOptimisticChanges(String requestId) {
    final entries = _entries.remove(requestId);
    if (entries == null) return const {};

    final touchedTables = <String>{};
    for (final entry in entries.reversed) {
      _rollbackEntry(entry);
      touchedTables.add(entry.tableName);
      _releaseStashIfNoLongerOptimistic(entry.tableName, entry.primaryKey);
    }
    return touchedTables;
  }

  void clearNonOptimisticRows(String tableName) {
    final table = _cache.getTableByName(tableName);
    if (table == null) return;

    final optimisticPKs = optimisticPrimaryKeysForTable(tableName);
    if (optimisticPKs.isEmpty) {
      table.clear();
    } else {
      table.removeRowsWhere((pk) => !optimisticPKs.contains(pk));
    }
  }

  void clear() {
    _entries.clear();
    _committedStash.clear();
  }

  void stashCommittedState(
    String tableName,
    dynamic primaryKey,
    Map<String, dynamic>? committedRowJson,
  ) {
    if (primaryKey == null) return;
    (_committedStash[tableName] ??= {})[primaryKey] = _StashedCommit(
      committedRowJson,
    );
  }

  bool _isKeyStillOptimistic(String tableName, dynamic primaryKey) {
    for (final entries in _entries.values) {
      for (final entry in entries) {
        if (entry.tableName == tableName && entry.primaryKey == primaryKey) {
          return true;
        }
      }
    }
    return false;
  }

  void _releaseStashIfNoLongerOptimistic(String tableName, dynamic primaryKey) {
    if (primaryKey == null) return;
    if (_isKeyStillOptimistic(tableName, primaryKey)) return;
    final tableStash = _committedStash[tableName];
    if (tableStash == null) return;
    tableStash.remove(primaryKey);
    if (tableStash.isEmpty) _committedStash.remove(tableName);
  }

  void _rollbackEntry(OptimisticEntry entry) {
    final table = _cache.getTableByName(entry.tableName);
    if (table == null) return;

    final tableStash = _committedStash[entry.tableName];
    final hasStash =
        entry.primaryKey != null &&
        tableStash != null &&
        tableStash.containsKey(entry.primaryKey);

    if (hasStash) {
      final stashed = tableStash[entry.primaryKey]!;
      if (stashed.rowJson == null) {
        table.deleteRow(entry.primaryKey);
      } else {
        final row = table.decoder.fromJson(stashed.rowJson!);
        if (row != null) {
          table.insertRow(row);
        }
      }
      return;
    }

    switch (entry.type) {
      case OptimisticChangeType.insert:
        table.deleteRow(entry.primaryKey);
      case OptimisticChangeType.update:
        if (entry.oldRowJson != null) {
          final oldRow = table.decoder.fromJson(entry.oldRowJson!);
          if (oldRow != null) {
            table.updateRow(oldRow);
          }
        }
      case OptimisticChangeType.delete:
        if (entry.oldRowJson != null) {
          final oldRow = table.decoder.fromJson(entry.oldRowJson!);
          if (oldRow != null) {
            table.insertRow(oldRow);
          }
        }
    }
  }
}
