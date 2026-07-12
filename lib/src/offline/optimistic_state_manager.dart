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

  /// True iff, at the moment this change was applied, the row it displaces was
  /// a real committed row (no pending optimistic entry already sat on this
  /// table+pk). When false, the "base" this entry would restore on rollback is
  /// itself another uncommitted overlay — restoring it would resurrect a
  /// phantom, so the rollback must drop the pk instead.
  final bool baseCommitted;

  OptimisticEntry({
    required this.tableName,
    required this.type,
    required this.primaryKey,
    this.oldRowJson,
    this.newRowJson,
    this.baseCommitted = true,
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
  final Map<String, Map<dynamic, _StashedCommit>> _committedBase = {};
  final Map<String, Map<String, Set<dynamic>>> _confirmedOverlayKeys = {};

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

  List<Map<String, dynamic>> optimisticInsertRowsForTable(String tableName) {
    final rows = <Map<String, dynamic>>[];
    for (final entries in _entries.values) {
      for (final entry in entries) {
        if (entry.tableName == tableName &&
            entry.type == OptimisticChangeType.insert &&
            entry.newRowJson != null) {
          rows.add(entry.newRowJson!);
        }
      }
    }
    return rows;
  }

  List<Map<String, dynamic>> optimisticPkInsertRowsForTable(String tableName) {
    final rows = <Map<String, dynamic>>[];
    for (final entries in _entries.values) {
      for (final entry in entries) {
        if (entry.tableName == tableName &&
            entry.type == OptimisticChangeType.insert &&
            entry.primaryKey != null &&
            entry.newRowJson != null) {
          rows.add(entry.newRowJson!);
        }
      }
    }
    return rows;
  }

  Set<String> optimisticNoPkInsertRequestIdsForTable(String tableName) {
    final ids = <String>{};
    for (final mapEntry in _entries.entries) {
      for (final entry in mapEntry.value) {
        if (entry.tableName == tableName &&
            entry.type == OptimisticChangeType.insert &&
            entry.primaryKey == null) {
          ids.add(mapEntry.key);
        }
      }
    }
    return ids;
  }

  /// True iff no pending optimistic entry already sits on (tableName, pk) — i.e.
  /// the row currently at that pk is a committed row, not another overlay.
  bool _pkHasCommittedBase(String tableName, dynamic pk) {
    if (pk == null) return true;
    for (final entries in _entries.values) {
      for (final entry in entries) {
        if (entry.tableName == tableName && entry.primaryKey == pk) {
          return false;
        }
      }
    }
    return true;
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
            table.insertRow(row, requestId: pk == null ? requestId : null);
            (specsByTable[change.tableName] ??= []).add(
              TableEventSpec.insert(row),
            );
          }
        case OptimisticChangeType.update:
          final oldRow = table.decoder.fromJson(change.oldRowJson!);
          final newRow = table.decoder.fromJson(change.newRowJson!);
          if (oldRow != null && newRow != null) {
            final pk = table.decoder.getPrimaryKey(newRow);
            final oldPk = table.decoder.getPrimaryKey(oldRow);
            final baseCommitted =
                _pkHasCommittedBase(change.tableName, oldPk);
            if (baseCommitted) {
              _recordCommittedBase(change.tableName, pk, change.oldRowJson);
            }
            entries.add(
              OptimisticEntry(
                tableName: change.tableName,
                type: OptimisticChangeType.update,
                primaryKey: pk,
                oldRowJson: change.oldRowJson,
                newRowJson: change.newRowJson,
                baseCommitted: baseCommitted,
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
            final baseCommitted = _pkHasCommittedBase(change.tableName, pk);
            if (baseCommitted) {
              _recordCommittedBase(change.tableName, pk, change.oldRowJson);
            }
            entries.add(
              OptimisticEntry(
                tableName: change.tableName,
                type: OptimisticChangeType.delete,
                primaryKey: pk,
                oldRowJson: change.oldRowJson,
                baseCommitted: baseCommitted,
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
      if (entry.type == OptimisticChangeType.insert &&
          entry.primaryKey == null) {
        _cache.getTableByName(entry.tableName)?.clearNoPkRequestTag(requestId);
      }
      if ((entry.type == OptimisticChangeType.update ||
              entry.type == OptimisticChangeType.delete) &&
          entry.primaryKey != null) {
        ((_confirmedOverlayKeys[requestId] ??= {})[entry.tableName] ??= {})
            .add(entry.primaryKey);
      }
      _releaseStashIfNoLongerOptimistic(entry.tableName, entry.primaryKey);
    }
    return entries;
  }

  bool hasPendingEntryForKey(String tableName, dynamic primaryKey) {
    return _isKeyStillOptimistic(tableName, primaryKey);
  }

  bool wasOverlayConfirmedForKey(
    String requestId,
    String tableName,
    dynamic primaryKey,
  ) {
    return _confirmedOverlayKeys[requestId]?[tableName]?.contains(primaryKey) ??
        false;
  }

  void clearConfirmedOverlay(String requestId) {
    _confirmedOverlayKeys.remove(requestId);
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
        _rollbackEntry(entry, requestId);
      }

      _releaseStashIfNoLongerOptimistic(entry.tableName, entry.primaryKey);
    }
  }

  Set<String> rollbackOptimisticChanges(String requestId) {
    final entries = _entries.remove(requestId);
    if (entries == null) return const {};

    final touchedTables = <String>{};
    for (final entry in entries.reversed) {
      _rollbackEntry(entry, requestId);
      touchedTables.add(entry.tableName);
      _releaseStashIfNoLongerOptimistic(entry.tableName, entry.primaryKey);
    }
    return touchedTables;
  }

  void clearNonOptimisticRows(String tableName) {
    final table = _cache.getTableByName(tableName);
    if (table == null) return;

    if (!table.hasPrimaryKey) {
      table.clearUntaggedNoPkRows();
      return;
    }
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
    _confirmedOverlayKeys.clear();
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
    if (tableStash != null) {
      tableStash.remove(primaryKey);
      if (tableStash.isEmpty) _committedStash.remove(tableName);
    }
    final tableBase = _committedBase[tableName];
    if (tableBase != null) {
      tableBase.remove(primaryKey);
      if (tableBase.isEmpty) _committedBase.remove(tableName);
    }
  }

  void _recordCommittedBase(
    String tableName,
    dynamic primaryKey,
    Map<String, dynamic>? rowJson,
  ) {
    if (primaryKey == null) return;
    (_committedBase[tableName] ??= {}).putIfAbsent(
      primaryKey,
      () => _StashedCommit(rowJson),
    );
  }

  _StashedCommit? _committedBaseFor(String tableName, dynamic primaryKey) {
    if (primaryKey == null) return null;
    return _committedBase[tableName]?[primaryKey];
  }

  void _restoreCommittedBase(dynamic table, OptimisticEntry entry) {
    final base = _committedBaseFor(entry.tableName, entry.primaryKey);
    if (base == null) {
      if (entry.primaryKey != null) table.deleteRow(entry.primaryKey);
      return;
    }
    if (base.rowJson == null) {
      if (entry.primaryKey != null) table.deleteRow(entry.primaryKey);
      return;
    }
    final row = table.decoder.fromJson(base.rowJson!);
    if (row != null) {
      table.insertRow(row);
    }
  }

  void _rollbackEntry(OptimisticEntry entry, String requestId) {
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
      _reapplyNewestSurvivingOverlay(table, entry.tableName, entry.primaryKey);
      return;
    }

    var rolledBackUncommittedInsert = false;
    switch (entry.type) {
      case OptimisticChangeType.insert:
        if (!table.hasPrimaryKey) {
          if (entry.newRowJson != null) {
            table.removeNoPkRow(entry.newRowJson!, requestId: requestId);
          }
        } else {
          final base = _committedBaseFor(entry.tableName, entry.primaryKey);
          if (base?.rowJson != null) {
            _restoreCommittedBase(table, entry);
          } else {
            table.deleteRow(entry.primaryKey);
            rolledBackUncommittedInsert = true;
          }
        }
      case OptimisticChangeType.update:
        _restoreCommittedBase(table, entry);
      case OptimisticChangeType.delete:
        _restoreCommittedBase(table, entry);
    }

    _reapplyNewestSurvivingOverlay(
      table,
      entry.tableName,
      entry.primaryKey,
      rolledBackUncommittedInsert: rolledBackUncommittedInsert,
    );
  }

  void _reapplyNewestSurvivingOverlay(
    dynamic table,
    String tableName,
    dynamic primaryKey, {
    bool rolledBackUncommittedInsert = false,
  }) {
    if (primaryKey == null || !table.hasPrimaryKey) return;
    OptimisticEntry? newest;
    var hasSurvivingInsert = false;
    for (final entries in _entries.values) {
      for (final entry in entries) {
        if (entry.tableName == tableName && entry.primaryKey == primaryKey) {
          newest = entry;
          if (entry.type == OptimisticChangeType.insert) {
            hasSurvivingInsert = true;
          }
        }
      }
    }
    if (newest == null) return;
    // When we just rolled back an uncommitted insert (no committed row under
    // it), a surviving UPDATE overlay has no real base to sit on — re-applying
    // it would resurrect a phantom. Skip it UNLESS a surviving INSERT entry
    // still provides a base at this pk (stacked-insert / delete-recreate).
    if (rolledBackUncommittedInsert &&
        newest.type == OptimisticChangeType.update &&
        !hasSurvivingInsert) {
      return;
    }
    switch (newest.type) {
      case OptimisticChangeType.insert:
      case OptimisticChangeType.update:
        if (newest.newRowJson != null) {
          final row = table.decoder.fromJson(newest.newRowJson!);
          if (row != null) table.updateRow(row);
        }
      case OptimisticChangeType.delete:
        table.deleteRow(primaryKey);
    }
  }
}
