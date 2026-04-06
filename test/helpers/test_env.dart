import 'package:spacetimedb_dart_sdk/spacetimedb_dart_sdk.dart';
import '../generated/note.dart';
import '../generated/folder.dart';
import '../generated/reducer_args.dart';
import '../generated/reducers.dart' as gen;

class TestEnv {
  final SpacetimeDbConnection connection;
  final SubscriptionManager subManager;
  final gen.Reducers reducers;

  TestEnv({
    required this.connection,
    required this.subManager,
    required this.reducers,
  });

  TableCache<Note> get noteTable =>
      subManager.cache.getTableByTypedName<Note>('note');

  TableCache<Folder> get folderTable =>
      subManager.cache.getTableByTypedName<Folder>('folder');

  Future<void> disconnect() async {
    await connection.disconnect();
  }
}

Future<TestEnv> createTestEnv({
  bool registerNote = true,
  bool registerFolder = false,
  bool registerViews = false,
  OfflineStorage? offlineStorage,
}) async {
  final connection = SpacetimeDbConnection(
    host: 'localhost:3000',
    database: 'notesdb',
  );
  final subManager = SubscriptionManager(
    connection,
    offlineStorage: offlineStorage,
  );

  if (registerNote) {
    subManager.cache.registerDecoder<Note>('note', NoteDecoder());
  }
  if (registerFolder) {
    subManager.cache.registerDecoder<Folder>('folder', FolderDecoder());
  }
  if (registerViews) {
    subManager.cache.registerDecoder<Note>('all_notes', NoteDecoder());
    subManager.cache.registerDecoder<Note>('first_note', NoteDecoder());
    subManager.cache.registerDecoder<Note>('notes_query_all', NoteDecoder());
  }

  subManager.reducerRegistry.register(createNoteDef);
  subManager.reducerRegistry.register(updateNoteDef);
  subManager.reducerRegistry.register(deleteNoteDef);
  subManager.reducerRegistry.register(deleteAllNotesDef);
  subManager.reducerRegistry.register(createFolderDef);
  subManager.reducerRegistry.register(deleteFolderDef);
  subManager.reducerRegistry.register(deleteAllFoldersDef);

  final reducers = gen.Reducers(subManager.reducers, subManager.reducerEmitter);

  return TestEnv(
    connection: connection,
    subManager: subManager,
    reducers: reducers,
  );
}
