// GENERATED CODE - DO NOT MODIFY BY HAND

import 'dart:async';
import 'package:spacetimedb_dart_sdk/codegen.dart';
import 'reducer_args.dart';

class Reducers {
  Reducers(this._reducerCaller, this._reducerEmitter);

  final ReducerCaller _reducerCaller;

  final ReducerEmitter _reducerEmitter;

  Future<TransactionResult> bulkInsertEntities({
    required int count,
    List<OptimisticChange>? optimisticChanges,
    bool dropIfOffline = false,
  }) async {
    final encoder = BsatnEncoder();
    encoder.writeU32(count);
    return await _reducerCaller.call(
      bulkInsertEntitiesDef.name,
      encoder.toBytes(),
      optimisticChanges: optimisticChanges,
      dropIfOffline: dropIfOffline,
    );
  }

  Future<TransactionResult> createFolder({
    required String path,
    required String name,
    List<OptimisticChange>? optimisticChanges,
    bool dropIfOffline = false,
  }) async {
    final encoder = BsatnEncoder();
    encoder.writeString(path);
    encoder.writeString(name);
    return await _reducerCaller.call(
      createFolderDef.name,
      encoder.toBytes(),
      optimisticChanges: optimisticChanges,
      dropIfOffline: dropIfOffline,
    );
  }

  Future<TransactionResult> createNote({
    required String title,
    required String content,
    List<OptimisticChange>? optimisticChanges,
    bool dropIfOffline = false,
  }) async {
    final encoder = BsatnEncoder();
    encoder.writeString(title);
    encoder.writeString(content);
    return await _reducerCaller.call(
      createNoteDef.name,
      encoder.toBytes(),
      optimisticChanges: optimisticChanges,
      dropIfOffline: dropIfOffline,
    );
  }

  Future<TransactionResult> createNotesBulk({
    required int count,
    required String titlePrefix,
    List<OptimisticChange>? optimisticChanges,
    bool dropIfOffline = false,
  }) async {
    final encoder = BsatnEncoder();
    encoder.writeU32(count);
    encoder.writeString(titlePrefix);
    return await _reducerCaller.call(
      createNotesBulkDef.name,
      encoder.toBytes(),
      optimisticChanges: optimisticChanges,
      dropIfOffline: dropIfOffline,
    );
  }

  Future<TransactionResult> deleteAllFolders({
    List<OptimisticChange>? optimisticChanges,
    bool dropIfOffline = false,
  }) async {
    final encoder = BsatnEncoder();
    return await _reducerCaller.call(
      deleteAllFoldersDef.name,
      encoder.toBytes(),
      optimisticChanges: optimisticChanges,
      dropIfOffline: dropIfOffline,
    );
  }

  Future<TransactionResult> deleteAllNotes({
    List<OptimisticChange>? optimisticChanges,
    bool dropIfOffline = false,
  }) async {
    final encoder = BsatnEncoder();
    return await _reducerCaller.call(
      deleteAllNotesDef.name,
      encoder.toBytes(),
      optimisticChanges: optimisticChanges,
      dropIfOffline: dropIfOffline,
    );
  }

  Future<TransactionResult> deleteFolder({
    required String path,
    List<OptimisticChange>? optimisticChanges,
    bool dropIfOffline = false,
  }) async {
    final encoder = BsatnEncoder();
    encoder.writeString(path);
    return await _reducerCaller.call(
      deleteFolderDef.name,
      encoder.toBytes(),
      optimisticChanges: optimisticChanges,
      dropIfOffline: dropIfOffline,
    );
  }

  Future<TransactionResult> deleteNote({
    required int noteId,
    List<OptimisticChange>? optimisticChanges,
    bool dropIfOffline = false,
  }) async {
    final encoder = BsatnEncoder();
    encoder.writeU32(noteId);
    return await _reducerCaller.call(
      deleteNoteDef.name,
      encoder.toBytes(),
      optimisticChanges: optimisticChanges,
      dropIfOffline: dropIfOffline,
    );
  }

  Future<TransactionResult> diagInsertFive({
    List<OptimisticChange>? optimisticChanges,
    bool dropIfOffline = false,
  }) async {
    final encoder = BsatnEncoder();
    return await _reducerCaller.call(
      diagInsertFiveDef.name,
      encoder.toBytes(),
      optimisticChanges: optimisticChanges,
      dropIfOffline: dropIfOffline,
    );
  }

  Future<TransactionResult> mixedNoteBatch({
    required int inserts,
    required int updates,
    required int deletes,
    required String marker,
    List<OptimisticChange>? optimisticChanges,
    bool dropIfOffline = false,
  }) async {
    final encoder = BsatnEncoder();
    encoder.writeU32(inserts);
    encoder.writeU32(updates);
    encoder.writeU32(deletes);
    encoder.writeString(marker);
    return await _reducerCaller.call(
      mixedNoteBatchDef.name,
      encoder.toBytes(),
      optimisticChanges: optimisticChanges,
      dropIfOffline: dropIfOffline,
    );
  }

  Future<TransactionResult> mutateRandomEntities({
    required int count,
    required Int64 seed,
    List<OptimisticChange>? optimisticChanges,
    bool dropIfOffline = false,
  }) async {
    final encoder = BsatnEncoder();
    encoder.writeU32(count);
    encoder.writeU64(seed);
    return await _reducerCaller.call(
      mutateRandomEntitiesDef.name,
      encoder.toBytes(),
      optimisticChanges: optimisticChanges,
      dropIfOffline: dropIfOffline,
    );
  }

  Future<TransactionResult> noOp({
    List<OptimisticChange>? optimisticChanges,
    bool dropIfOffline = false,
  }) async {
    final encoder = BsatnEncoder();
    return await _reducerCaller.call(
      noOpDef.name,
      encoder.toBytes(),
      optimisticChanges: optimisticChanges,
      dropIfOffline: dropIfOffline,
    );
  }

  Future<TransactionResult> updateAllNotes({
    required String newContent,
    List<OptimisticChange>? optimisticChanges,
    bool dropIfOffline = false,
  }) async {
    final encoder = BsatnEncoder();
    encoder.writeString(newContent);
    return await _reducerCaller.call(
      updateAllNotesDef.name,
      encoder.toBytes(),
      optimisticChanges: optimisticChanges,
      dropIfOffline: dropIfOffline,
    );
  }

  Future<TransactionResult> updateNote({
    required int noteId,
    required String title,
    required String content,
    List<OptimisticChange>? optimisticChanges,
    bool dropIfOffline = false,
  }) async {
    final encoder = BsatnEncoder();
    encoder.writeU32(noteId);
    encoder.writeString(title);
    encoder.writeString(content);
    return await _reducerCaller.call(
      updateNoteDef.name,
      encoder.toBytes(),
      optimisticChanges: optimisticChanges,
      dropIfOffline: dropIfOffline,
    );
  }

  StreamSubscription<void> onBulkInsertEntities(
    void Function(EventContext ctx, int count) callback,
  ) {
    return _reducerEmitter.on(bulkInsertEntitiesDef).listen((EventContext ctx) {
      final event = ctx.event;
      if (event is! ReducerEvent) return;
      final args = event.reducerArgs;
      if (args is! BulkInsertEntitiesArgs) return;
      callback(ctx, args.count);
    });
  }

  StreamSubscription<void> onCreateFolder(
    void Function(EventContext ctx, String path, String name) callback,
  ) {
    return _reducerEmitter.on(createFolderDef).listen((EventContext ctx) {
      final event = ctx.event;
      if (event is! ReducerEvent) return;
      final args = event.reducerArgs;
      if (args is! CreateFolderArgs) return;
      callback(ctx, args.path, args.name);
    });
  }

  StreamSubscription<void> onCreateNote(
    void Function(EventContext ctx, String title, String content) callback,
  ) {
    return _reducerEmitter.on(createNoteDef).listen((EventContext ctx) {
      final event = ctx.event;
      if (event is! ReducerEvent) return;
      final args = event.reducerArgs;
      if (args is! CreateNoteArgs) return;
      callback(ctx, args.title, args.content);
    });
  }

  StreamSubscription<void> onCreateNotesBulk(
    void Function(EventContext ctx, int count, String titlePrefix) callback,
  ) {
    return _reducerEmitter.on(createNotesBulkDef).listen((EventContext ctx) {
      final event = ctx.event;
      if (event is! ReducerEvent) return;
      final args = event.reducerArgs;
      if (args is! CreateNotesBulkArgs) return;
      callback(ctx, args.count, args.titlePrefix);
    });
  }

  StreamSubscription<void> onDeleteAllFolders(
    void Function(EventContext ctx) callback,
  ) {
    return _reducerEmitter.on(deleteAllFoldersDef).listen((EventContext ctx) {
      final event = ctx.event;
      if (event is! ReducerEvent) return;
      final args = event.reducerArgs;
      if (args is! DeleteAllFoldersArgs) return;
      callback(ctx);
    });
  }

  StreamSubscription<void> onDeleteAllNotes(
    void Function(EventContext ctx) callback,
  ) {
    return _reducerEmitter.on(deleteAllNotesDef).listen((EventContext ctx) {
      final event = ctx.event;
      if (event is! ReducerEvent) return;
      final args = event.reducerArgs;
      if (args is! DeleteAllNotesArgs) return;
      callback(ctx);
    });
  }

  StreamSubscription<void> onDeleteFolder(
    void Function(EventContext ctx, String path) callback,
  ) {
    return _reducerEmitter.on(deleteFolderDef).listen((EventContext ctx) {
      final event = ctx.event;
      if (event is! ReducerEvent) return;
      final args = event.reducerArgs;
      if (args is! DeleteFolderArgs) return;
      callback(ctx, args.path);
    });
  }

  StreamSubscription<void> onDeleteNote(
    void Function(EventContext ctx, int noteId) callback,
  ) {
    return _reducerEmitter.on(deleteNoteDef).listen((EventContext ctx) {
      final event = ctx.event;
      if (event is! ReducerEvent) return;
      final args = event.reducerArgs;
      if (args is! DeleteNoteArgs) return;
      callback(ctx, args.noteId);
    });
  }

  StreamSubscription<void> onDiagInsertFive(
    void Function(EventContext ctx) callback,
  ) {
    return _reducerEmitter.on(diagInsertFiveDef).listen((EventContext ctx) {
      final event = ctx.event;
      if (event is! ReducerEvent) return;
      final args = event.reducerArgs;
      if (args is! DiagInsertFiveArgs) return;
      callback(ctx);
    });
  }

  StreamSubscription<void> onMixedNoteBatch(
    void Function(
      EventContext ctx,
      int inserts,
      int updates,
      int deletes,
      String marker,
    )
    callback,
  ) {
    return _reducerEmitter.on(mixedNoteBatchDef).listen((EventContext ctx) {
      final event = ctx.event;
      if (event is! ReducerEvent) return;
      final args = event.reducerArgs;
      if (args is! MixedNoteBatchArgs) return;
      callback(ctx, args.inserts, args.updates, args.deletes, args.marker);
    });
  }

  StreamSubscription<void> onMutateRandomEntities(
    void Function(EventContext ctx, int count, Int64 seed) callback,
  ) {
    return _reducerEmitter.on(mutateRandomEntitiesDef).listen((
      EventContext ctx,
    ) {
      final event = ctx.event;
      if (event is! ReducerEvent) return;
      final args = event.reducerArgs;
      if (args is! MutateRandomEntitiesArgs) return;
      callback(ctx, args.count, args.seed);
    });
  }

  StreamSubscription<void> onNoOp(void Function(EventContext ctx) callback) {
    return _reducerEmitter.on(noOpDef).listen((EventContext ctx) {
      final event = ctx.event;
      if (event is! ReducerEvent) return;
      final args = event.reducerArgs;
      if (args is! NoOpArgs) return;
      callback(ctx);
    });
  }

  StreamSubscription<void> onUpdateAllNotes(
    void Function(EventContext ctx, String newContent) callback,
  ) {
    return _reducerEmitter.on(updateAllNotesDef).listen((EventContext ctx) {
      final event = ctx.event;
      if (event is! ReducerEvent) return;
      final args = event.reducerArgs;
      if (args is! UpdateAllNotesArgs) return;
      callback(ctx, args.newContent);
    });
  }

  StreamSubscription<void> onUpdateNote(
    void Function(EventContext ctx, int noteId, String title, String content)
    callback,
  ) {
    return _reducerEmitter.on(updateNoteDef).listen((EventContext ctx) {
      final event = ctx.event;
      if (event is! ReducerEvent) return;
      final args = event.reducerArgs;
      if (args is! UpdateNoteArgs) return;
      callback(ctx, args.noteId, args.title, args.content);
    });
  }
}
