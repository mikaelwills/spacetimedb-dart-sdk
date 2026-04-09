import 'package:spacetimedb_dart_sdk/src/utils/value_notifier.dart';
import 'package:spacetimedb_dart_sdk/src/cache/row_decoder.dart';
import 'package:spacetimedb_dart_sdk/src/codec/bsatn_decoder.dart';
import 'package:spacetimedb_dart_sdk/src/messages/shared_types.dart';
import 'package:spacetimedb_dart_sdk/src/events/event_context.dart';
import 'package:spacetimedb_dart_sdk/src/events/table_event.dart';
import 'package:spacetimedb_dart_sdk/src/utils/sdk_logger.dart';

class TableCache<T> {
  final String tableName;
  final RowDecoder<T> decoder;
  final bool isEvent;

  final Map<dynamic, T> _rowsByPrimaryKey = {};
  final List<T> _rows = [];

  final ValueNotifier<List<T>> rows = ValueNotifier<List<T>>([]);
  final ValueNotifier<TableEvent<T>?> lastEvent = ValueNotifier<TableEvent<T>?>(
    null,
  );

  TableCache({
    required this.tableName,
    required this.decoder,
    this.isEvent = false,
  });

  void _refreshRowsNotifier() {
    rows.value =
        _rowsByPrimaryKey.isNotEmpty
            ? List<T>.of(_rowsByPrimaryKey.values)
            : List<T>.of(_rows);
  }

  void _emitChanges(_RowChanges<T> changes, EventContext context) {
    if (!isEvent) {
      SdkLogger.i(
        'EMIT_CHANGES[$tableName]: inserts=${changes.inserted.length}, updates=${changes.updated.length}, deletes=${changes.deleted.length}',
      );
    }
    for (final row in changes.inserted) {
      lastEvent.value = TableInsertEvent(context, row);
    }

    for (final row in changes.deleted) {
      lastEvent.value = TableDeleteEvent(context, row);
    }

    for (final (oldRow, newRow) in changes.updated) {
      lastEvent.value = TableUpdateEvent(context, oldRow, newRow);
    }

    _refreshRowsNotifier();
  }

  /// Apply transaction update with event context
  ///
  /// Updates the cache with inserts/deletes from a transaction and emits
  /// changes to streams. The EventContext contains metadata about what
  /// caused the transaction (reducer name, caller, status, etc.).
  ///
  /// Phase 3 will add enhanced event streams that include the context.
  void applyTransactionUpdate(
    BsatnRowList deletes,
    BsatnRowList inserts,
    EventContext context,
  ) {
    final changes = _applyChanges(deletes, inserts);
    _emitChanges(changes, context);

    if (isEvent) {
      _rowsByPrimaryKey.clear();
      _rows.clear();
    }
  }

  /// Apply transaction update and return the set of touched primary keys
  ///
  /// Used for touch-based optimistic confirmation. Returns all primary keys
  /// that were inserted, updated, or deleted in this transaction.
  Set<dynamic> applyTransactionUpdateAndCollectKeys(
    BsatnRowList deletes,
    BsatnRowList inserts,
    EventContext context,
  ) {
    final changes = _applyChanges(deletes, inserts);
    _emitChanges(changes, context);

    if (isEvent) {
      _rowsByPrimaryKey.clear();
      _rows.clear();
    }

    final touchedKeys = <dynamic>{};
    for (final row in changes.inserted) {
      final pk = decoder.getPrimaryKey(row);
      if (pk != null) touchedKeys.add(pk);
    }
    for (final row in changes.deleted) {
      final pk = decoder.getPrimaryKey(row);
      if (pk != null) touchedKeys.add(pk);
    }
    for (final (_, newRow) in changes.updated) {
      final pk = decoder.getPrimaryKey(newRow);
      if (pk != null) touchedKeys.add(pk);
    }
    return touchedKeys;
  }

  /// Returns the number of rows in the cache
  ///
  /// Example:
  /// ```dart
  /// print('Total notes: ${noteTable.count()}');
  /// ```
  int count() {
    return _rowsByPrimaryKey.isNotEmpty
        ? _rowsByPrimaryKey.length
        : _rows.length;
  }

  /// Finds a row by its primary key
  ///
  /// Returns null if the row is not found or if the table has no primary key.
  ///
  /// Example:
  /// ```dart
  /// final note = noteTable.find(42);
  /// if (note != null) {
  ///   print('Found: ${note.title}');
  /// }
  /// ```
  T? find(dynamic primaryKey) => _rowsByPrimaryKey[primaryKey];

  /// Returns an iterable of all rows in the cache
  ///
  /// Example:
  /// ```dart
  /// for (final note in noteTable.iter()) {
  ///   print('${note.id}. ${note.title}');
  /// }
  /// ```
  Iterable<T> iter() {
    return _rowsByPrimaryKey.isNotEmpty ? _rowsByPrimaryKey.values : _rows;
  }

  void _decodeAndStoreRows(BsatnRowList rowList) {
    final rowBytes = rowList.getRows();

    for (final bytes in rowBytes) {
      final bsatnDecoder = BsatnDecoder(bytes);
      final row = decoder.decode(bsatnDecoder);

      final primaryKey = decoder.getPrimaryKey(row);
      if (primaryKey != null) {
        _rowsByPrimaryKey[primaryKey] = row;
      } else {
        _rows.add(row);
      }
    }
  }

  void applyDeletes(BsatnRowList deletes) {
    final rowBytes = deletes.getRows();
    for (final bytes in rowBytes) {
      final bsatnDecoder = BsatnDecoder(bytes);
      final row = decoder.decode(bsatnDecoder);
      final primaryKey = decoder.getPrimaryKey(row);
      if (primaryKey != null) {
        _rowsByPrimaryKey.remove(primaryKey);
      } else {
        _rows.remove(row);
      }
    }
  }

  _RowChanges<T> _applyChanges(BsatnRowList deletes, BsatnRowList inserts) {
    final changes = _RowChanges<T>();
    final oldValues = <dynamic, T>{};

    final deleteBytes = deletes.getRows();
    final insertBytes = inserts.getRows();

    for (final bytes in deleteBytes) {
      final bsatnDecoder = BsatnDecoder(bytes);
      final row = decoder.decode(bsatnDecoder);
      final primaryKey = decoder.getPrimaryKey(row);
      if (primaryKey != null) {
        final old = _rowsByPrimaryKey.remove(primaryKey);
        if (old != null) {
          oldValues[primaryKey] = old;
          changes.deleted.add(old);
        } else {
          changes.deleted.add(row);
        }
      } else {
        _rows.remove(row);
        changes.deleted.add(row);
      }
    }

    for (final bytes in insertBytes) {
      final bsatnDecoder = BsatnDecoder(bytes);
      final row = decoder.decode(bsatnDecoder);
      final primaryKey = decoder.getPrimaryKey(row);

      if (primaryKey != null) {
        if (oldValues.containsKey(primaryKey)) {
          changes.updated.add((oldValues[primaryKey]!, row));
        } else {
          changes.inserted.add(row);
        }
        _rowsByPrimaryKey[primaryKey] = row;
      } else {
        changes.inserted.add(row);
        _rows.add(row);
      }
    }

    return changes;
  }

  /// Clears all rows from the cache
  ///
  /// Example:
  /// ```dart
  /// noteTable.clear();
  /// ```
  void clear() {
    _rowsByPrimaryKey.clear();
    _rows.clear();
    _refreshRowsNotifier();
  }

  /// Apply initial subscription data with event context
  ///
  /// Called when initial subscription data arrives. Emits events with
  /// SubscribeAppliedEvent so users can distinguish initial load from updates.
  void applyInitialData(BsatnRowList inserts, EventContext context) {
    // Treat initial data as inserts with no deletes
    final changes = _applyChanges(BsatnRowList.empty(), inserts);
    _emitChanges(changes, context);
  }

  void applyInserts(BsatnRowList inserts) {
    _decodeAndStoreRows(inserts);
    _refreshRowsNotifier();
  }

  void dispose() {
    rows.dispose();
    lastEvent.dispose();
  }

  List<Map<String, dynamic>> toSerializable() {
    if (!decoder.supportsJsonSerialization) {
      throw UnsupportedError(
        'Table "$tableName" decoder does not support JSON serialization. '
        'Implement toJson() and fromJson() in your RowDecoder.',
      );
    }
    return iter().map((row) => decoder.toJson(row)!).toList();
  }

  void loadFromSerializable(List<Map<String, dynamic>> jsonRows) {
    if (!decoder.supportsJsonSerialization) {
      throw UnsupportedError(
        'Table "$tableName" decoder does not support JSON serialization. '
        'Implement toJson() and fromJson() in your RowDecoder.',
      );
    }
    _rowsByPrimaryKey.clear();
    _rows.clear();
    for (final json in jsonRows) {
      final row = decoder.fromJson(json);
      if (row == null) {
        SdkLogger.w('Failed to deserialize row in table "$tableName": $json');
        continue;
      }
      final primaryKey = decoder.getPrimaryKey(row);
      if (primaryKey != null) {
        _rowsByPrimaryKey[primaryKey] = row;
      } else {
        _rows.add(row);
      }
    }
    _refreshRowsNotifier();
  }

  void insertRow(T row) {
    final primaryKey = decoder.getPrimaryKey(row);
    if (primaryKey != null) {
      _rowsByPrimaryKey[primaryKey] = row;
    } else {
      _rows.add(row);
    }
    _refreshRowsNotifier();
  }

  void updateRow(T row) {
    final primaryKey = decoder.getPrimaryKey(row);
    if (primaryKey != null) {
      _rowsByPrimaryKey[primaryKey] = row;
    }
    _refreshRowsNotifier();
  }

  void deleteRow(dynamic primaryKey) {
    _rowsByPrimaryKey.remove(primaryKey);
    _refreshRowsNotifier();
  }

  T? getRow(dynamic primaryKey) => _rowsByPrimaryKey[primaryKey];

  void emitInsert(T row, EventContext context) {
    lastEvent.value = TableInsertEvent(context, row);
    _refreshRowsNotifier();
  }

  void emitUpdate(T oldRow, T newRow, EventContext context) {
    lastEvent.value = TableUpdateEvent(context, oldRow, newRow);
    _refreshRowsNotifier();
  }

  void emitDelete(T row, EventContext context) {
    lastEvent.value = TableDeleteEvent(context, row);
    _refreshRowsNotifier();
  }

  void removeRowsWhere(bool Function(dynamic pk) test) {
    _rowsByPrimaryKey.removeWhere((key, _) => test(key));
    _rows.removeWhere((row) {
      final pk = decoder.getPrimaryKey(row);
      return test(pk);
    });
    _refreshRowsNotifier();
  }
}

class _RowChanges<T> {
  final List<T> inserted = [];
  final List<T> deleted = [];
  final List<(T, T)> updated = [];
}
