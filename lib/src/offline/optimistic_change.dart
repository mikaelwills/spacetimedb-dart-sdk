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

  Map<String, dynamic> toJson() => {
    'tableName': tableName,
    'type': type.name,
    'oldRowJson': oldRowJson,
    'newRowJson': newRowJson,
  };

  factory OptimisticChange.fromJson(Map<String, dynamic> json) {
    final type = OptimisticChangeType.values.byName(json['type'] as String);
    final tableName = json['tableName'] as String;
    final oldRowJson = json['oldRowJson'] as Map<String, dynamic>?;
    final newRowJson = json['newRowJson'] as Map<String, dynamic>?;

    switch (type) {
      case OptimisticChangeType.insert:
        return OptimisticChange.insert(tableName, newRowJson!);
      case OptimisticChangeType.update:
        return OptimisticChange.update(tableName, oldRowJson!, newRowJson!);
      case OptimisticChangeType.delete:
        return OptimisticChange.delete(tableName, oldRowJson!);
    }
  }
}
