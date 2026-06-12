// GENERATED CODE - DO NOT MODIFY BY HAND

import 'dart:async';
import 'package:spacetimedb_sdk/codegen.dart';
import 'reducer_args.dart';

class Reducers {
  Reducers(this._reducerCaller, this._reducerEmitter);

  final ReducerCaller _reducerCaller;

  final ReducerEmitter _reducerEmitter;

  /// Calls the `bulk_insert_entities` reducer.
  ///
  /// Returns a [TransactionResult] on success. Throws
  /// [SpacetimeDbReducerException] if the reducer returns `Failed` or
  /// `InternalError`. The returned status is one of `Committed`,
  /// `Pending` (queued to offline storage), or `Dropped` (skipped via
  /// `dropIfOffline: true` while offline).
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

  /// Calls the `create_folder` reducer.
  ///
  /// Returns a [TransactionResult] on success. Throws
  /// [SpacetimeDbReducerException] if the reducer returns `Failed` or
  /// `InternalError`. The returned status is one of `Committed`,
  /// `Pending` (queued to offline storage), or `Dropped` (skipped via
  /// `dropIfOffline: true` while offline).
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

  /// Calls the `create_note` reducer.
  ///
  /// Returns a [TransactionResult] on success. Throws
  /// [SpacetimeDbReducerException] if the reducer returns `Failed` or
  /// `InternalError`. The returned status is one of `Committed`,
  /// `Pending` (queued to offline storage), or `Dropped` (skipped via
  /// `dropIfOffline: true` while offline).
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

  /// Calls the `create_notes_bulk` reducer.
  ///
  /// Returns a [TransactionResult] on success. Throws
  /// [SpacetimeDbReducerException] if the reducer returns `Failed` or
  /// `InternalError`. The returned status is one of `Committed`,
  /// `Pending` (queued to offline storage), or `Dropped` (skipped via
  /// `dropIfOffline: true` while offline).
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

  /// Calls the `create_optional_item` reducer.
  ///
  /// Returns a [TransactionResult] on success. Throws
  /// [SpacetimeDbReducerException] if the reducer returns `Failed` or
  /// `InternalError`. The returned status is one of `Committed`,
  /// `Pending` (queued to offline storage), or `Dropped` (skipped via
  /// `dropIfOffline: true` while offline).
  Future<TransactionResult> createOptionalItem({
    required int id,
    required String? nickname,
    required Int64? score,
    required Int64? resolvedAt,
    List<OptimisticChange>? optimisticChanges,
    bool dropIfOffline = false,
  }) async {
    final encoder = BsatnEncoder();
    encoder.writeU32(id);
    encoder.writeOption<String>(
      nickname,
      (value) => encoder.writeString(value),
    );
    encoder.writeOption<Int64>(score, (value) => encoder.writeU64(value));
    encoder.writeOption<Int64>(resolvedAt, (value) => encoder.writeU64(value));
    return await _reducerCaller.call(
      createOptionalItemDef.name,
      encoder.toBytes(),
      optimisticChanges: optimisticChanges,
      dropIfOffline: dropIfOffline,
    );
  }

  /// Calls the `create_tagged_item` reducer.
  ///
  /// Returns a [TransactionResult] on success. Throws
  /// [SpacetimeDbReducerException] if the reducer returns `Failed` or
  /// `InternalError`. The returned status is one of `Committed`,
  /// `Pending` (queued to offline storage), or `Dropped` (skipped via
  /// `dropIfOffline: true` while offline).
  Future<TransactionResult> createTaggedItem({
    required int id,
    required String name,
    required List<Int64> tagIds,
    required List<String> labels,
    List<OptimisticChange>? optimisticChanges,
    bool dropIfOffline = false,
  }) async {
    final encoder = BsatnEncoder();
    encoder.writeU32(id);
    encoder.writeString(name);
    encoder.writeArray<Int64>(tagIds, (item) => encoder.writeU64(item));
    encoder.writeArray<String>(labels, (item) => encoder.writeString(item));
    return await _reducerCaller.call(
      createTaggedItemDef.name,
      encoder.toBytes(),
      optimisticChanges: optimisticChanges,
      dropIfOffline: dropIfOffline,
    );
  }

  /// Calls the `delete_all_folders` reducer.
  ///
  /// Returns a [TransactionResult] on success. Throws
  /// [SpacetimeDbReducerException] if the reducer returns `Failed` or
  /// `InternalError`. The returned status is one of `Committed`,
  /// `Pending` (queued to offline storage), or `Dropped` (skipped via
  /// `dropIfOffline: true` while offline).
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

  /// Calls the `delete_all_notes` reducer.
  ///
  /// Returns a [TransactionResult] on success. Throws
  /// [SpacetimeDbReducerException] if the reducer returns `Failed` or
  /// `InternalError`. The returned status is one of `Committed`,
  /// `Pending` (queued to offline storage), or `Dropped` (skipped via
  /// `dropIfOffline: true` while offline).
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

  /// Calls the `delete_folder` reducer.
  ///
  /// Returns a [TransactionResult] on success. Throws
  /// [SpacetimeDbReducerException] if the reducer returns `Failed` or
  /// `InternalError`. The returned status is one of `Committed`,
  /// `Pending` (queued to offline storage), or `Dropped` (skipped via
  /// `dropIfOffline: true` while offline).
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

  /// Calls the `delete_note` reducer.
  ///
  /// Returns a [TransactionResult] on success. Throws
  /// [SpacetimeDbReducerException] if the reducer returns `Failed` or
  /// `InternalError`. The returned status is one of `Committed`,
  /// `Pending` (queued to offline storage), or `Dropped` (skipped via
  /// `dropIfOffline: true` while offline).
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

  /// Calls the `diag_insert_five` reducer.
  ///
  /// Returns a [TransactionResult] on success. Throws
  /// [SpacetimeDbReducerException] if the reducer returns `Failed` or
  /// `InternalError`. The returned status is one of `Committed`,
  /// `Pending` (queued to offline storage), or `Dropped` (skipped via
  /// `dropIfOffline: true` while offline).
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

  /// Calls the `mixed_note_batch` reducer.
  ///
  /// Returns a [TransactionResult] on success. Throws
  /// [SpacetimeDbReducerException] if the reducer returns `Failed` or
  /// `InternalError`. The returned status is one of `Committed`,
  /// `Pending` (queued to offline storage), or `Dropped` (skipped via
  /// `dropIfOffline: true` while offline).
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

  /// Calls the `mutate_random_entities` reducer.
  ///
  /// Returns a [TransactionResult] on success. Throws
  /// [SpacetimeDbReducerException] if the reducer returns `Failed` or
  /// `InternalError`. The returned status is one of `Committed`,
  /// `Pending` (queued to offline storage), or `Dropped` (skipped via
  /// `dropIfOffline: true` while offline).
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

  /// Calls the `no_op` reducer.
  ///
  /// Returns a [TransactionResult] on success. Throws
  /// [SpacetimeDbReducerException] if the reducer returns `Failed` or
  /// `InternalError`. The returned status is one of `Committed`,
  /// `Pending` (queued to offline storage), or `Dropped` (skipped via
  /// `dropIfOffline: true` while offline).
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

  /// Calls the `reducer_returns_err` reducer.
  ///
  /// Returns a [TransactionResult] on success. Throws
  /// [SpacetimeDbReducerException] if the reducer returns `Failed` or
  /// `InternalError`. The returned status is one of `Committed`,
  /// `Pending` (queued to offline storage), or `Dropped` (skipped via
  /// `dropIfOffline: true` while offline).
  Future<TransactionResult> reducerReturnsErr({
    required String message,
    List<OptimisticChange>? optimisticChanges,
    bool dropIfOffline = false,
  }) async {
    final encoder = BsatnEncoder();
    encoder.writeString(message);
    return await _reducerCaller.call(
      reducerReturnsErrDef.name,
      encoder.toBytes(),
      optimisticChanges: optimisticChanges,
      dropIfOffline: dropIfOffline,
    );
  }

  /// Calls the `reducer_that_panics` reducer.
  ///
  /// Returns a [TransactionResult] on success. Throws
  /// [SpacetimeDbReducerException] if the reducer returns `Failed` or
  /// `InternalError`. The returned status is one of `Committed`,
  /// `Pending` (queued to offline storage), or `Dropped` (skipped via
  /// `dropIfOffline: true` while offline).
  Future<TransactionResult> reducerThatPanics({
    List<OptimisticChange>? optimisticChanges,
    bool dropIfOffline = false,
  }) async {
    final encoder = BsatnEncoder();
    return await _reducerCaller.call(
      reducerThatPanicsDef.name,
      encoder.toBytes(),
      optimisticChanges: optimisticChanges,
      dropIfOffline: dropIfOffline,
    );
  }

  /// Calls the `update_all_notes` reducer.
  ///
  /// Returns a [TransactionResult] on success. Throws
  /// [SpacetimeDbReducerException] if the reducer returns `Failed` or
  /// `InternalError`. The returned status is one of `Committed`,
  /// `Pending` (queued to offline storage), or `Dropped` (skipped via
  /// `dropIfOffline: true` while offline).
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

  /// Calls the `update_note` reducer.
  ///
  /// Returns a [TransactionResult] on success. Throws
  /// [SpacetimeDbReducerException] if the reducer returns `Failed` or
  /// `InternalError`. The returned status is one of `Committed`,
  /// `Pending` (queued to offline storage), or `Dropped` (skipped via
  /// `dropIfOffline: true` while offline).
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

  /// Calls the `update_note_guarded` reducer.
  ///
  /// Returns a [TransactionResult] on success. Throws
  /// [SpacetimeDbReducerException] if the reducer returns `Failed` or
  /// `InternalError`. The returned status is one of `Committed`,
  /// `Pending` (queued to offline storage), or `Dropped` (skipped via
  /// `dropIfOffline: true` while offline).
  Future<TransactionResult> updateNoteGuarded({
    required int noteId,
    required String content,
    List<OptimisticChange>? optimisticChanges,
    bool dropIfOffline = false,
  }) async {
    final encoder = BsatnEncoder();
    encoder.writeU32(noteId);
    encoder.writeString(content);
    return await _reducerCaller.call(
      updateNoteGuardedDef.name,
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

  StreamSubscription<void> onCreateOptionalItem(
    void Function(
      EventContext ctx,
      int id,
      String? nickname,
      Int64? score,
      Int64? resolvedAt,
    )
    callback,
  ) {
    return _reducerEmitter.on(createOptionalItemDef).listen((EventContext ctx) {
      final event = ctx.event;
      if (event is! ReducerEvent) return;
      final args = event.reducerArgs;
      if (args is! CreateOptionalItemArgs) return;
      callback(ctx, args.id, args.nickname, args.score, args.resolvedAt);
    });
  }

  StreamSubscription<void> onCreateTaggedItem(
    void Function(
      EventContext ctx,
      int id,
      String name,
      List<Int64> tagIds,
      List<String> labels,
    )
    callback,
  ) {
    return _reducerEmitter.on(createTaggedItemDef).listen((EventContext ctx) {
      final event = ctx.event;
      if (event is! ReducerEvent) return;
      final args = event.reducerArgs;
      if (args is! CreateTaggedItemArgs) return;
      callback(ctx, args.id, args.name, args.tagIds, args.labels);
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

  StreamSubscription<void> onReducerReturnsErr(
    void Function(EventContext ctx, String message) callback,
  ) {
    return _reducerEmitter.on(reducerReturnsErrDef).listen((EventContext ctx) {
      final event = ctx.event;
      if (event is! ReducerEvent) return;
      final args = event.reducerArgs;
      if (args is! ReducerReturnsErrArgs) return;
      callback(ctx, args.message);
    });
  }

  StreamSubscription<void> onReducerThatPanics(
    void Function(EventContext ctx) callback,
  ) {
    return _reducerEmitter.on(reducerThatPanicsDef).listen((EventContext ctx) {
      final event = ctx.event;
      if (event is! ReducerEvent) return;
      final args = event.reducerArgs;
      if (args is! ReducerThatPanicsArgs) return;
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

  StreamSubscription<void> onUpdateNoteGuarded(
    void Function(EventContext ctx, int noteId, String content) callback,
  ) {
    return _reducerEmitter.on(updateNoteGuardedDef).listen((EventContext ctx) {
      final event = ctx.event;
      if (event is! ReducerEvent) return;
      final args = event.reducerArgs;
      if (args is! UpdateNoteGuardedArgs) return;
      callback(ctx, args.noteId, args.content);
    });
  }
}
