import 'package:spacetimedb_sdk/src/cache/table_cache.dart';

enum OptimisticChangeType { insert, update, delete }

/// Represents a change to be applied optimistically to the local cache.
///
/// Optimistic changes allow the UI to update immediately while the server
/// processes the request. When the server responds, the change is either
/// confirmed (kept) or rolled back (reverted).
///
/// ## ID Generation Requirement
///
/// **Important**: Optimistic inserts require client-side ID generation (e.g., UUIDs).
///
/// If you use server-generated IDs (e.g., auto-increment), the optimistic row
/// will have a temporary ID that differs from the server-assigned ID. This results
/// in duplicate rows (temp + real) because the SDK cannot automatically map
/// temporary IDs to server-assigned IDs.
///
/// ```dart
/// // ✅ CORRECT: Client-side UUID
/// final id = Uuid().v4();
/// await client.reducers.createNote(
///   id: id,
///   content: 'Hello',
///   optimisticChanges: [OptimisticChange.insert('note', {'id': id, 'content': 'Hello'})],
/// );
///
/// // ❌ PROBLEMATIC: Server-generated ID
/// // The optimistic row uses a temp ID, but the server assigns a different ID.
/// // You'll end up with both rows in the cache.
/// ```
///
/// Updates and deletes work with any ID strategy since the row already exists.
class OptimisticChange {
  final String tableName;
  final OptimisticChangeType type;
  final Map<String, dynamic>? oldRowJson;
  final Map<String, dynamic>? newRowJson;

  OptimisticChange.insert(this.tableName, Map<String, dynamic> row)
    : type = OptimisticChangeType.insert,
      oldRowJson = null,
      newRowJson = row;

  OptimisticChange.update(
    this.tableName,
    Map<String, dynamic> oldRow,
    Map<String, dynamic> newRow,
  ) : type = OptimisticChangeType.update,
      oldRowJson = oldRow,
      newRowJson = newRow;

  OptimisticChange.delete(this.tableName, Map<String, dynamic> row)
    : type = OptimisticChangeType.delete,
      oldRowJson = row,
      newRowJson = null;

  /// Build an insert change from a typed row. The SDK extracts the table
  /// name and serializes the row via the decoder — no hand-typed map and
  /// no stringly-typed table name.
  ///
  /// ```dart
  /// optimisticChanges: [
  ///   OptimisticChange.insertRow(client.note, Note(id: tempId, title: 'Hi', body: 'there')),
  /// ],
  /// ```
  ///
  /// Throws [UnsupportedError] if the decoder does not implement `toJson`
  /// (regenerate the table decoder to add it).
  static OptimisticChange insertRow<T>(TableCache<T> table, T row) {
    return OptimisticChange.insert(table.tableName, _requireJson(table, row));
  }

  /// Build an update change from two typed rows (old + new).
  static OptimisticChange updateRow<T>(
    TableCache<T> table,
    T oldRow,
    T newRow,
  ) {
    return OptimisticChange.update(
      table.tableName,
      _requireJson(table, oldRow),
      _requireJson(table, newRow),
    );
  }

  /// Build a delete change from a typed row.
  static OptimisticChange deleteRow<T>(TableCache<T> table, T row) {
    return OptimisticChange.delete(table.tableName, _requireJson(table, row));
  }

  Map<String, dynamic> toJson() => {
    'tableName': tableName,
    'type': type.name,
    'oldRowJson': oldRowJson,
    'newRowJson': newRowJson,
  };

  factory OptimisticChange.fromJson(Map<String, dynamic> json) {
    final String typeName = json['type'] ?? '';
    final String tableName = json['tableName'] ?? '';
    final Map<String, dynamic>? oldRowJson = json['oldRowJson'];
    final Map<String, dynamic>? newRowJson = json['newRowJson'];

    if (typeName.isEmpty || tableName.isEmpty) {
      throw FormatException('Invalid OptimisticChange JSON: $json');
    }

    final type = OptimisticChangeType.values.byName(typeName);
    switch (type) {
      case OptimisticChangeType.insert:
        if (newRowJson == null) {
          throw FormatException('Insert missing newRowJson: $json');
        }
        return OptimisticChange.insert(tableName, newRowJson);
      case OptimisticChangeType.update:
        if (oldRowJson == null || newRowJson == null) {
          throw FormatException('Update missing old/newRowJson: $json');
        }
        return OptimisticChange.update(tableName, oldRowJson, newRowJson);
      case OptimisticChangeType.delete:
        if (oldRowJson == null) {
          throw FormatException('Delete missing oldRowJson: $json');
        }
        return OptimisticChange.delete(tableName, oldRowJson);
    }
  }

  static Map<String, dynamic> _requireJson<T>(TableCache<T> table, T row) {
    final json = table.decoder.toJson(row);
    if (json == null) {
      throw UnsupportedError(
        'Table "${table.tableName}" decoder does not implement toJson. '
        'Regenerate with a current codegen to enable typed optimistic changes, '
        'or use OptimisticChange.insert/update/delete with a raw Map.',
      );
    }
    return json;
  }
}

/// Generate a client-side temporary integer primary key for optimistic
/// inserts. Returns a negative microsecond-timestamp so it cannot collide
/// with server-assigned positive IDs.
///
/// For UUID / String primary keys, use `Uuid().v4()` or your own scheme
/// instead.
///
/// ```dart
/// final tempId = nextOptimisticIntId();
/// await client.reducers.createNote(
///   title: 'Hi',
///   body: 'there',
///   optimisticChanges: [
///     OptimisticChange.insertRow(client.note, Note(id: tempId, title: 'Hi', body: 'there')),
///   ],
/// );
/// ```
int nextOptimisticIntId() => -DateTime.now().microsecondsSinceEpoch;
