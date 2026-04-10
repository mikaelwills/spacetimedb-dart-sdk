import 'package:spacetimedb_dart_sdk/src/cache/client_cache.dart';
import 'package:spacetimedb_dart_sdk/src/events/event_context.dart';
import 'package:spacetimedb_dart_sdk/src/utils/sdk_logger.dart';

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

class OptimisticStateManager {
  final ClientCache _cache;
  final Map<String, List<OptimisticEntry>> _entries = {};

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

            final context = EventContext.optimistic(requestId: requestId);
            table.emitInsert(row, context);
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

            final context = EventContext.optimistic(requestId: requestId);
            table.emitUpdate(oldRow, newRow, context);
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

            final context = EventContext.optimistic(requestId: requestId);
            table.emitDelete(row, context);
          }
      }
    }

    if (entries.isNotEmpty) {
      _entries.putIfAbsent(requestId, () => []).addAll(entries);
    }
  }

  void confirmOptimisticChange(String requestId) {
    _entries.remove(requestId);
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
        continue;
      }

      SdkLogger.d('ROLLING BACK (key NOT in touchedKeys)');
      _rollbackEntry(entry);
    }
  }

  Set<String> rollbackOptimisticChanges(String requestId) {
    final entries = _entries.remove(requestId);
    if (entries == null) return const {};

    final touchedTables = <String>{};
    for (final entry in entries.reversed) {
      _rollbackEntry(entry);
      touchedTables.add(entry.tableName);
    }
    return touchedTables;
  }

  void _rollbackEntry(OptimisticEntry entry) {
    final table = _cache.getTableByName(entry.tableName);
    if (table == null) return;

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
  }
}
