import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:spacetimedb_dart_sdk/src/cache/row_decoder.dart';
import 'package:spacetimedb_dart_sdk/src/codec/bsatn_decoder.dart';
import 'package:spacetimedb_dart_sdk/src/messages/shared_types.dart';
import 'package:spacetimedb_dart_sdk/src/events/event_context.dart';
import 'package:spacetimedb_dart_sdk/src/events/table_event.dart';
import 'package:spacetimedb_dart_sdk/src/events/transaction_batch.dart';
import 'package:spacetimedb_dart_sdk/src/utils/sdk_logger.dart';

class TableCache<T> {
  final String tableName;
  final RowDecoder<T> decoder;
  final bool isEvent;
  final bool hasPrimaryKey;

  final Map<dynamic, T> _rowsByPrimaryKey = {};
  final List<T> _rows = [];

  final Map<dynamic, _AutoDisposeNotifier<T?>> _rowNotifiers = {};

  final ValueNotifier<List<T>> rows = ValueNotifier<List<T>>([]);
  final ValueNotifier<TransactionBatch<T>?> lastBatch =
      ValueNotifier<TransactionBatch<T>?>(null);

  final Completer<void> _subscribedCompleter = Completer<void>();

  /// Resolves when the server has delivered the initial subscription batch
  /// for this table. Completes exactly once; stays completed across
  /// reconnects. Resolves even for empty tables (no row-count gate). Throws
  /// [SpacetimeDbSubscriptionException] if the server rejects a subscription
  /// query that references this table by name.
  ///
  /// ```dart
  /// await client.connect(initialSubscriptions: ['SELECT * FROM notes']);
  /// await client.notes.subscribed;
  /// print('notes ready: ${client.notes.rows.value.length}');
  /// ```
  Future<void> get subscribed => _subscribedCompleter.future;

  TableCache({
    required this.tableName,
    required this.decoder,
    this.isEvent = false,
  }) : hasPrimaryKey = decoder.hasPrimaryKey;

  void markSubscribed() {
    if (!_subscribedCompleter.isCompleted) {
      _subscribedCompleter.complete();
    }
  }

  void markSubscribeFailed(Object error) {
    if (!_subscribedCompleter.isCompleted) {
      _subscribedCompleter.completeError(error);
    }
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
    return hasPrimaryKey ? _rowsByPrimaryKey.length : _rows.length;
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
    return hasPrimaryKey ? _rowsByPrimaryKey.values : _rows;
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
    if (_rowNotifiers.isNotEmpty) {
      _notifyRowListeners(_rowNotifiers.keys.toList());
    }
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
    if (!_subscribedCompleter.isCompleted) {
      _subscribedCompleter.complete();
    }
    for (final notifier in _rowNotifiers.values) {
      notifier.dispose();
    }
    _rowNotifiers.clear();
    rows.dispose();
    lastBatch.dispose();
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
    if (_rowNotifiers.isNotEmpty) {
      _notifyRowListeners(_rowNotifiers.keys.toList());
    }
  }

  void insertRow(T row) {
    final primaryKey = decoder.getPrimaryKey(row);
    if (primaryKey != null) {
      _rowsByPrimaryKey[primaryKey] = row;
    } else {
      _rows.add(row);
    }
    _refreshRowsNotifier();
    if (primaryKey != null && _rowNotifiers.containsKey(primaryKey)) {
      _notifyRowListeners([primaryKey]);
    }
  }

  void updateRow(T row) {
    if (!hasPrimaryKey) {
      throw StateError(
        'updateRow called on no-PK table "$tableName". '
        'Rebuild the cache via applyTransactionUpdate or loadFromSerializable instead.',
      );
    }
    final primaryKey = decoder.getPrimaryKey(row);
    if (primaryKey != null) {
      _rowsByPrimaryKey[primaryKey] = row;
    }
    _refreshRowsNotifier();
    if (primaryKey != null && _rowNotifiers.containsKey(primaryKey)) {
      _notifyRowListeners([primaryKey]);
    }
  }

  void deleteRow(dynamic primaryKey) {
    if (!hasPrimaryKey) {
      throw StateError(
        'deleteRow called on no-PK table "$tableName". '
        'Rebuild the cache via applyTransactionUpdate or loadFromSerializable instead.',
      );
    }
    _rowsByPrimaryKey.remove(primaryKey);
    _refreshRowsNotifier();
    if (_rowNotifiers.containsKey(primaryKey)) {
      _notifyRowListeners([primaryKey]);
    }
  }

  T? getRow(dynamic primaryKey) => _rowsByPrimaryKey[primaryKey];

  /// Returns a [ValueNotifier] that fires only when the row with this
  /// [primaryKey] changes. Fires when the row's value changes per `==` —
  /// a server touch that doesn't change any field is de-duplicated.
  ///
  /// The notifier is cached per key: repeated calls with the same key
  /// return the same instance. When the last listener detaches, the notifier
  /// is disposed and removed from the cache on the next microtask; a
  /// subsequent `rowNotifier(pk)` call creates a fresh instance.
  ///
  /// Only valid for tables with a declared primary key. Throws [StateError]
  /// on no-PK tables.
  ///
  /// ```dart
  /// final entity = client.entity.rowNotifier(entityId);
  /// entity.addListener(() => print('entity changed: ${entity.value}'));
  /// ```
  ValueNotifier<T?> rowNotifier(dynamic primaryKey) {
    if (!hasPrimaryKey) {
      throw StateError(
        'rowNotifier called on no-PK table "$tableName". '
        'Per-row notifiers require a declared primary key.',
      );
    }
    return _rowNotifiers.putIfAbsent(
      primaryKey,
      () => _AutoDisposeNotifier<T?>(
        _rowsByPrimaryKey[primaryKey],
        onEmpty: () => _removeRowNotifier(primaryKey),
      ),
    );
  }

  void emitBatch(List<TableEventSpec> specs, EventContext context) {
    _refreshRowsNotifier();
    if (specs.isEmpty) return;

    final events = <TableEvent<T>>[];
    for (final spec in specs) {
      switch (spec.kind) {
        case TableEventKind.insert:
          events.add(TableInsertEvent<T>(context, spec.newRow as T));
        case TableEventKind.update:
          events.add(
            TableUpdateEvent<T>(context, spec.oldRow as T, spec.newRow as T),
          );
        case TableEventKind.delete:
          events.add(TableDeleteEvent<T>(context, spec.oldRow as T));
      }
    }
    lastBatch.value = TransactionBatch<T>(context, events);
  }

  void removeRowsWhere(bool Function(dynamic pk) test) {
    final touchedKeys = <dynamic>[];
    if (_rowNotifiers.isNotEmpty) {
      for (final key in _rowNotifiers.keys) {
        if (test(key)) touchedKeys.add(key);
      }
    }
    _rowsByPrimaryKey.removeWhere((key, _) => test(key));
    _rows.removeWhere((row) {
      final pk = decoder.getPrimaryKey(row);
      return test(pk);
    });
    _refreshRowsNotifier();
    if (touchedKeys.isNotEmpty) {
      _notifyRowListeners(touchedKeys);
    }
  }

  void _refreshRowsNotifier() {
    rows.value =
        hasPrimaryKey
            ? List<T>.of(_rowsByPrimaryKey.values)
            : List<T>.of(_rows);
  }

  void _removeRowNotifier(dynamic primaryKey) {
    final removed = _rowNotifiers.remove(primaryKey);
    removed?.dispose();
  }

  void _notifyRowListeners(Iterable<dynamic> touchedKeys) {
    for (final key in touchedKeys) {
      final notifier = _rowNotifiers[key];
      if (notifier != null) {
        notifier.value = _rowsByPrimaryKey[key];
      }
    }
  }

  void _emitChanges(_RowChanges<T> changes, EventContext context) {
    if (!isEvent) {
      SdkLogger.d(
        'EMIT_CHANGES[$tableName]: inserts=${changes.inserted.length}, updates=${changes.updated.length}, deletes=${changes.deleted.length}',
      );
    }

    final events = <TableEvent<T>>[];
    for (final row in changes.inserted) {
      events.add(TableInsertEvent<T>(context, row));
    }
    for (final row in changes.deleted) {
      events.add(TableDeleteEvent<T>(context, row));
    }
    for (final (oldRow, newRow) in changes.updated) {
      events.add(TableUpdateEvent<T>(context, oldRow, newRow));
    }

    _refreshRowsNotifier();

    if (_rowNotifiers.isNotEmpty) {
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
      _notifyRowListeners(touchedKeys);
    }

    if (events.isNotEmpty) {
      lastBatch.value = TransactionBatch<T>(context, events);
    }
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

  _RowChanges<T> _applyChanges(BsatnRowList deletes, BsatnRowList inserts) {
    final changes = _RowChanges<T>();
    final oldValues = <dynamic, T>{};
    final pendingDeletes = <(dynamic, T)>[];

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
          pendingDeletes.add((primaryKey, old));
        } else {
          pendingDeletes.add((primaryKey, row));
        }
      } else {
        _rows.remove(row);
        changes.deleted.add(row);
      }
    }

    final coalescedKeys = <dynamic>{};
    for (final bytes in insertBytes) {
      final bsatnDecoder = BsatnDecoder(bytes);
      final row = decoder.decode(bsatnDecoder);
      final primaryKey = decoder.getPrimaryKey(row);

      if (primaryKey != null) {
        if (oldValues.containsKey(primaryKey)) {
          changes.updated.add((oldValues[primaryKey]!, row));
          coalescedKeys.add(primaryKey);
        } else {
          changes.inserted.add(row);
        }
        _rowsByPrimaryKey[primaryKey] = row;
      } else {
        changes.inserted.add(row);
        _rows.add(row);
      }
    }

    for (final (primaryKey, deletedRow) in pendingDeletes) {
      if (!coalescedKeys.contains(primaryKey)) {
        changes.deleted.add(deletedRow);
      }
    }

    return changes;
  }
}

class _RowChanges<T> {
  final List<T> inserted = [];
  final List<T> deleted = [];
  final List<(T, T)> updated = [];
}

class _AutoDisposeNotifier<T> extends ValueNotifier<T> {
  final VoidCallback onEmpty;
  bool _disposed = false;

  _AutoDisposeNotifier(super.value, {required this.onEmpty});

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    scheduleMicrotask(() {
      if (_disposed) return;
      if (!hasListeners) onEmpty();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
