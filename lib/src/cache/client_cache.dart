import 'table_cache.dart';
import 'row_decoder.dart';

/// Builder function that constructs a TableCache with preserved type information
typedef TableCacheBuilder = TableCache Function(int tableId, String tableName);

/// Main cache container for all subscribed tables
///
/// The ClientCache uses a two-phase registration model:
///
/// Phase 1 (Static): Register decoders by table name before connecting
/// Phase 2 (Dynamic): Server sends table metadata, SDK activates tables
///
/// Features:
/// - Name-based decoder registration (no magic numbers)
/// - Runtime table activation when server assigns IDs
/// - Type-safe table access
/// - Automatic row decoding
/// - Real-time synchronization
///
/// Example:
/// ```dart
/// final cache = ClientCache();
///
/// // Phase 1: Register decoders (before connecting)
/// cache.registerDecoder<Note>('note', NoteDecoder());
/// cache.registerDecoder<User>('user', UserDecoder());
///
/// // Phase 2: Happens automatically when subscription arrives
/// // Server sends: TableUpdate { tableId: 100, tableName: 'note', ... }
/// // SDK calls: cache.activateTable(100, 'note')
///
/// // Access cached data (after activation)
/// final noteTable = cache.getTableByTypedName<Note>('note');
/// final note = noteTable.find(42);
///
/// // Iterate all notes
/// for (final note in noteTable.iter()) {
///   print(note.title);
/// }
/// ```
class ClientCache {
  // Phase 1: Static registry - store builder functions that capture type T
  final Map<String, TableCacheBuilder> _builders = {};

  // Phase 2: Runtime storage mapping server table ID → cache
  final Map<int, TableCache> _tables = {};

  // Convenience: Reverse lookup name → server table ID
  final Map<String, int> _nameToId = {};

  final Set<String> _eventTableNames = {};

  /// Register a decoder for a table or view (Phase 1: Static Registration).
  ///
  /// Call this before connecting to declare: "I know how to decode table X".
  /// The table won't be accessible until the server activates it during subscription.
  ///
  /// Uses the Factory/Builder Pattern to preserve type information through closures.
  /// The builder function captures the specific type T at registration time.
  ///
  /// - [tableName]: The table/view name as defined in your SpacetimeDB module
  /// - [decoder]: The row decoder that knows how to deserialize rows
  ///
  /// Example:
  /// ```dart
  /// cache.registerDecoder<Note>('note', NoteDecoder());
  /// cache.registerDecoder<Note>('all_notes', NoteDecoder()); // View using same type
  /// ```
  bool isEventTable(String tableName) => _eventTableNames.contains(tableName);

  void registerDecoder<T>(
    String tableName,
    RowDecoder<T> decoder, {
    bool isEvent = false,
  }) {
    if (_builders.containsKey(tableName)) {
      throw ArgumentError('Decoder for "$tableName" is already registered');
    }
    if (isEvent) {
      _eventTableNames.add(tableName);
    }
    _builders[tableName] = (int tableId, String name) {
      return TableCache<T>(
        tableId: tableId,
        tableName: name,
        decoder: decoder,
        isEvent: isEvent,
      );
    };
  }

  /// Activate a table with runtime server ID (Phase 2: Dynamic Activation).
  ///
  /// Called automatically by SubscriptionManager when server sends table metadata.
  /// Invokes the builder function to construct a TableCache with preserved type.
  ///
  /// Gracefully ignores tables without registered builders (e.g., when user
  /// subscribes to tables not in the generated code).
  ///
  /// - [tableId]: Runtime table ID assigned by server
  /// - [tableName]: Table name from server
  ///
  /// Throws if table ID already activated for a different table.
  void activateTable(int tableId, String tableName) {
    // Check if this ID is already used
    if (_tables.containsKey(tableId)) {
      final existing = _nameToId.entries.firstWhere((e) => e.value == tableId);
      if (existing.key != tableName) {
        throw ArgumentError(
          'Table ID $tableId already activated for "${existing.key}", '
          'cannot activate for "$tableName"',
        );
      }
      // Already activated for this exact table, ignore
      return;
    }

    // Find the registered builder
    final builder = _builders[tableName];
    if (builder == null) {
      // Server sent data for a table we don't know about - this is fine, ignore it
      return;
    }

    // Invoke the builder to create the typed TableCache
    // The builder returns TableCache<T> (preserving the specific type from registration)
    final tableCache = builder(tableId, tableName);

    _tables[tableId] = tableCache;
    _nameToId[tableName] = tableId;
  }

  /// Get a typed table cache by table ID.
  ///
  /// Throws [ArgumentError] if the table is not registered.
  ///
  /// Example:
  /// ```dart
  /// final players = cache.getTable<Player>(16);
  /// final count = players.count();
  /// ```
  TableCache<T> getTable<T>(int tableId) {
    final table = _tables[tableId];
    if (table == null) {
      throw ArgumentError('Table $tableId not found in cache.');
    }
    if (table is! TableCache<T>) {
      // 2. The Descriptive Error: Use standard Dart StateError
      throw StateError(
        "Type Mismatch: You requested TableCache<$T> for table '$tableId', "
        "but the active cache is ${table.runtimeType}. "
        "Ensure you are using the correct generated class for this table.",
      );
    }

    // 3. Safe Return: We know 100% this will not crash now.
    return table;
  }

  /// Get a typed table cache by table name.
  ///
  /// This is the primary accessor for getting table data. Use this after
  /// registering decoders and subscribing to tables.
  ///
  /// Throws [ArgumentError] if the table is not activated (either not registered
  /// or not yet subscribed to).
  ///
  /// Example:
  /// ```dart
  /// final noteCache = cache.getTableByTypedName<Note>('note');
  /// for (final note in noteCache.iter()) {
  ///   print(note.title);
  /// }
  /// ```
  TableCache<T> getTableByTypedName<T>(String tableName) {
    final tableId = _nameToId[tableName];
    if (tableId == null) {
      throw ArgumentError(
        'Table "$tableName" is not active. Did you subscribe to it?\n'
        'Builder registered: ${_builders.containsKey(tableName)}',
      );
    }

    final table = _tables[tableId]!;
    if (table is! TableCache<T>) {
      throw StateError(
        "Type Mismatch: You requested TableCache<$T> for table '$tableName', "
        "but the active cache is ${table.runtimeType}. "
        "Ensure you are using the correct generated class for this table.",
      );
    }

    return table;
  }

  /// Check if a table is registered by ID.
  bool hasTable(int tableId) => _tables.containsKey(tableId);

  /// Check if a table is activated by name.
  bool hasTableByName(String tableName) => _nameToId.containsKey(tableName);

  /// Check if a builder is registered for a table name.
  bool hasBuilder(String tableName) => _builders.containsKey(tableName);

  /// Activate an empty table by name only (for when server returns no rows).
  ///
  /// When a subscribed table has no rows, the server doesn't include it in
  /// the InitialSubscription's tableUpdates. This method allows activating
  /// such tables so they're accessible via getTableByTypedName().
  ///
  /// Uses a synthetic table ID (negative) since we don't have the server's ID.
  /// The table will be re-activated with the real ID if data arrives later.
  ///
  /// - [tableName]: The table name to activate
  ///
  /// Returns true if table was activated, false if already active or no builder.
  bool activateEmptyTable(String tableName) {
    // Already activated
    if (_nameToId.containsKey(tableName)) {
      return false;
    }

    // No builder registered for this table
    final builder = _builders[tableName];
    if (builder == null) {
      return false;
    }

    // Use a synthetic negative table ID for empty tables
    // These will be replaced with real IDs when data arrives
    final syntheticId = -(_nameToId.length + 1);

    final tableCache = builder(syntheticId, tableName);
    _tables[syntheticId] = tableCache;
    _nameToId[tableName] = syntheticId;

    return true;
  }

  /// Link a table that was activated by name to its real server table ID.
  ///
  /// When an empty table receives its first data via TransactionUpdate,
  /// we need to update our mappings to use the real server ID.
  ///
  /// Returns the TableCache if linking was successful or table already exists.
  /// Returns null if the table name wasn't found.
  TableCache? linkTableId(int tableId, String tableName) {
    if (_tables.containsKey(tableId)) {
      return _tables[tableId];
    }

    final existingId = _nameToId[tableName];
    if (existingId != null && existingId != tableId) {
      final table = _tables.remove(existingId);
      if (table != null) {
        _tables[tableId] = table;
        _nameToId[tableName] = tableId;
        return table;
      }
    }

    activateTable(tableId, tableName);
    return _tables[tableId];
  }

  /// Get all registered table IDs.
  Iterable<int> get tableIds => _tables.keys;

  /// Get all registered builder names (tables that have decoders registered).
  Iterable<String> get registeredTableNames => _builders.keys;

  /// Get the number of registered tables.
  int get tableCount => _tables.length;

  /// Clear all tables and their data.
  ///
  /// This removes all cached rows but keeps table registrations.
  /// Use this when disconnecting or resetting the cache.
  void clearAll() {
    for (final table in _tables.values) {
      table.clear();
    }
  }

  /// Unregister a table.
  ///
  /// This removes the table registration and all its cached data.
  void unregisterTable(int tableId) {
    _tables.remove(tableId);
  }

  void unregisterAll() {
    _tables.clear();
  }

  Map<String, List<Map<String, dynamic>>> serializeAllTables() {
    final result = <String, List<Map<String, dynamic>>>{};
    for (final entry in _nameToId.entries) {
      final tableName = entry.key;
      final tableId = entry.value;
      final table = _tables[tableId];
      if (table != null && table.decoder.supportsJsonSerialization) {
        result[tableName] = table.toSerializable();
      }
    }
    return result;
  }

  void loadSerializedTables(Map<String, List<Map<String, dynamic>>> data) {
    for (final entry in data.entries) {
      final tableName = entry.key;
      final rows = entry.value;
      final tableId = _nameToId[tableName];
      if (tableId != null) {
        final table = _tables[tableId];
        if (table != null && table.decoder.supportsJsonSerialization) {
          table.loadFromSerializable(rows);
        }
      }
    }
  }

  List<String> get activatedTableNames => _nameToId.keys.toList();

  TableCache? getTableByName(String tableName) {
    final tableId = _nameToId[tableName];
    if (tableId == null) return null;
    return _tables[tableId];
  }

  Iterable<TableCache> get allTables => _tables.values;
}
