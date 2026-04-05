import 'package:spacetimedb_dart_sdk/src/codegen/models.dart';
import 'package:spacetimedb_dart_sdk/src/codegen/view_generator.dart';

/// Generates main client class
class ClientGenerator {
  final DatabaseSchema schema;
  late final ViewGenerator _viewGenerator;

  ClientGenerator(this.schema) {
    _viewGenerator = ViewGenerator(schema);
  }

  /// Generate client class
  String generate() {
    final buf = StringBuffer();

    // Header
    buf.writeln('// GENERATED CODE - DO NOT MODIFY BY HAND');
    buf.writeln('// ignore_for_file: avoid_print');
    buf.writeln();
    buf.writeln("import 'dart:async';");
    buf.writeln();
    buf.writeln(
      "import 'package:spacetimedb_dart_sdk/spacetimedb_dart_sdk.dart';",
    );
    buf.writeln("import 'reducers.dart';");
    if (schema.reducers.isNotEmpty) {
      buf.writeln("import 'reducer_args.dart';");
    }

    // Import all table files
    for (final table in schema.tables) {
      buf.writeln("import '${table.name}.dart';");
    }
    buf.writeln();

    // Client class name (always SpacetimeDbClient for consistency)
    const clientName = 'SpacetimeDbClient';

    buf.writeln('class $clientName {');
    buf.writeln('  final SpacetimeDbConnection connection;');
    buf.writeln('  final SubscriptionManager subscriptions;');
    buf.writeln('  final AuthTokenStore _authStorage;');
    buf.writeln('  final bool _ssl; // Store SSL state for OIDC generation');
    buf.writeln('  late final Reducers reducers;');
    buf.writeln();
    buf.writeln('  /// Access to ReducerEmitter for event-driven patterns');
    buf.writeln(
      '  ReducerEmitter get reducerEmitter => subscriptions.reducerEmitter;',
    );
    buf.writeln();
    buf.writeln('  /// Current user identity (32-byte public key hash)');
    buf.writeln('  ///');
    buf.writeln(
      '  /// Available after connection is established. Returns null before first IdentityToken message.',
    );
    buf.writeln('  ///');
    buf.writeln('  /// Example:');
    buf.writeln('  /// ```dart');
    buf.writeln('  /// // Check ownership');
    buf.writeln('  /// if (note.ownerId == client.identity?.toHexString) {');
    buf.writeln('  ///   // User owns this note');
    buf.writeln('  /// }');
    buf.writeln('  ///');
    buf.writeln('  /// // Display in UI');
    buf.writeln(
      r'  /// print("User: ${client.identity?.toAbbreviated}"); // "2ab4...9f1c"',
    );
    buf.writeln('  /// ```');
    buf.writeln('  Identity? get identity => subscriptions.identity;');
    buf.writeln();
    buf.writeln(
      '  /// Current connection address (16-byte connection ID as hex string)',
    );
    buf.writeln('  ///');
    buf.writeln(
      '  /// Available after connection is established. Returns null before first IdentityToken message.',
    );
    buf.writeln('  String? get address => subscriptions.address;');
    buf.writeln();
    buf.writeln('  /// Current authentication token (JWT string)');
    buf.writeln('  ///');
    buf.writeln(
      '  /// Available after connection is established. Returns null if not authenticated.',
    );
    buf.writeln('  String? get token => connection.token;');
    buf.writeln();
    buf.writeln('  /// Whether offline storage is enabled');
    buf.writeln(
      '  bool get hasOfflineStorage => subscriptions.hasOfflineStorage;',
    );
    buf.writeln();
    buf.writeln('  /// Current sync state for offline mutations');
    buf.writeln('  SyncState get syncState => subscriptions.syncState;');
    buf.writeln();
    buf.writeln('  /// Stream of sync state changes');
    buf.writeln(
      '  Stream<SyncState> get onSyncStateChanged => subscriptions.onSyncStateChanged;',
    );
    buf.writeln();
    buf.writeln('  /// Stream of individual mutation sync results');
    buf.writeln(
      '  Stream<MutationSyncResult> get onMutationSyncResult => subscriptions.onMutationSyncResult;',
    );
    buf.writeln();

    // Table cache getters
    for (final table in schema.tables) {
      final tableName = _toCamelCase(table.name);
      final className = _toPascalCase(table.name);
      buf.writeln('  TableCache<$className> get $tableName {');
      buf.writeln(
        "    return subscriptions.cache.getTableByTypedName<$className>('${table.name}');",
      );
      buf.writeln('  }');
      buf.writeln();
    }

    // View cache getters (views that return table rows)
    for (final view in schema.views) {
      final rowType = _viewGenerator.getViewRowType(view);
      if (rowType != null) {
        final viewName = _toCamelCase(view.name);
        final pattern = _viewGenerator.getViewReturnPattern(view);

        switch (pattern) {
          case ViewReturnType.array:
            // Vec<T> - returns TableCache<T>
            buf.writeln('  TableCache<$rowType> get $viewName {');
            buf.writeln(
              "    return subscriptions.cache.getTableByTypedName<$rowType>('${view.name}');",
            );
            buf.writeln('  }');
            break;

          case ViewReturnType.option:
            // Option<T> - returns T? (single optional row)
            buf.writeln('  /// Access singleton view \'${view.name}\'');
            buf.writeln('  $rowType? get $viewName {');
            buf.writeln(
              "    final cache = subscriptions.cache.getTableByTypedName<$rowType>('${view.name}');",
            );
            buf.writeln(
              '    // Optimization: Don\'t convert to list, just check the iterator',
            );
            buf.writeln('    final iterator = cache.iter().iterator;');
            buf.writeln('    if (iterator.moveNext()) {');
            buf.writeln('      return iterator.current;');
            buf.writeln('    }');
            buf.writeln('    return null;');
            buf.writeln('  }');
            break;

          case ViewReturnType.single:
            // T - returns T (single row, non-optional)
            buf.writeln('  $rowType get $viewName {');
            buf.writeln(
              "    final cache = subscriptions.cache.getTableByTypedName<$rowType>('${view.name}');",
            );
            buf.writeln('    return cache.iter().first;');
            buf.writeln('  }');
            break;

          case ViewReturnType.unknown:
            // Skip unknown patterns
            continue;
        }
        buf.writeln();
      }
    }

    // Constructor
    buf.writeln('  $clientName._({');
    buf.writeln('    required this.connection,');
    buf.writeln('    required this.subscriptions,');
    buf.writeln('    required AuthTokenStore authStorage,');
    buf.writeln('    required bool ssl,');
    buf.writeln('  })  : _authStorage = authStorage,');
    buf.writeln('        _ssl = ssl {');
    buf.writeln(
      '    // Initialize Reducers with ReducerCaller and ReducerEmitter',
    );
    buf.writeln(
      '    reducers = Reducers(subscriptions.reducers, subscriptions.reducerEmitter);',
    );
    buf.writeln('  }');
    buf.writeln();

    // Static connect method
    buf.writeln('  static Future<$clientName> connect({');
    buf.writeln('    required String host,');
    buf.writeln('    required String database,');
    buf.writeln('    AuthTokenStore? authStorage,');
    buf.writeln('    OfflineStorage? offlineStorage,');
    buf.writeln('    bool ssl = false,');
    buf.writeln('    ConnectionConfig config = const ConnectionConfig(),');
    buf.writeln('    List<String>? initialSubscriptions,');
    buf.writeln(
      '    Duration subscriptionTimeout = const Duration(seconds: 10),',
    );
    buf.writeln('    void Function($clientName client)? onCacheLoaded,');
    buf.writeln('  }) async {');
    buf.writeln('    // Setup storage (default to in-memory)');
    buf.writeln('    final storage = authStorage ?? InMemoryTokenStore();');
    buf.writeln();
    buf.writeln('    // Try to load existing token');
    buf.writeln('    final savedToken = await storage.loadToken();');
    buf.writeln();
    buf.writeln('    // Connect with token');
    buf.writeln("    final connection = SpacetimeDbConnection(");
    buf.writeln('      host: host,');
    buf.writeln('      database: database,');
    buf.writeln('      initialToken: savedToken,');
    buf.writeln('      ssl: ssl, // Pass SSL config to connection');
    buf.writeln('      config: config, // Pass connection config');
    buf.writeln('    );');
    buf.writeln();
    buf.writeln(
      '    final subscriptionManager = SubscriptionManager(connection, offlineStorage: offlineStorage);',
    );
    buf.writeln();

    // Auto-register table decoders (Phase 1: Static Registration)
    buf.writeln('    // Auto-register table decoders');
    for (final table in schema.tables) {
      final className = _toPascalCase(table.name);
      final eventArg = table.isEvent ? ', isEvent: true' : '';
      buf.writeln(
        "    subscriptionManager.cache.registerDecoder<$className>('${table.name}', ${className}Decoder()$eventArg);",
      );
    }
    buf.writeln();

    // Auto-register view decoders (Phase 1: Static Registration)
    buf.writeln('    // Auto-register view decoders');
    for (final view in schema.views) {
      final rowType = _viewGenerator.getViewRowType(view);
      if (rowType != null) {
        buf.writeln(
          "    subscriptionManager.cache.registerDecoder<$rowType>('${view.name}', ${rowType}Decoder());",
        );
      }
    }
    buf.writeln();

    // Auto-register reducer arg decoders (Phase 5: Transaction Support)
    if (schema.reducers.isNotEmpty) {
      buf.writeln('    // Auto-register reducer argument decoders');
      for (final reducer in schema.reducers) {
        final reducerClassName = _toPascalCase(reducer.name);
        buf.writeln(
          "    subscriptionManager.reducerRegistry.registerDecoder('${reducer.name}', ${reducerClassName}ArgsDecoder());",
        );
      }
      buf.writeln();
    }

    buf.writeln('    final client = $clientName._(');
    buf.writeln('      connection: connection,');
    buf.writeln('      subscriptions: subscriptionManager,');
    buf.writeln('      authStorage: storage,');
    buf.writeln('      ssl: ssl,');
    buf.writeln('    );');
    buf.writeln();
    buf.writeln('    // Auto-save new tokens');
    buf.writeln('    subscriptionManager.onIdentityToken.listen((msg) async {');
    buf.writeln('      await storage.saveToken(msg.token);');
    buf.writeln('      connection.updateToken(msg.token);');
    buf.writeln('    });');
    buf.writeln();
    buf.writeln(
      '    // Load cached data before connecting (for offline-first support)',
    );
    buf.writeln('    if (offlineStorage != null) {');
    buf.writeln('      await subscriptionManager.loadFromOfflineCache();');
    buf.writeln('      onCacheLoaded?.call(client);');
    buf.writeln('    }');
    buf.writeln();
    buf.writeln(
      '    // Connect and subscribe - with offline support, this is non-blocking on failure',
    );
    buf.writeln('    try {');
    buf.writeln(
      '      await connection.connect().timeout(config.connectTimeout);',
    );
    buf.writeln(
      '      if (initialSubscriptions != null && initialSubscriptions.isNotEmpty) {',
    );
    buf.writeln(
      '        await subscriptionManager.subscribe(initialSubscriptions).timeout(subscriptionTimeout);',
    );
    buf.writeln('      }');
    buf.writeln('    } catch (e) {');
    buf.writeln('      if (offlineStorage != null) {');
    buf.writeln(
      "        // Offline mode: connection failed but we have cached data, continue in offline mode",
    );
    buf.writeln(
      "        print('📴 Connection failed, operating in offline mode: \$e');",
    );
    buf.writeln('      } else {');
    buf.writeln('        rethrow;');
    buf.writeln('      }');
    buf.writeln('    }');
    buf.writeln();
    buf.writeln('    return client;');
    buf.writeln('  }');
    buf.writeln();

    // Disconnect method
    buf.writeln('  Future<void> disconnect() async {');
    buf.writeln('    await connection.disconnect();');
    buf.writeln('  }');
    buf.writeln();
    buf.writeln('  /// Logout - clear stored token and disconnect');
    buf.writeln('  ///');
    buf.writeln(
      '  /// This clears the authentication token from storage and disconnects',
    );
    buf.writeln(
      '  /// from the server. On next connect, the server will assign a new',
    );
    buf.writeln('  /// anonymous identity.');
    buf.writeln('  Future<void> logout() async {');
    buf.writeln('    await _authStorage.clearToken();');
    buf.writeln('    await connection.disconnect();');
    buf.writeln('  }');
    buf.writeln();
    buf.writeln('  /// Get authentication URL for OAuth/OIDC provider.');
    buf.writeln('  ///');
    buf.writeln('  /// Example:');
    buf.writeln('  /// ```dart');
    buf.writeln("  /// final url = client.getAuthUrl('google');");
    buf.writeln('  /// await launchUrl(Uri.parse(url)); // Open in browser');
    buf.writeln('  /// ```');
    buf.writeln(
      '  String getAuthUrl(String provider, {String? redirectUri}) {',
    );
    buf.writeln('    final helper = OidcHelper(');
    buf.writeln('      host: connection.host,');
    buf.writeln('      database: connection.database,');
    buf.writeln('      ssl: _ssl, // Uses the captured SSL state');
    buf.writeln('    );');
    buf.writeln(
      '    return helper.getAuthUrl(provider, redirectUri: redirectUri);',
    );
    buf.writeln('  }');
    buf.writeln();
    buf.writeln('  /// Parse token from OAuth callback URL.');
    buf.writeln('  ///');
    buf.writeln('  /// Example:');
    buf.writeln('  /// ```dart');
    buf.writeln(
      '  /// // After user authenticates, your app receives callback:',
    );
    buf.writeln(
      "  /// final token = client.parseTokenFromCallback('myapp://callback?token=abc123');",
    );
    buf.writeln('  /// if (token != null) {');
    buf.writeln('  ///   // Save and reconnect with new token');
    buf.writeln('  /// }');
    buf.writeln('  /// ```');
    buf.writeln('  String? parseTokenFromCallback(String callbackUrl) {');
    buf.writeln('    final helper = OidcHelper(');
    buf.writeln('      host: connection.host,');
    buf.writeln('      database: connection.database,');
    buf.writeln('      ssl: _ssl,');
    buf.writeln('    );');
    buf.writeln('    return helper.parseTokenFromCallback(callbackUrl);');
    buf.writeln('  }');
    buf.writeln('}');

    return buf.toString();
  }

  String _toPascalCase(String input) {
    return input
        .split('_')
        .map((word) {
          return word[0].toUpperCase() + word.substring(1).toLowerCase();
        })
        .join('');
  }

  String _toCamelCase(String input) {
    final parts = input.split('_');
    if (parts.isEmpty) return input;

    return parts[0].toLowerCase() +
        parts
            .skip(1)
            .map((word) {
              return word[0].toUpperCase() + word.substring(1).toLowerCase();
            })
            .join('');
  }
}
