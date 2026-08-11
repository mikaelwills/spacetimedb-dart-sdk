import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:spacetimedb_sdk/src/cache/row_decoder.dart';
import 'package:spacetimedb_sdk/src/codec/bsatn_decoder.dart';
import 'package:spacetimedb_sdk/src/messages/shared_types.dart';
import 'package:spacetimedb_sdk/src/events/event_context.dart';
import 'package:spacetimedb_sdk/src/events/table_event.dart';
import 'package:spacetimedb_sdk/src/events/transaction_batch.dart';
import 'package:spacetimedb_sdk/src/utils/sdk_logger.dart';

class TableCache<T> {
  final String tableName;
  @internal
  final RowDecoder<T> decoder;
  final bool isEvent;
  final bool hasPrimaryKey;

  final Map<dynamic, T> _rowsByPrimaryKey = {};
  final List<_CachedRow<T>> _rows = [];

  Map<dynamic, Set<int>> _rowOwners = {};

  final Map<dynamic, Set<int>> _previousOwners = {};

  final Map<dynamic, Set<int>> _retainedTags = {};

  @internal
  @visibleForTesting
  int get ownershipImbalanceCount => _ownershipImbalanceCount;
  int _ownershipImbalanceCount = 0;

  /// Rows evicted because their last owning query set was unsubscribed
  /// (`dropQuerySet`). Monotonic per table instance. Together with
  /// [reconcileEvictionCount] and [sweepEvictionCount] this lets a consumer
  /// distinguish explained cache shrinkage from anomalies.
  int get unsubscribeEvictionCount => _unsubscribeEvictionCount;
  int _unsubscribeEvictionCount = 0;

  /// Rows evicted by snapshot reconciliation: previously owned or retained
  /// under the arriving query set's tag, but absent from its snapshot.
  int get reconcileEvictionCount => _reconcileEvictionCount;
  int _reconcileEvictionCount = 0;

  /// Rows evicted by the unowned-row sweep that runs when a snapshot applies
  /// outside a reconnect window (stale disk-loaded rows).
  int get sweepEvictionCount => _sweepEvictionCount;
  int _sweepEvictionCount = 0;

  @internal
  @visibleForTesting
  Set<int> retainedTagsFor(dynamic primaryKey) =>
      _retainedTags[primaryKey] ?? const {};

  @internal
  @visibleForTesting
  int get retainedTagEntryCount => _retainedTags.length;

  final Map<dynamic, _AutoDisposeNotifier<T?>> _rowNotifiers = {};

  final ValueNotifier<List<T>> rows = ValueNotifier<List<T>>([]);
  final ValueNotifier<TransactionBatch<T>?> lastBatch =
      ValueNotifier<TransactionBatch<T>?>(null);

  final StreamController<TableInsertEvent<T>> _onInsertController =
      StreamController<TableInsertEvent<T>>.broadcast(sync: true);
  final StreamController<TableUpdateEvent<T>> _onUpdateController =
      StreamController<TableUpdateEvent<T>>.broadcast(sync: true);
  final StreamController<TableDeleteEvent<T>> _onDeleteController =
      StreamController<TableDeleteEvent<T>>.broadcast(sync: true);

  /// Fires when a row is inserted into this table. Broadcast — multiple
  /// subscribers each receive every event. No replay: late subscribers do not
  /// see past events. Fires synchronously during the transaction, before
  /// [lastBatch] fires.
  ///
  /// ```dart
  /// client.chat.onInsert.listen((e) => playDingSound());
  /// ```
  Stream<TableInsertEvent<T>> get onInsert => _onInsertController.stream;

  /// Fires when a row is updated. `oldRow` and `newRow` are both provided on
  /// the event. See [onInsert] for broadcast/ordering semantics.
  Stream<TableUpdateEvent<T>> get onUpdate => _onUpdateController.stream;

  /// Fires when a row is deleted from this table. See [onInsert] for
  /// broadcast/ordering semantics.
  Stream<TableDeleteEvent<T>> get onDelete => _onDeleteController.stream;

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

  bool get isSubscribed => _subscribedCompleter.isCompleted;

  TableCache({
    required this.tableName,
    required this.decoder,
    this.isEvent = false,
  }) : hasPrimaryKey = decoder.hasPrimaryKey;

  @internal
  void markSubscribed() {
    if (!_subscribedCompleter.isCompleted) {
      _subscribedCompleter.complete();
    }
  }

  @internal
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
  @internal
  void applyTransactionUpdate(
    BsatnRowList deletes,
    BsatnRowList inserts,
    EventContext context, {
    Set<dynamic>? protectedKeys,
    bool reconcile = false,
  }) {
    final changes = _applyChanges(
      deletes,
      inserts,
      protectedKeys: protectedKeys,
      reconcile: reconcile,
    );
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
  @internal
  Set<dynamic> applyTransactionUpdateAndCollectKeys(
    BsatnRowList deletes,
    BsatnRowList inserts,
    EventContext context, {
    Set<dynamic>? protectedKeys,
    bool reconcile = false,
    void Function(dynamic primaryKey, Map<String, dynamic>? committedRowJson)?
    onProtectedKeyCommitted,
  }) {
    final changes = _applyChanges(
      deletes,
      inserts,
      protectedKeys: protectedKeys,
      reconcile: reconcile,
      onProtectedKeyCommitted: onProtectedKeyCommitted,
    );
    _emitChanges(changes, context);

    if (isEvent) {
      _rowsByPrimaryKey.clear();
      _rows.clear();
    }

    return changes.touchedKeys;
  }

  @internal
  Set<dynamic> applyServerDelta(
    BsatnRowList deletes,
    BsatnRowList inserts,
    EventContext context, {
    required int querySetId,
    Set<dynamic>? protectedKeys,
    bool reconcile = false,
    bool trackImbalance = true,
    void Function(dynamic primaryKey, Map<String, dynamic>? committedRowJson)?
    onProtectedKeyCommitted,
    void Function(dynamic primaryKey)? onOwnershipGained,
  }) {
    final hadOwnersBefore = <dynamic>{
      for (final pk in inserts.getRows().map(
        (bytes) => decoder.getPrimaryKey(decoder.decode(BsatnDecoder(bytes))),
      ))
        if (pk != null && _rowOwners[pk]?.isNotEmpty == true) pk,
    };

    final changes = _applyChanges(
      deletes,
      inserts,
      protectedKeys: protectedKeys,
      reconcile: reconcile,
      onProtectedKeyCommitted: onProtectedKeyCommitted,
    );

    for (final pk in changes.serverPresentKeys) {
      final owners = _rowOwners.putIfAbsent(pk, () => <int>{});
      if (owners.isEmpty) onOwnershipGained?.call(pk);
      owners.add(querySetId);
      _previousOwners.remove(pk);
    }

    final suppressInsertEvents = <dynamic>{};
    for (final pk in changes.serverPresentKeys) {
      if (hadOwnersBefore.contains(pk)) suppressInsertEvents.add(pk);
    }
    if (suppressInsertEvents.isNotEmpty) {
      changes.inserted.removeWhere((row) {
        final pk = decoder.getPrimaryKey(row);
        return pk != null && suppressInsertEvents.contains(pk);
      });
    }

    final deletedRowValues = <dynamic, T>{
      for (final row in changes.deleted)
        if (decoder.getPrimaryKey(row) != null) decoder.getPrimaryKey(row): row,
    };

    final toEvict = <dynamic>[];
    final surviving = <dynamic>[];
    for (final pk in changes.serverAbsentKeys) {
      _previousOwners.remove(pk);
      final owners = _rowOwners[pk];
      if (owners == null) {
        if (trackImbalance && deletedRowValues.containsKey(pk)) {
          _ownershipImbalanceCount++;
          SdkLogger.w(
            'OWNERSHIP_IMBALANCE[$tableName]: querySetId=$querySetId '
            'reported pk=$pk absent but it has no owner entry',
          );
        }
        continue;
      }
      if (!owners.remove(querySetId) && trackImbalance) {
        _ownershipImbalanceCount++;
        SdkLogger.w(
          'OWNERSHIP_IMBALANCE[$tableName]: querySetId=$querySetId '
          'reported pk=$pk absent but was not among its owners $owners',
        );
      }
      if (owners.isEmpty) {
        _rowOwners.remove(pk);
        toEvict.add(pk);
      } else {
        surviving.add(pk);
      }
    }

    for (final pk in toEvict) {
      if (protectedKeys != null && protectedKeys.contains(pk)) continue;
      _evictRow(pk);
    }

    final suppressDeleteEvents = <dynamic>{};
    for (final pk in surviving) {
      final row = deletedRowValues[pk];
      if (row != null) {
        _rowsByPrimaryKey[pk] = row;
        suppressDeleteEvents.add(pk);
      }
    }
    if (suppressDeleteEvents.isNotEmpty) {
      changes.deleted.removeWhere((row) {
        final pk = decoder.getPrimaryKey(row);
        return pk != null && suppressDeleteEvents.contains(pk);
      });
    }

    _emitChanges(changes, context);

    if (isEvent) {
      _rowsByPrimaryKey.clear();
      _rows.clear();
    }

    return changes.touchedKeys;
  }

  @internal
  Set<dynamic> applySnapshot(
    BsatnRowList inserts,
    EventContext context, {
    required int querySetId,
    Set<dynamic>? protectedKeys,
    bool reconnectInFlight = false,
    int? retainTag,
  }) {
    final changes = _applyChanges(
      BsatnRowList.empty(),
      inserts,
      protectedKeys: protectedKeys,
    );

    final snapshotKeys = changes.serverPresentKeys;

    final toEvict = <dynamic>[];
    for (final entry in _rowOwners.entries.toList()) {
      final pk = entry.key;
      final owners = entry.value;
      if (!owners.contains(querySetId)) continue;
      if (snapshotKeys.contains(pk)) continue;
      owners.remove(querySetId);
      if (owners.isEmpty) {
        _rowOwners.remove(pk);
        if (protectedKeys == null || !protectedKeys.contains(pk)) {
          toEvict.add(pk);
        }
      }
    }

    if (retainTag != null && _retainedTags.isNotEmpty) {
      for (final entry in _retainedTags.entries.toList()) {
        final pk = entry.key;
        final tags = entry.value;
        if (!tags.remove(retainTag)) continue;
        if (tags.isEmpty) _retainedTags.remove(pk);
        if (snapshotKeys.contains(pk)) continue;
        if (tags.isNotEmpty) continue;
        if (_rowOwners.containsKey(pk)) continue;
        if (protectedKeys != null && protectedKeys.contains(pk)) continue;
        toEvict.add(pk);
      }
    }
    _reconcileEvictionCount += toEvict.length;

    for (final pk in snapshotKeys) {
      _rowOwners.putIfAbsent(pk, () => <int>{}).add(querySetId);
      _previousOwners.remove(pk);
    }

    if (!reconnectInFlight) {
      for (final row in _rowsByPrimaryKey.values.toList()) {
        final pk = decoder.getPrimaryKey(row);
        if (pk == null) continue;
        if (snapshotKeys.contains(pk)) continue;
        if (protectedKeys != null && protectedKeys.contains(pk)) continue;
        if (_rowOwners.containsKey(pk)) continue;
        if (_retainedTags.containsKey(pk)) continue;
        toEvict.add(pk);
        _sweepEvictionCount++;
      }
    }

    for (final pk in toEvict) {
      _evictRow(pk);
    }

    _emitChanges(changes, context);
    if (toEvict.isNotEmpty) {
      _refreshRowsNotifier();
      _notifyRowListeners(toEvict);
    }
    return changes.insertedPrimaryKeys;
  }

  @internal
  void dropQuerySet(
    int querySetId, {
    Set<dynamic>? protectedKeys,
    int? retainTag,
  }) {
    final toEvict = <dynamic>[];
    void evictOrRetain(dynamic pk) {
      if (retainTag != null) {
        _retainedTags.putIfAbsent(pk, () => <int>{}).add(retainTag);
        return;
      }
      toEvict.add(pk);
    }

    for (final entry in _rowOwners.entries.toList()) {
      final pk = entry.key;
      final owners = entry.value;
      if (!owners.remove(querySetId)) continue;
      if (owners.isEmpty) {
        _rowOwners.remove(pk);
        if (protectedKeys == null || !protectedKeys.contains(pk)) {
          evictOrRetain(pk);
        }
      }
    }
    for (final entry in _previousOwners.entries.toList()) {
      final pk = entry.key;
      final owners = entry.value;
      if (!owners.remove(querySetId)) continue;
      if (owners.isEmpty) {
        _previousOwners.remove(pk);
        if (!_rowOwners.containsKey(pk) &&
            (protectedKeys == null || !protectedKeys.contains(pk))) {
          evictOrRetain(pk);
        }
      }
    }
    _unsubscribeEvictionCount += toEvict.length;
    for (final pk in toEvict) {
      _evictRow(pk);
    }
    if (toEvict.isNotEmpty) {
      _refreshRowsNotifier();
      _notifyRowListeners(toEvict);
    }
  }

  @internal
  void convertQuerySetToRetainTag(int querySetId, int retainTag) {
    for (final entry in _rowOwners.entries.toList()) {
      final pk = entry.key;
      final owners = entry.value;
      if (!owners.remove(querySetId)) continue;
      if (owners.isEmpty) {
        _rowOwners.remove(pk);
        _retainedTags.putIfAbsent(pk, () => <int>{}).add(retainTag);
      }
    }
    for (final entry in _previousOwners.entries.toList()) {
      final pk = entry.key;
      final owners = entry.value;
      if (!owners.remove(querySetId)) continue;
      if (owners.isEmpty) {
        _previousOwners.remove(pk);
        if (!_rowOwners.containsKey(pk)) {
          _retainedTags.putIfAbsent(pk, () => <int>{}).add(retainTag);
        }
      }
    }
  }

  @internal
  int get ownerEntryCount => _rowOwners.length;

  @internal
  Set<dynamic> ownedKeys(dynamic primaryKey) =>
      _rowOwners[primaryKey] ?? _previousOwners[primaryKey] ?? const {};

  @internal
  int get pendingOwnerEntryCount => _previousOwners.length;

  @internal
  void beginReconnectGeneration() {
    if (_rowOwners.isEmpty) return;
    for (final entry in _rowOwners.entries) {
      final existing = _previousOwners[entry.key];
      if (existing == null) {
        _previousOwners[entry.key] = entry.value;
      } else {
        existing.addAll(entry.value);
      }
    }
    _rowOwners = {};
  }

  @internal
  int finalizeReconnectGeneration({
    Set<dynamic>? protectedKeys,
    bool Function(Set<int> owners)? retainWhere,
  }) {
    if (_previousOwners.isEmpty) return 0;
    final evicted = <dynamic>[];
    for (final entry in _previousOwners.entries) {
      final pk = entry.key;
      if (protectedKeys != null && protectedKeys.contains(pk)) continue;
      if (retainWhere != null && retainWhere(entry.value)) continue;
      evicted.add(pk);
    }
    _previousOwners.clear();
    for (final pk in evicted) {
      _evictRow(pk);
    }
    if (evicted.isNotEmpty) {
      _refreshRowsNotifier();
      _notifyRowListeners(evicted);
    }
    return evicted.length;
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
    return hasPrimaryKey ? _rowsByPrimaryKey.values : _rows.map((e) => e.row);
  }

  @internal
  Set<dynamic> get primaryKeys =>
      hasPrimaryKey ? _rowsByPrimaryKey.keys.toSet() : const {};

  @internal
  void applyDeletes(BsatnRowList deletes) {
    final rowBytes = deletes.getRows();
    for (final bytes in rowBytes) {
      final bsatnDecoder = BsatnDecoder(bytes);
      final row = decoder.decode(bsatnDecoder);
      final primaryKey = decoder.getPrimaryKey(row);
      if (primaryKey != null) {
        _evictRow(primaryKey);
      } else {
        _removeUntaggedNoPkRow(row);
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
    _rowOwners.clear();
    _previousOwners.clear();
    _retainedTags.clear();
    _refreshRowsNotifier();
    if (_rowNotifiers.isNotEmpty) {
      _notifyRowListeners(_rowNotifiers.keys.toList());
    }
  }

  /// Apply initial subscription data with event context
  ///
  /// Called when initial subscription data arrives. Emits events with
  /// SubscribeAppliedEvent so users can distinguish initial load from updates.
  @internal
  Set<dynamic> applyInitialData(
    BsatnRowList inserts,
    EventContext context, {
    Set<dynamic>? protectedKeys,
  }) {
    // Treat initial data as inserts with no deletes
    final changes = _applyChanges(
      BsatnRowList.empty(),
      inserts,
      protectedKeys: protectedKeys,
    );
    _emitChanges(changes, context);
    return changes.insertedPrimaryKeys;
  }

  @internal
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
    _onInsertController.close();
    _onUpdateController.close();
    _onDeleteController.close();
  }

  @internal
  List<Map<String, dynamic>> toSerializable({
    List<Map<String, dynamic>> excludeRows = const [],
    Set<String> excludeRequestIds = const {},
  }) {
    if (!decoder.supportsJsonSerialization) {
      throw UnsupportedError(
        'Table "$tableName" decoder does not support JSON serialization. '
        'Implement toJson() and fromJson() in your RowDecoder.',
      );
    }
    final Iterable<Map<String, dynamic>> all;
    if (hasPrimaryKey) {
      all = _rowsByPrimaryKey.values.map((row) => decoder.toJson(row)!);
    } else {
      all = _rows
          .where(
            (e) =>
                e.requestId == null || !excludeRequestIds.contains(e.requestId),
          )
          .map((e) => decoder.toJson(e.row)!);
    }
    if (excludeRows.isEmpty) return all.toList();
    final remaining = List<Map<String, dynamic>>.of(excludeRows);
    final out = <Map<String, dynamic>>[];
    for (final row in all) {
      final matchIndex = remaining.indexWhere((e) => _jsonEquals(e, row));
      if (matchIndex >= 0) {
        remaining.removeAt(matchIndex);
      } else {
        out.add(row);
      }
    }
    return out;
  }

  @internal
  void loadFromSerializable(List<Map<String, dynamic>> jsonRows) {
    if (!decoder.supportsJsonSerialization) {
      throw UnsupportedError(
        'Table "$tableName" decoder does not support JSON serialization. '
        'Implement toJson() and fromJson() in your RowDecoder.',
      );
    }
    _rowsByPrimaryKey.clear();
    _rows.clear();
    _rowOwners.clear();
    _previousOwners.clear();
    _retainedTags.clear();
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
        _rows.add(_CachedRow(row));
      }
    }
    _refreshRowsNotifier();
    if (_rowNotifiers.isNotEmpty) {
      _notifyRowListeners(_rowNotifiers.keys.toList());
    }
  }

  @internal
  List<Map<String, dynamic>> tagsToSerializable(
    int? Function(int querySetId) resolveQuerySetTag,
  ) {
    final effective = <dynamic, Set<int>>{
      for (final entry in _retainedTags.entries) entry.key: {...entry.value},
    };
    void fold(Map<dynamic, Set<int>> owners) {
      for (final entry in owners.entries) {
        for (final querySetId in entry.value) {
          final tag = resolveQuerySetTag(querySetId);
          if (tag == null) continue;
          effective.putIfAbsent(entry.key, () => <int>{}).add(tag);
        }
      }
    }

    fold(_rowOwners);
    fold(_previousOwners);
    return [
      for (final entry in effective.entries)
        if (_rowsByPrimaryKey.containsKey(entry.key))
          {'pk': entry.key.toString(), 'tags': entry.value.toList()},
    ];
  }

  @internal
  void loadRetainedTags(List<Map<String, dynamic>> tagRows) {
    if (tagRows.isEmpty) return;
    final pksByString = <String, dynamic>{
      for (final pk in _rowsByPrimaryKey.keys) pk.toString(): pk,
    };
    for (final tagRow in tagRows) {
      final pkString = tagRow['pk'];
      final tags = tagRow['tags'];
      if (pkString is! String || tags is! List) continue;
      final pk = pksByString[pkString];
      if (pk == null) continue;
      final parsed = <int>{
        for (final tag in tags)
          if (tag is int) tag,
      };
      if (parsed.isEmpty) continue;
      _retainedTags.putIfAbsent(pk, () => <int>{}).addAll(parsed);
    }
  }

  @internal
  void insertRow(T row, {String? requestId}) {
    final primaryKey = decoder.getPrimaryKey(row);
    if (primaryKey != null) {
      _rowsByPrimaryKey[primaryKey] = row;
    } else {
      _rows.add(_CachedRow(row, requestId: requestId));
    }
    _refreshRowsNotifier();
    if (primaryKey != null && _rowNotifiers.containsKey(primaryKey)) {
      _notifyRowListeners([primaryKey]);
    }
  }

  @internal
  @visibleForTesting
  void insertServerOwnedRow(T row, {int querySetId = 0}) {
    final primaryKey = decoder.getPrimaryKey(row);
    insertRow(row);
    if (primaryKey != null) {
      _rowOwners.putIfAbsent(primaryKey, () => <int>{}).add(querySetId);
    }
  }

  @internal
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

  @internal
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

  @internal
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

  @internal
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

    for (final event in events) {
      switch (event) {
        case TableInsertEvent<T>():
          _onInsertController.add(event);
        case TableUpdateEvent<T>():
          _onUpdateController.add(event);
        case TableDeleteEvent<T>():
          _onDeleteController.add(event);
      }
    }

    lastBatch.value = TransactionBatch<T>(context, events);
  }

  @internal
  void removeRowsWhere(bool Function(dynamic pk) test) {
    final touchedKeys = <dynamic>[];
    if (_rowNotifiers.isNotEmpty) {
      for (final key in _rowNotifiers.keys) {
        if (test(key)) touchedKeys.add(key);
      }
    }
    final matchedKeys = _rowsByPrimaryKey.keys.where(test).toList();
    for (final key in matchedKeys) {
      _rowsByPrimaryKey.remove(key);
      _rowOwners.remove(key);
      _retainedTags.remove(key);
    }
    _rows.removeWhere((entry) {
      final pk = decoder.getPrimaryKey(entry.row);
      return test(pk);
    });
    _refreshRowsNotifier();
    if (touchedKeys.isNotEmpty) {
      _notifyRowListeners(touchedKeys);
    }
  }

  @internal
  void removeNoPkRow(Map<String, dynamic> rowJson, {String? requestId}) {
    if (hasPrimaryKey) return;
    if (requestId != null) {
      final i = _rows.indexWhere((e) => e.requestId == requestId);
      if (i >= 0) {
        _rows.removeAt(i);
        _refreshRowsNotifier();
      }
      return;
    }
    for (var i = 0; i < _rows.length; i++) {
      final asJson = decoder.toJson(_rows[i].row);
      if (asJson != null && _jsonEquals(asJson, rowJson)) {
        _rows.removeAt(i);
        _refreshRowsNotifier();
        return;
      }
    }
  }

  @internal
  void clearNoPkRequestTag(String requestId) {
    if (hasPrimaryKey) return;
    for (final entry in _rows) {
      if (entry.requestId == requestId) entry.requestId = null;
    }
  }

  @internal
  void clearUntaggedNoPkRows() {
    if (hasPrimaryKey) return;
    final before = _rows.length;
    _rows.removeWhere((e) => e.requestId == null);
    if (_rows.length != before) _refreshRowsNotifier();
  }

  void _removeUntaggedNoPkRow(T row) {
    final i = _rows.indexWhere((e) => e.requestId == null && e.row == row);
    if (i >= 0) _rows.removeAt(i);
  }

  bool _jsonEquals(Map<String, dynamic> a, Map<String, dynamic> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (!b.containsKey(entry.key) || b[entry.key] != entry.value) {
        return false;
      }
    }
    return true;
  }

  void _refreshRowsNotifier() {
    rows.value =
        hasPrimaryKey
            ? List<T>.of(_rowsByPrimaryKey.values)
            : _rows.map((e) => e.row).toList();
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

    for (final event in events) {
      switch (event) {
        case TableInsertEvent<T>():
          _onInsertController.add(event);
        case TableUpdateEvent<T>():
          _onUpdateController.add(event);
        case TableDeleteEvent<T>():
          _onDeleteController.add(event);
      }
    }

    if (events.isNotEmpty) {
      lastBatch.value = TransactionBatch<T>(context, events);
    }
  }

  _RowChanges<T> _applyChanges(
    BsatnRowList deletes,
    BsatnRowList inserts, {
    Set<dynamic>? protectedKeys,
    bool reconcile = false,
    void Function(dynamic primaryKey, Map<String, dynamic>? committedRowJson)?
    onProtectedKeyCommitted,
  }) {
    final changes = _RowChanges<T>();
    final oldValues = <dynamic, T>{};
    final pendingDeletes = <(dynamic, T)>[];
    final protectedDeletedKeys = <dynamic>{};
    final protectedInsertedRows = <dynamic, T>{};
    final alreadyGoneKeys = <dynamic>{};

    final deleteBytes = deletes.getRows();
    final insertBytes = inserts.getRows();

    final insertedKeysRaw = <dynamic>{};
    for (final bytes in insertBytes) {
      final primaryKey = decoder.getPrimaryKey(
        decoder.decode(BsatnDecoder(bytes)),
      );
      if (primaryKey != null) insertedKeysRaw.add(primaryKey);
    }
    for (final bytes in deleteBytes) {
      final primaryKey = decoder.getPrimaryKey(
        decoder.decode(BsatnDecoder(bytes)),
      );
      if (primaryKey != null && !insertedKeysRaw.contains(primaryKey)) {
        changes.serverAbsentKeys.add(primaryKey);
      }
    }
    changes.serverPresentKeys.addAll(insertedKeysRaw);

    for (final bytes in deleteBytes) {
      final bsatnDecoder = BsatnDecoder(bytes);
      final row = decoder.decode(bsatnDecoder);
      final primaryKey = decoder.getPrimaryKey(row);
      if (primaryKey != null) {
        if (protectedKeys != null && protectedKeys.contains(primaryKey)) {
          protectedDeletedKeys.add(primaryKey);
          continue;
        }
        changes.touchedKeys.add(primaryKey);
        final old = _rowsByPrimaryKey.remove(primaryKey);
        if (old != null) {
          oldValues[primaryKey] = old;
          pendingDeletes.add((primaryKey, old));
        } else if (!reconcile) {
          pendingDeletes.add((primaryKey, row));
        } else {
          alreadyGoneKeys.add(primaryKey);
        }
      } else {
        _removeUntaggedNoPkRow(row);
        changes.deleted.add(row);
      }
    }

    final coalescedKeys = <dynamic>{};
    for (final bytes in insertBytes) {
      final bsatnDecoder = BsatnDecoder(bytes);
      final row = decoder.decode(bsatnDecoder);
      final primaryKey = decoder.getPrimaryKey(row);

      if (primaryKey != null) {
        if (protectedKeys != null && protectedKeys.contains(primaryKey)) {
          protectedInsertedRows[primaryKey] = row;
          continue;
        }
        changes.touchedKeys.add(primaryKey);
        changes.insertedPrimaryKeys.add(primaryKey);
        alreadyGoneKeys.remove(primaryKey);
        if (oldValues.containsKey(primaryKey)) {
          final old = oldValues[primaryKey] as T;
          if (!(reconcile && old == row)) {
            changes.updated.add((old, row));
          }
          coalescedKeys.add(primaryKey);
        } else if (reconcile) {
          final existing = _rowsByPrimaryKey[primaryKey];
          if (existing == null) {
            changes.inserted.add(row);
            changes.freshInsertedPrimaryKeys.add(primaryKey);
          } else if (existing != row) {
            changes.updated.add((existing, row));
          }
        } else {
          changes.inserted.add(row);
          if (!_rowsByPrimaryKey.containsKey(primaryKey)) {
            changes.freshInsertedPrimaryKeys.add(primaryKey);
          }
        }
        _rowsByPrimaryKey[primaryKey] = row;
      } else {
        changes.inserted.add(row);
        _rows.add(_CachedRow(row));
      }
    }

    for (final (primaryKey, deletedRow) in pendingDeletes) {
      if (!coalescedKeys.contains(primaryKey)) {
        changes.deleted.add(deletedRow);
        changes.removedPrimaryKeys.add(primaryKey);
      }
    }
    changes.removedPrimaryKeys.addAll(alreadyGoneKeys);

    if (onProtectedKeyCommitted != null) {
      for (final entry in protectedInsertedRows.entries) {
        onProtectedKeyCommitted(entry.key, decoder.toJson(entry.value));
      }
      for (final primaryKey in protectedDeletedKeys) {
        if (protectedInsertedRows.containsKey(primaryKey)) continue;
        onProtectedKeyCommitted(primaryKey, null);
      }
    }

    return changes;
  }

  void _evictRow(dynamic primaryKey) {
    _rowsByPrimaryKey.remove(primaryKey);
    _rowOwners.remove(primaryKey);
    _previousOwners.remove(primaryKey);
    _retainedTags.remove(primaryKey);
  }
}

class _CachedRow<T> {
  _CachedRow(this.row, {this.requestId});
  final T row;
  String? requestId;
}

class _RowChanges<T> {
  final List<T> inserted = [];
  final List<T> deleted = [];
  final List<(T, T)> updated = [];
  final Set<dynamic> touchedKeys = {};
  final Set<dynamic> insertedPrimaryKeys = {};
  final Set<dynamic> freshInsertedPrimaryKeys = {};
  final Set<dynamic> removedPrimaryKeys = {};
  final Set<dynamic> serverPresentKeys = {};
  final Set<dynamic> serverAbsentKeys = {};
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
