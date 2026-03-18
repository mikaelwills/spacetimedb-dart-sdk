import 'dart:async';

import 'package:spacetimedb_dart_sdk/src/cache/row_decoder.dart';
import 'package:spacetimedb_dart_sdk/src/codec/bsatn_decoder.dart';
import 'package:spacetimedb_dart_sdk/src/messages/shared_types.dart';
import 'package:spacetimedb_dart_sdk/src/events/event_context.dart';
import 'package:spacetimedb_dart_sdk/src/events/table_event.dart';
import 'package:spacetimedb_dart_sdk/src/events/event.dart';
import 'package:spacetimedb_dart_sdk/src/utils/sdk_logger.dart';

/// Client-side cache for a single SpacetimeDB table
///
/// Stores decoded rows in memory and provides:
/// - Fast lookups by primary key
/// - Real-time change streams (insertStream, updateStream, deleteStream, changeStream)
/// - Automatic update detection
///
/// The cache automatically processes transaction updates from the server
/// and emits changes to streams with zero overhead when no listeners are present.
///
/// Example:
/// ```dart
/// final noteTable = subscriptionManager.cache.getTable<Note>(4096);
///
/// // Listen to changes
/// noteTable.insertStream.listen((note) {
///   print('New note: ${note.title}');
/// });
///
/// noteTable.updateStream.listen((update) {
///   print('Updated: ${update.oldRow.title} → ${update.newRow.title}');
/// });
///
/// noteTable.deleteStream.listen((note) {
///   print('Deleted: ${note.title}');
/// });
///
/// // Query cached data
/// final note = noteTable.find(42);
/// print('Note count: ${noteTable.count()}');
///
/// for (final note in noteTable.iter()) {
///   print(note.title);
/// }
/// ```
class TableCache<T> {
  final int tableId;
  final String tableName;
  final RowDecoder<T> decoder;
  final bool isEvent;

  final Map<dynamic, T> _rowsByPrimaryKey = {};
  final List<T> _rows = [];

  final Map<String, List<_OptimisticChange<T>>> _optimisticChanges = {};

  // === Simple streams (existing - backward compatible) ===
  final StreamController<T> _insertController = StreamController<T>.broadcast();
  final StreamController<T> _deleteController = StreamController<T>.broadcast();
  final StreamController<TableUpdate<T>> _updateController =
      StreamController<TableUpdate<T>>.broadcast();
  final StreamController<TableChange<T>> _changeController =
      StreamController<TableChange<T>>.broadcast();

  // === Event streams with context (new - Phase 3) ===
  final StreamController<TableInsertEvent<T>> _insertEventController =
      StreamController<TableInsertEvent<T>>.broadcast();
  final StreamController<TableUpdateEvent<T>> _updateEventController =
      StreamController<TableUpdateEvent<T>>.broadcast();
  final StreamController<TableDeleteEvent<T>> _deleteEventController =
      StreamController<TableDeleteEvent<T>>.broadcast();
  final StreamController<TableEvent<T>> _eventController =
      StreamController<TableEvent<T>>.broadcast();

  TableCache(
      {required this.tableId, required this.tableName, required this.decoder, this.isEvent = false});

  /// Stream of inserted rows
  ///
  /// Zero-overhead broadcast stream that emits rows as they're inserted.
  /// Multiple listeners supported with no performance penalty.
  ///
  /// Example:
  /// ```dart
  /// noteTable.insertStream.listen((note) {
  ///   print('New note: ${note.title}');
  /// });
  /// ```
  Stream<T> get insertStream => _insertController.stream;

  /// Stream of deleted rows
  ///
  /// Example:
  /// ```dart
  /// noteTable.deleteStream.listen((note) {
  ///   print('Deleted: ${note.title}');
  /// });
  /// ```
  Stream<T> get deleteStream => _deleteController.stream;

  /// Stream of updated rows
  ///
  /// Emits TableUpdate objects containing both old and new row values.
  ///
  /// Example:
  /// ```dart
  /// noteTable.updateStream.listen((update) {
  ///   print('Updated: ${update.oldRow.title} → ${update.newRow.title}');
  /// });
  /// ```
  Stream<TableUpdate<T>> get updateStream => _updateController.stream;

  /// Combined stream of all changes
  ///
  /// Emits TableChange objects for inserts, updates, and deletes.
  /// Useful when you need to react to any change regardless of type.
  ///
  /// Example:
  /// ```dart
  /// noteTable.changeStream.listen((change) {
  ///   switch (change.type) {
  ///     case ChangeType.insert:
  ///       print('Inserted: ${change.row!.title}');
  ///     case ChangeType.update:
  ///       print('Updated: ${change.oldRow!.title} → ${change.newRow!.title}');
  ///     case ChangeType.delete:
  ///       print('Deleted: ${change.row!.title}');
  ///   }
  /// });
  /// ```
  Stream<TableChange<T>> get changeStream => _changeController.stream;

  // === Enhanced event streams with context (Phase 3) ===

  /// Stream of insert events with transaction context
  ///
  /// Each event includes the inserted row and EventContext with metadata about
  /// what caused the transaction (reducer name, caller, status, etc.).
  ///
  /// Example:
  /// ```dart
  /// noteTable.insertEventStream.listen((event) {
  ///   print('New note: ${event.row.title}');
  ///
  ///   if (event.context.isMyTransaction) {
  ///     print('I created this note!');
  ///   }
  ///
  ///   if (event.context.event is ReducerEvent) {
  ///     final reducerEvent = event.context.event as ReducerEvent;
  ///     print('Created by reducer: ${reducerEvent.reducerName}');
  ///   }
  /// });
  /// ```
  Stream<TableInsertEvent<T>> get insertEventStream =>
      _insertEventController.stream;

  /// Stream of update events with transaction context
  ///
  /// Each event includes both old and new row versions plus EventContext.
  ///
  /// Example:
  /// ```dart
  /// noteTable.updateEventStream.listen((event) {
  ///   print('Updated: ${event.oldRow.title} → ${event.newRow.title}');
  ///
  ///   if (event.context.isMyTransaction) {
  ///     print('I updated this note!');
  ///   }
  /// });
  /// ```
  Stream<TableUpdateEvent<T>> get updateEventStream =>
      _updateEventController.stream;

  /// Stream of delete events with transaction context
  ///
  /// Each event includes the deleted row and EventContext.
  ///
  /// Example:
  /// ```dart
  /// noteTable.deleteEventStream.listen((event) {
  ///   print('Deleted note: ${event.row.title}');
  ///
  ///   if (event.context.isMyTransaction) {
  ///     print('I deleted this note!');
  ///   }
  /// });
  /// ```
  Stream<TableDeleteEvent<T>> get deleteEventStream =>
      _deleteEventController.stream;

  /// Unified stream of all table events with context
  ///
  /// Emits all insert, update, and delete events as TableEvent sealed class.
  /// Use pattern matching to handle different event types.
  ///
  /// Example:
  /// ```dart
  /// noteTable.eventStream.listen((event) {
  ///   switch (event) {
  ///     case TableInsertEvent(:final row, :final context):
  ///       print('Inserted: ${row.title}');
  ///       if (context.isMyTransaction) print('By me!');
  ///     case TableUpdateEvent(:final oldRow, :final newRow):
  ///       print('Updated: ${oldRow.title} → ${newRow.title}');
  ///     case TableDeleteEvent(:final row):
  ///       print('Deleted: ${row.title}');
  ///   }
  /// });
  /// ```
  Stream<TableEvent<T>> get eventStream => _eventController.stream;

  // === Convenience filter streams (Phase 3) ===

  /// Stream of inserts caused by reducers only (not subscriptions)
  ///
  /// Filters out inserts from initial subscription loads, showing only
  /// inserts triggered by reducer calls.
  ///
  /// Example:
  /// ```dart
  /// noteTable.insertsFromReducers.listen((event) {
  ///   print('Note created by reducer: ${event.row.title}');
  ///   final reducerEvent = event.context.event as ReducerEvent;
  ///   print('Reducer: ${reducerEvent.reducerName}');
  /// });
  /// ```
  Stream<TableInsertEvent<T>> get insertsFromReducers =>
      insertEventStream.where((e) => e.context.event is ReducerEvent);

  /// Stream of inserts from the current client only
  ///
  /// Filters to show only rows inserted by transactions initiated by this
  /// client connection. Useful for showing feedback for user actions.
  ///
  /// Example:
  /// ```dart
  /// noteTable.myInserts.listen((event) {
  ///   print('I created: ${event.row.title}');
  ///   // Show success toast to user
  /// });
  /// ```
  Stream<TableInsertEvent<T>> get myInserts =>
      insertEventStream.where((e) => e.context.isMyTransaction);

  /// Stream of all events caused by reducers (not subscriptions)
  ///
  /// Filters to show only changes triggered by reducer calls, excluding
  /// initial subscription loads.
  ///
  /// Example:
  /// ```dart
  /// noteTable.eventsFromReducers.listen((event) {
  ///   switch (event) {
  ///     case TableInsertEvent(:final row):
  ///       print('Reducer added: ${row.title}');
  ///     case TableUpdateEvent(:final oldRow, :final newRow):
  ///       print('Reducer updated: ${oldRow.title} → ${newRow.title}');
  ///     case TableDeleteEvent(:final row):
  ///       print('Reducer deleted: ${row.title}');
  ///   }
  /// });
  /// ```
  Stream<TableEvent<T>> get eventsFromReducers =>
      eventStream.where((e) => e.context.event is ReducerEvent);

  /// Stream of all events from the current client only
  ///
  /// Filters to show only changes from transactions initiated by this client.
  ///
  /// Example:
  /// ```dart
  /// noteTable.myEvents.listen((event) {
  ///   print('I made a change!');
  ///   // Update UI to reflect user's action
  /// });
  /// ```
  Stream<TableEvent<T>> get myEvents =>
      eventStream.where((e) => e.context.isMyTransaction);

  void _emitChanges(_RowChanges<T> changes, EventContext context) {
    if (!isEvent) {
      SdkLogger.i('EMIT_CHANGES[$tableName]: inserts=${changes.inserted.length}, updates=${changes.updated.length}, deletes=${changes.deleted.length}');
    }
    for (final row in changes.inserted) {
      _insertController.add(row);
      _changeController.add(TableChange.insert(row));

      final insertEvent = TableInsertEvent(context, row);
      _insertEventController.add(insertEvent);
      _eventController.add(insertEvent);
    }

    for (final row in changes.deleted) {
      _deleteController.add(row);
      _changeController.add(TableChange.delete(row));

      final deleteEvent = TableDeleteEvent(context, row);
      _deleteEventController.add(deleteEvent);
      _eventController.add(deleteEvent);
    }

    for (final (oldRow, newRow) in changes.updated) {
      _updateController.add(TableUpdate(oldRow, newRow));
      _changeController.add(TableChange.update(oldRow, newRow));

      final updateEvent = TableUpdateEvent(context, oldRow, newRow);
      _updateEventController.add(updateEvent);
      _eventController.add(updateEvent);
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
  }

  void dispose() {
    _insertController.close();
    _deleteController.close();
    _updateController.close();
    _changeController.close();
    _insertEventController.close();
    _updateEventController.close();
    _deleteEventController.close();
    _eventController.close();
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

  void loadFromSerializable(List<Map<String, dynamic>> rows) {
    if (!decoder.supportsJsonSerialization) {
      throw UnsupportedError(
        'Table "$tableName" decoder does not support JSON serialization. '
        'Implement toJson() and fromJson() in your RowDecoder.',
      );
    }
    final savedOptimisticChanges =
        Map<String, List<_OptimisticChange<T>>>.from(_optimisticChanges);
    clear();
    _optimisticChanges.addAll(savedOptimisticChanges);
    for (final json in rows) {
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
  }

  void insertRow(T row) {
    final primaryKey = decoder.getPrimaryKey(row);
    if (primaryKey != null) {
      _rowsByPrimaryKey[primaryKey] = row;
    } else {
      _rows.add(row);
    }
  }

  void updateRow(T row) {
    final primaryKey = decoder.getPrimaryKey(row);
    if (primaryKey != null) {
      _rowsByPrimaryKey[primaryKey] = row;
    }
  }

  void deleteRow(dynamic primaryKey) {
    _rowsByPrimaryKey.remove(primaryKey);
  }

  T? getRow(dynamic primaryKey) => _rowsByPrimaryKey[primaryKey];

  void applyOptimisticInsert(String requestId, T row) {
    final primaryKey = decoder.getPrimaryKey(row);
    final change = _OptimisticChange<T>(
      type: _OptimisticChangeType.insert,
      primaryKey: primaryKey,
      newRow: row,
    );
    _optimisticChanges.putIfAbsent(requestId, () => []).add(change);
    insertRow(row);

    _insertController.add(row);
    _changeController.add(TableChange.insert(row));

    final context = EventContext.optimistic(requestId: requestId);
    final insertEvent = TableInsertEvent(context, row);
    _insertEventController.add(insertEvent);
    _eventController.add(insertEvent);
  }

  void applyOptimisticUpdate(String requestId, T oldRow, T newRow) {
    final primaryKey = decoder.getPrimaryKey(newRow);
    final change = _OptimisticChange<T>(
      type: _OptimisticChangeType.update,
      primaryKey: primaryKey,
      oldRow: oldRow,
      newRow: newRow,
    );
    _optimisticChanges.putIfAbsent(requestId, () => []).add(change);
    updateRow(newRow);

    _updateController.add(TableUpdate(oldRow, newRow));
    _changeController.add(TableChange.update(oldRow, newRow));

    final context = EventContext.optimistic(requestId: requestId);
    final updateEvent = TableUpdateEvent(context, oldRow, newRow);
    _updateEventController.add(updateEvent);
    _eventController.add(updateEvent);
  }

  void applyOptimisticDelete(String requestId, T row) {
    final primaryKey = decoder.getPrimaryKey(row);
    final change = _OptimisticChange<T>(
      type: _OptimisticChangeType.delete,
      primaryKey: primaryKey,
      oldRow: row,
    );
    _optimisticChanges.putIfAbsent(requestId, () => []).add(change);
    deleteRow(primaryKey);

    _deleteController.add(row);
    _changeController.add(TableChange.delete(row));

    final context = EventContext.optimistic(requestId: requestId);
    final deleteEvent = TableDeleteEvent(context, row);
    _deleteEventController.add(deleteEvent);
    _eventController.add(deleteEvent);
  }

  void confirmOptimisticChange(String requestId) {
    _optimisticChanges.remove(requestId);
  }

  void confirmOrRollbackOptimisticChange(String requestId, Set<dynamic> touchedKeys) {
    final changes = _optimisticChanges.remove(requestId);
    if (changes == null) return;

    SdkLogger.d('confirmOrRollbackOptimisticChange for "$tableName" requestId="$requestId"');
    SdkLogger.d('touchedKeys: ${touchedKeys.map((k) => '"$k"').toList()}, changes: ${changes.length}');

    for (final change in changes.reversed) {
      final wasTouched = touchedKeys.contains(change.primaryKey);

      SdkLogger.d('Change: ${change.type.name}, PK: "${change.primaryKey}", wasTouched: $wasTouched');

      if (wasTouched) {
        SdkLogger.d('CONFIRMED (key was touched)');
        continue;
      }

      SdkLogger.d('ROLLING BACK (key NOT in touchedKeys)');
      switch (change.type) {
        case _OptimisticChangeType.insert:
          deleteRow(change.primaryKey);
        case _OptimisticChangeType.update:
          if (change.oldRow != null) {
            updateRow(change.oldRow as T);
          }
        case _OptimisticChangeType.delete:
          if (change.oldRow != null) {
            SdkLogger.d('Re-inserting deleted row');
            insertRow(change.oldRow as T);
          }
      }
    }
  }

  void rollbackOptimisticChange(String requestId) {
    final changes = _optimisticChanges.remove(requestId);
    if (changes == null) return;

    for (final change in changes.reversed) {
      switch (change.type) {
        case _OptimisticChangeType.insert:
          deleteRow(change.primaryKey);
        case _OptimisticChangeType.update:
          if (change.oldRow != null) {
            updateRow(change.oldRow as T);
          }
        case _OptimisticChangeType.delete:
          if (change.oldRow != null) {
            insertRow(change.oldRow as T);
          }
      }
    }
  }

  bool hasOptimisticChange(String requestId) =>
      _optimisticChanges.containsKey(requestId);

  int get optimisticChangeCount =>
      _optimisticChanges.values.fold(0, (sum, list) => sum + list.length);

  /// Clears all rows that are NOT involved in pending optimistic changes.
  ///
  /// This is called before applying InitialSubscription to remove "zombie" rows
  /// that may have been deleted on the server but are still in the local cache
  /// due to a crash or failed persistence.
  ///
  /// Rows involved in pending optimistic mutations are preserved to avoid
  /// losing user changes that haven't been synced yet.
  void clearNonOptimisticRows() {
    final optimisticPrimaryKeys = <dynamic>{};
    for (final changes in _optimisticChanges.values) {
      for (final change in changes) {
        if (change.primaryKey != null) {
          optimisticPrimaryKeys.add(change.primaryKey);
        }
      }
    }

    if (optimisticPrimaryKeys.isEmpty) {
      clear();
    } else {
      _rowsByPrimaryKey.removeWhere((key, _) => !optimisticPrimaryKeys.contains(key));
      _rows.removeWhere((row) {
        final pk = decoder.getPrimaryKey(row);
        return !optimisticPrimaryKeys.contains(pk);
      });
    }
  }
}

enum _OptimisticChangeType { insert, update, delete }

class _OptimisticChange<T> {
  final _OptimisticChangeType type;
  final dynamic primaryKey;
  final T? oldRow;
  final T? newRow;

  _OptimisticChange({
    required this.type,
    required this.primaryKey,
    this.oldRow,
    this.newRow,
  });
}

class _RowChanges<T> {
  final List<T> inserted = [];
  final List<T> deleted = [];
  final List<(T, T)> updated = [];
}

/// Represents an update to a row (old value → new value)
class TableUpdate<T> {
  final T oldRow;
  final T newRow;

  TableUpdate(this.oldRow, this.newRow);
}

/// Types of changes that can occur to a table
enum ChangeType { insert, update, delete }

/// Represents any change to a table row
class TableChange<T> {
  final ChangeType type;
  final T? row; 
  final T? oldRow;
  final T? newRow; 

  TableChange.insert(this.row)
      : type = ChangeType.insert,
        oldRow = null,
        newRow = null;

  TableChange.update(this.oldRow, this.newRow)
      : type = ChangeType.update,
        row = null;

  TableChange.delete(this.row)
      : type = ChangeType.delete,
        oldRow = null,
        newRow = null;
}
