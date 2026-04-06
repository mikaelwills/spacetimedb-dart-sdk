// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: avoid_print

import 'dart:async';

import 'package:spacetimedb_dart_sdk/spacetimedb_dart_sdk.dart';
import 'reducers.dart';
import 'reducer_args.dart';
import 'note.dart';
import 'folder.dart';

class SpacetimeDbClient {
  final SpacetimeDbConnection connection;
  final SubscriptionManager subscriptions;
  final AuthTokenStore _authStorage;
  final bool _ssl; // Store SSL state for OIDC generation
  late final Reducers reducers;

  /// Access to ReducerEmitter for event-driven patterns
  ReducerEmitter get reducerEmitter => subscriptions.reducerEmitter;

  /// Current user identity (32-byte public key hash)
  ///
  /// Available after connection is established. Returns null before first IdentityToken message.
  ///
  /// Example:
  /// ```dart
  /// // Check ownership
  /// if (note.ownerId == client.identity?.toHexString) {
  ///   // User owns this note
  /// }
  ///
  /// // Display in UI
  /// print("User: ${client.identity?.toAbbreviated}"); // "2ab4...9f1c"
  /// ```
  Identity? get identity => subscriptions.identity;

  /// Current connection address (16-byte connection ID as hex string)
  ///
  /// Available after connection is established. Returns null before first IdentityToken message.
  String? get address => subscriptions.address;

  /// Current authentication token (JWT string)
  ///
  /// Available after connection is established. Returns null if not authenticated.
  String? get token => connection.token;

  /// Whether offline storage is enabled
  bool get hasOfflineStorage => subscriptions.hasOfflineStorage;

  /// Current sync state for offline mutations
  SyncState get syncState => subscriptions.syncState;

  /// Stream of sync state changes
  Stream<SyncState> get onSyncStateChanged => subscriptions.onSyncStateChanged;

  /// Stream of individual mutation sync results
  Stream<MutationSyncResult> get onMutationSyncResult =>
      subscriptions.onMutationSyncResult;

  TableCache<Note> get note {
    return subscriptions.cache.getTableByTypedName<Note>('note');
  }

  TableCache<Folder> get folder {
    return subscriptions.cache.getTableByTypedName<Folder>('folder');
  }

  TableCache<Note> get allNotes {
    return subscriptions.cache.getTableByTypedName<Note>('all_notes');
  }

  /// Access singleton view 'first_note'
  Note? get firstNote {
    final cache = subscriptions.cache.getTableByTypedName<Note>('first_note');
    // Optimization: Don't convert to list, just check the iterator
    final iterator = cache.iter().iterator;
    if (iterator.moveNext()) {
      return iterator.current;
    }
    return null;
  }

  TableCache<Note> get notesQueryAll {
    return subscriptions.cache.getTableByTypedName<Note>('notes_query_all');
  }

  SpacetimeDbClient._({
    required this.connection,
    required this.subscriptions,
    required AuthTokenStore authStorage,
    required bool ssl,
  }) : _authStorage = authStorage,
       _ssl = ssl {
    // Initialize Reducers with ReducerCaller and ReducerEmitter
    reducers = Reducers(subscriptions.reducers, subscriptions.reducerEmitter);
  }

  static Future<SpacetimeDbClient> connect({
    required String host,
    required String database,
    AuthTokenStore? authStorage,
    OfflineStorage? offlineStorage,
    bool ssl = false,
    ConnectionConfig config = const ConnectionConfig(),
    List<String>? initialSubscriptions,
    Duration subscriptionTimeout = const Duration(seconds: 10),
    void Function(SpacetimeDbClient client)? onCacheLoaded,
  }) async {
    // Setup storage (default to in-memory)
    final storage = authStorage ?? InMemoryTokenStore();

    // Try to load existing token
    final savedToken = await storage.loadToken();

    // Connect with token
    final connection = SpacetimeDbConnection(
      host: host,
      database: database,
      initialToken: savedToken,
      ssl: ssl, // Pass SSL config to connection
      config: config, // Pass connection config
    );

    final subscriptionManager = SubscriptionManager(
      connection,
      offlineStorage: offlineStorage,
    );

    // Auto-register table decoders
    subscriptionManager.cache.registerDecoder<Note>('note', NoteDecoder());
    subscriptionManager.cache.registerDecoder<Folder>(
      'folder',
      FolderDecoder(),
    );

    // Auto-register view decoders
    subscriptionManager.cache.registerDecoder<Note>('all_notes', NoteDecoder());
    subscriptionManager.cache.registerDecoder<Note>(
      'first_note',
      NoteDecoder(),
    );
    subscriptionManager.cache.registerDecoder<Note>(
      'notes_query_all',
      NoteDecoder(),
    );

    // Auto-register reducer argument decoders
    subscriptionManager.reducerRegistry.registerDecoder(
      'create_folder',
      CreateFolderArgsDecoder(),
    );
    subscriptionManager.reducerRegistry.registerDecoder(
      'create_note',
      CreateNoteArgsDecoder(),
    );
    subscriptionManager.reducerRegistry.registerDecoder(
      'delete_all_folders',
      DeleteAllFoldersArgsDecoder(),
    );
    subscriptionManager.reducerRegistry.registerDecoder(
      'delete_all_notes',
      DeleteAllNotesArgsDecoder(),
    );
    subscriptionManager.reducerRegistry.registerDecoder(
      'delete_folder',
      DeleteFolderArgsDecoder(),
    );
    subscriptionManager.reducerRegistry.registerDecoder(
      'delete_note',
      DeleteNoteArgsDecoder(),
    );
    subscriptionManager.reducerRegistry.registerDecoder(
      'update_note',
      UpdateNoteArgsDecoder(),
    );

    final client = SpacetimeDbClient._(
      connection: connection,
      subscriptions: subscriptionManager,
      authStorage: storage,
      ssl: ssl,
    );

    // Auto-save new tokens
    subscriptionManager.onIdentityToken.listen((msg) async {
      await storage.saveToken(msg.token);
      connection.updateToken(msg.token);
    });

    // Load cached data before connecting (for offline-first support)
    if (offlineStorage != null) {
      await subscriptionManager.loadFromOfflineCache();
      onCacheLoaded?.call(client);
    }

    // Connect and subscribe - with offline support, this is non-blocking on failure
    try {
      await connection.connect().timeout(config.connectTimeout);
      if (initialSubscriptions != null && initialSubscriptions.isNotEmpty) {
        await subscriptionManager
            .subscribe(initialSubscriptions)
            .timeout(subscriptionTimeout);
      }
    } catch (e) {
      if (offlineStorage != null) {
        // Offline mode: connection failed but we have cached data, continue in offline mode
        print('📴 Connection failed, operating in offline mode: $e');
      } else {
        rethrow;
      }
    }

    return client;
  }

  Future<void> disconnect() async {
    await connection.disconnect();
  }

  /// Logout - clear stored token and disconnect
  ///
  /// This clears the authentication token from storage and disconnects
  /// from the server. On next connect, the server will assign a new
  /// anonymous identity.
  Future<void> logout() async {
    await _authStorage.clearToken();
    await connection.disconnect();
  }

  /// Get authentication URL for OAuth/OIDC provider.
  ///
  /// Example:
  /// ```dart
  /// final url = client.getAuthUrl('google');
  /// await launchUrl(Uri.parse(url)); // Open in browser
  /// ```
  String getAuthUrl(String provider, {String? redirectUri}) {
    final helper = OidcHelper(
      host: connection.host,
      database: connection.database,
      ssl: _ssl, // Uses the captured SSL state
    );
    return helper.getAuthUrl(provider, redirectUri: redirectUri);
  }

  /// Parse token from OAuth callback URL.
  ///
  /// Example:
  /// ```dart
  /// // After user authenticates, your app receives callback:
  /// final token = client.parseTokenFromCallback('myapp://callback?token=abc123');
  /// if (token != null) {
  ///   // Save and reconnect with new token
  /// }
  /// ```
  String? parseTokenFromCallback(String callbackUrl) {
    final helper = OidcHelper(
      host: connection.host,
      database: connection.database,
      ssl: _ssl,
    );
    return helper.parseTokenFromCallback(callbackUrl);
  }
}
