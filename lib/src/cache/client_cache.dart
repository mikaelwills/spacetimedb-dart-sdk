import 'table_cache.dart';
import 'row_decoder.dart';

/// Main cache container for all subscribed tables.
///
/// Tables are created eagerly when their decoder is registered via
/// [registerDecoder]. The primary key is the table name — `tableId` is a
/// protocol-layer concern only and never leaves the message-decoding layer.
///
/// Example:
/// ```dart
/// final cache = ClientCache();
///
/// cache.registerDecoder<Note>('note', NoteDecoder());
/// cache.registerDecoder<User>('user', UserDecoder());
///
/// final noteTable = cache.getTableByTypedName<Note>('note');
/// final note = noteTable.find(42);
///
/// for (final note in noteTable.iter()) {
///   print(note.title);
/// }
/// ```
class ClientCache {
  final Map<String, TableCache> _tables = {};
  final Set<String> _eventTableNames = {};

  bool isEventTable(String tableName) => _eventTableNames.contains(tableName);

  /// Register a decoder for a table or view.
  ///
  /// Creates an empty [TableCache] for [tableName] immediately. The cache
  /// remains the same instance for the lifetime of this [ClientCache], so
  /// stream listeners attached before the first server snapshot continue to
  /// receive events after data arrives.
  ///
  /// Throws [ArgumentError] if a decoder is already registered for
  /// [tableName].
  void registerDecoder<T>(
    String tableName,
    RowDecoder<T> decoder, {
    bool isEvent = false,
  }) {
    if (_tables.containsKey(tableName)) {
      throw ArgumentError('Decoder for "$tableName" is already registered');
    }
    if (isEvent) {
      _eventTableNames.add(tableName);
    }
    _tables[tableName] = TableCache<T>(
      tableName: tableName,
      decoder: decoder,
      isEvent: isEvent,
    );
  }

  /// Get a typed table cache by table name.
  ///
  /// Returns a table with zero rows if the decoder was registered but no
  /// data has arrived yet. Throws [ArgumentError] if no decoder was
  /// registered for [tableName].
  TableCache<T> getTableByTypedName<T>(String tableName) {
    final table = _tables[tableName];
    if (table == null) {
      throw ArgumentError(
        'Table "$tableName" has no registered decoder. '
        'Call registerDecoder<$T>("$tableName", ...) before accessing it.',
      );
    }
    if (table is! TableCache<T>) {
      throw StateError(
        "Type Mismatch: You requested TableCache<$T> for table '$tableName', "
        "but the active cache is ${table.runtimeType}. "
        "Ensure you are using the correct generated class for this table.",
      );
    }
    return table;
  }

  /// Get a table cache by name without enforcing a type parameter.
  ///
  /// Returns null if no decoder is registered for [tableName].
  TableCache? getTableByName(String tableName) => _tables[tableName];

  /// Whether a decoder has been registered for [tableName].
  bool hasBuilder(String tableName) => _tables.containsKey(tableName);

  /// Names of all tables with registered decoders.
  Iterable<String> get registeredTableNames => _tables.keys;

  /// Names of all tables with registered decoders.
  ///
  /// Kept for API compatibility with the old two-phase model where
  /// "registered" and "activated" were distinct states. They are now the
  /// same thing.
  List<String> get activatedTableNames => _tables.keys.toList();

  /// All table caches in the registry.
  Iterable<TableCache> get allTables => _tables.values;

  /// Number of registered tables.
  int get tableCount => _tables.length;

  /// Clear all cached rows while keeping registrations intact.
  void clearAll() {
    for (final table in _tables.values) {
      table.clear();
    }
  }

  Map<String, List<Map<String, dynamic>>> serializeAllTables() {
    final result = <String, List<Map<String, dynamic>>>{};
    for (final entry in _tables.entries) {
      final table = entry.value;
      if (table.decoder.supportsJsonSerialization) {
        result[entry.key] = table.toSerializable();
      }
    }
    return result;
  }

  void loadSerializedTables(Map<String, List<Map<String, dynamic>>> data) {
    for (final entry in data.entries) {
      final table = _tables[entry.key];
      if (table != null && table.decoder.supportsJsonSerialization) {
        table.loadFromSerializable(entry.value);
      }
    }
  }
}
