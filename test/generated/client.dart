// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: avoid_print

import 'dart:async';
import 'package:spacetimedb_sdk/codegen.dart';
import 'reducers.dart';
import 'reducer_args.dart';
import 'cadence_item.dart';
import 'entity.dart';
import 'optional_item.dart';
import 'note.dart';
import 'tagged_item.dart';
import 'folder.dart';
import 'single_field.dart';
import 'scheduled_task.dart';
import 'session_marker.dart';

class SpacetimeDbClient {
  SpacetimeDbClient._({
    required this.connection,
    required this.subscriptions,
    required AuthTokenStore authStorage,
    required bool ssl,
  }) : _authStorage = authStorage,
       _ssl = ssl {
    reducers = Reducers(subscriptions.reducers, subscriptions.reducerEmitter);
  }

  final SpacetimeDbConnection connection;

  final SubscriptionManager subscriptions;

  final AuthTokenStore _authStorage;

  final bool _ssl;

  late final Reducers reducers;

  ReducerEmitter get reducerEmitter {
    return subscriptions.reducerEmitter;
  }

  Identity? get identity {
    return subscriptions.identity;
  }

  String? get address {
    return subscriptions.address;
  }

  String? get token {
    return connection.token;
  }

  bool get hasOfflineStorage {
    return subscriptions.hasOfflineStorage;
  }

  SyncState get syncState {
    return subscriptions.syncState;
  }

  Stream<SyncState> get onSyncStateChanged {
    return subscriptions.onSyncStateChanged;
  }

  Stream<MutationSyncResult> get onMutationSyncResult {
    return subscriptions.onMutationSyncResult;
  }

  void clearSyncErrors() {
    subscriptions.clearSyncErrors();
  }

  TableCache<CadenceItem> get cadenceItem {
    return subscriptions.cache.getTableByTypedName<CadenceItem>('cadence_item');
  }

  TableCache<Entity> get entity {
    return subscriptions.cache.getTableByTypedName<Entity>('entity');
  }

  TableCache<OptionalItem> get optionalItem {
    return subscriptions.cache.getTableByTypedName<OptionalItem>(
      'optional_item',
    );
  }

  TableCache<Note> get note {
    return subscriptions.cache.getTableByTypedName<Note>('note');
  }

  TableCache<TaggedItem> get taggedItem {
    return subscriptions.cache.getTableByTypedName<TaggedItem>('tagged_item');
  }

  TableCache<Folder> get folder {
    return subscriptions.cache.getTableByTypedName<Folder>('folder');
  }

  TableCache<SingleField> get singleField {
    return subscriptions.cache.getTableByTypedName<SingleField>('single_field');
  }

  TableCache<ScheduledTask> get scheduledTask {
    return subscriptions.cache.getTableByTypedName<ScheduledTask>(
      'scheduled_task',
    );
  }

  TableCache<SessionMarker> get sessionMarker {
    return subscriptions.cache.getTableByTypedName<SessionMarker>(
      'session_marker',
    );
  }

  TableCache<Note> get allNotes {
    return subscriptions.cache.getTableByTypedName<Note>('all_notes');
  }

  Note? get firstNote {
    final cache = subscriptions.cache.getTableByTypedName<Note>('first_note');
    final iterator = cache.iter().iterator;
    if (iterator.moveNext()) {
      return iterator.current;
    }
    return null;
  }

  TableCache<Note> get notesQueryAll {
    return subscriptions.cache.getTableByTypedName<Note>('notes_query_all');
  }

  static Future<SpacetimeDbClient> create({
    required String host,
    required String database,
    AuthTokenStore? authStorage,
    OfflineStorage? offlineStorage,
    OfflineQueuePolicy queuePolicy = const OfflineQueuePolicy(),
    bool retainRowsOnUnsubscribe = false,
    bool ssl = false,
    ConnectionConfig config = const ConnectionConfig(),
  }) async {
    final storage = authStorage ?? InMemoryTokenStore();
    final savedToken = await storage.loadToken();
    final connection = SpacetimeDbConnection(
      host: host,
      database: database,
      initialToken: savedToken,
      ssl: ssl,
      config: config,
    );
    final subscriptionManager = SubscriptionManager(
      connection,
      offlineStorage: offlineStorage,
      queuePolicy: queuePolicy,
      retainRowsOnUnsubscribe: retainRowsOnUnsubscribe,
    );

    subscriptionManager.cache.registerDecoder<CadenceItem>(
      'cadence_item',
      CadenceItemDecoder(),
    );
    subscriptionManager.cache.registerDecoder<Entity>(
      'entity',
      EntityDecoder(),
    );
    subscriptionManager.cache.registerDecoder<OptionalItem>(
      'optional_item',
      OptionalItemDecoder(),
    );
    subscriptionManager.cache.registerDecoder<Note>('note', NoteDecoder());
    subscriptionManager.cache.registerDecoder<TaggedItem>(
      'tagged_item',
      TaggedItemDecoder(),
    );
    subscriptionManager.cache.registerDecoder<Folder>(
      'folder',
      FolderDecoder(),
    );
    subscriptionManager.cache.registerDecoder<SingleField>(
      'single_field',
      SingleFieldDecoder(),
    );
    subscriptionManager.cache.registerDecoder<ScheduledTask>(
      'scheduled_task',
      ScheduledTaskDecoder(),
    );
    subscriptionManager.cache.registerDecoder<SessionMarker>(
      'session_marker',
      SessionMarkerDecoder(),
    );

    subscriptionManager.cache.registerDecoder<Note>('all_notes', NoteDecoder());
    subscriptionManager.cache.registerDecoder<Note>(
      'first_note',
      NoteDecoder(),
    );
    subscriptionManager.cache.registerDecoder<Note>(
      'notes_query_all',
      NoteDecoder(),
    );

    subscriptionManager.reducerRegistry.register(bulkInsertEntitiesDef);
    subscriptionManager.reducerRegistry.register(createCadenceItemDef);
    subscriptionManager.reducerRegistry.register(createFolderDef);
    subscriptionManager.reducerRegistry.register(createNoteDef);
    subscriptionManager.reducerRegistry.register(createNotesBulkDef);
    subscriptionManager.reducerRegistry.register(createOptionalItemDef);
    subscriptionManager.reducerRegistry.register(createSingleFieldDef);
    subscriptionManager.reducerRegistry.register(createTaggedItemDef);
    subscriptionManager.reducerRegistry.register(deleteAllFoldersDef);
    subscriptionManager.reducerRegistry.register(deleteAllNotesDef);
    subscriptionManager.reducerRegistry.register(deleteFolderDef);
    subscriptionManager.reducerRegistry.register(deleteNoteDef);
    subscriptionManager.reducerRegistry.register(diagInsertFiveDef);
    subscriptionManager.reducerRegistry.register(mixedNoteBatchDef);
    subscriptionManager.reducerRegistry.register(moveToDef);
    subscriptionManager.reducerRegistry.register(mutateRandomEntitiesDef);
    subscriptionManager.reducerRegistry.register(noOpDef);
    subscriptionManager.reducerRegistry.register(reducerReturnsErrDef);
    subscriptionManager.reducerRegistry.register(reducerThatPanicsDef);
    subscriptionManager.reducerRegistry.register(updateAllNotesDef);
    subscriptionManager.reducerRegistry.register(updateNoteDef);
    subscriptionManager.reducerRegistry.register(updateNoteGuardedDef);

    final client = SpacetimeDbClient._(
      connection: connection,
      subscriptions: subscriptionManager,
      authStorage: storage,
      ssl: ssl,
    );

    subscriptionManager.onInitialConnection.listen((msg) async {
      await storage.saveToken(msg.token);
      connection.updateToken(msg.token);
    });

    if (offlineStorage != null) {
      await subscriptionManager.loadFromOfflineCache();
    }

    return client;
  }

  Future<void> connect({
    List<String>? initialSubscriptions,
    Duration subscriptionTimeout = const Duration(seconds: 10),
  }) async {
    await connection.connect().timeout(connection.config.connectTimeout);
    if (initialSubscriptions != null && initialSubscriptions.isNotEmpty) {
      await subscriptions
          .subscribe(initialSubscriptions)
          .timeout(subscriptionTimeout);
    }
  }

  Future<void> disconnect() async {
    await connection.disconnect();
  }

  Future<void> logout() async {
    await _authStorage.clearToken();
    await connection.disconnect();
  }

  String getAuthUrl(String provider, {String? redirectUri}) {
    final helper = OidcHelper(
      host: connection.host,
      database: connection.database,
      ssl: _ssl,
    );
    return helper.getAuthUrl(provider, redirectUri: redirectUri);
  }

  String? parseTokenFromCallback(String callbackUrl) {
    final helper = OidcHelper(
      host: connection.host,
      database: connection.database,
      ssl: _ssl,
    );
    return helper.parseTokenFromCallback(callbackUrl);
  }
}
