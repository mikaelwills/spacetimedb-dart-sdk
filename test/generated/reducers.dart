// GENERATED CODE - DO NOT MODIFY BY HAND

import 'dart:async';
import 'package:spacetimedb_dart_sdk/spacetimedb_dart_sdk.dart';
import 'reducer_args.dart';

/// Generated reducer methods with async/await support
///
/// All methods return Future<TransactionResult> containing:
/// - status: Committed/Failed/OutOfEnergy
/// - timestamp: When the reducer executed
/// - energyConsumed: Energy used (null for TransactionUpdateLight)
/// - executionDuration: How long it took (null for TransactionUpdateLight)
class Reducers {
  final ReducerCaller _reducerCaller;
  final ReducerEmitter _reducerEmitter;

  Reducers(this._reducerCaller, this._reducerEmitter);

  /// Call the create_folder reducer
  ///
  /// Returns [TransactionResult] with execution metadata:
  /// - `result.isSuccess` - Check if reducer committed
  /// - `result.energyConsumed` - Energy used (null for lightweight responses)
  /// - `result.executionDuration` - How long it took (null for lightweight responses)
  ///
  /// Pass [optimisticChanges] to immediately update the local cache for offline-first UX.
  /// Changes are rolled back if the server rejects them.
  ///
  /// Throws [ReducerException] if the reducer fails or runs out of energy.
  /// Throws [TimeoutException] if the reducer doesn't complete within the timeout.
  Future<TransactionResult> createFolder({
    required String path,
    required String name,
    List<OptimisticChange>? optimisticChanges,
    bool isEventTable = false,
  }) async {
    final encoder = BsatnEncoder();
    encoder.writeString(path);
    encoder.writeString(name);

    return await _reducerCaller.call(
      'create_folder',
      encoder.toBytes(),
      optimisticChanges: optimisticChanges,
      isEventTable: isEventTable,
    );
  }

  /// Call the create_note reducer
  ///
  /// Returns [TransactionResult] with execution metadata:
  /// - `result.isSuccess` - Check if reducer committed
  /// - `result.energyConsumed` - Energy used (null for lightweight responses)
  /// - `result.executionDuration` - How long it took (null for lightweight responses)
  ///
  /// Pass [optimisticChanges] to immediately update the local cache for offline-first UX.
  /// Changes are rolled back if the server rejects them.
  ///
  /// Throws [ReducerException] if the reducer fails or runs out of energy.
  /// Throws [TimeoutException] if the reducer doesn't complete within the timeout.
  Future<TransactionResult> createNote({
    required String title,
    required String content,
    List<OptimisticChange>? optimisticChanges,
    bool isEventTable = false,
  }) async {
    final encoder = BsatnEncoder();
    encoder.writeString(title);
    encoder.writeString(content);

    return await _reducerCaller.call(
      'create_note',
      encoder.toBytes(),
      optimisticChanges: optimisticChanges,
      isEventTable: isEventTable,
    );
  }

  /// Call the delete_all_folders reducer
  ///
  /// Returns [TransactionResult] with execution metadata:
  /// - `result.isSuccess` - Check if reducer committed
  /// - `result.energyConsumed` - Energy used (null for lightweight responses)
  /// - `result.executionDuration` - How long it took (null for lightweight responses)
  ///
  /// Pass [optimisticChanges] to immediately update the local cache for offline-first UX.
  /// Changes are rolled back if the server rejects them.
  ///
  /// Throws [ReducerException] if the reducer fails or runs out of energy.
  /// Throws [TimeoutException] if the reducer doesn't complete within the timeout.
  Future<TransactionResult> deleteAllFolders({
    List<OptimisticChange>? optimisticChanges,
    bool isEventTable = false,
  }) async {
    final encoder = BsatnEncoder();

    return await _reducerCaller.call(
      'delete_all_folders',
      encoder.toBytes(),
      optimisticChanges: optimisticChanges,
      isEventTable: isEventTable,
    );
  }

  /// Call the delete_all_notes reducer
  ///
  /// Returns [TransactionResult] with execution metadata:
  /// - `result.isSuccess` - Check if reducer committed
  /// - `result.energyConsumed` - Energy used (null for lightweight responses)
  /// - `result.executionDuration` - How long it took (null for lightweight responses)
  ///
  /// Pass [optimisticChanges] to immediately update the local cache for offline-first UX.
  /// Changes are rolled back if the server rejects them.
  ///
  /// Throws [ReducerException] if the reducer fails or runs out of energy.
  /// Throws [TimeoutException] if the reducer doesn't complete within the timeout.
  Future<TransactionResult> deleteAllNotes({
    List<OptimisticChange>? optimisticChanges,
    bool isEventTable = false,
  }) async {
    final encoder = BsatnEncoder();

    return await _reducerCaller.call(
      'delete_all_notes',
      encoder.toBytes(),
      optimisticChanges: optimisticChanges,
      isEventTable: isEventTable,
    );
  }

  /// Call the delete_folder reducer
  ///
  /// Returns [TransactionResult] with execution metadata:
  /// - `result.isSuccess` - Check if reducer committed
  /// - `result.energyConsumed` - Energy used (null for lightweight responses)
  /// - `result.executionDuration` - How long it took (null for lightweight responses)
  ///
  /// Pass [optimisticChanges] to immediately update the local cache for offline-first UX.
  /// Changes are rolled back if the server rejects them.
  ///
  /// Throws [ReducerException] if the reducer fails or runs out of energy.
  /// Throws [TimeoutException] if the reducer doesn't complete within the timeout.
  Future<TransactionResult> deleteFolder({
    required String path,
    List<OptimisticChange>? optimisticChanges,
    bool isEventTable = false,
  }) async {
    final encoder = BsatnEncoder();
    encoder.writeString(path);

    return await _reducerCaller.call(
      'delete_folder',
      encoder.toBytes(),
      optimisticChanges: optimisticChanges,
      isEventTable: isEventTable,
    );
  }

  /// Call the delete_note reducer
  ///
  /// Returns [TransactionResult] with execution metadata:
  /// - `result.isSuccess` - Check if reducer committed
  /// - `result.energyConsumed` - Energy used (null for lightweight responses)
  /// - `result.executionDuration` - How long it took (null for lightweight responses)
  ///
  /// Pass [optimisticChanges] to immediately update the local cache for offline-first UX.
  /// Changes are rolled back if the server rejects them.
  ///
  /// Throws [ReducerException] if the reducer fails or runs out of energy.
  /// Throws [TimeoutException] if the reducer doesn't complete within the timeout.
  Future<TransactionResult> deleteNote({
    required int noteId,
    List<OptimisticChange>? optimisticChanges,
    bool isEventTable = false,
  }) async {
    final encoder = BsatnEncoder();
    encoder.writeU32(noteId);

    return await _reducerCaller.call(
      'delete_note',
      encoder.toBytes(),
      optimisticChanges: optimisticChanges,
      isEventTable: isEventTable,
    );
  }

  /// Call the init reducer
  ///
  /// Returns [TransactionResult] with execution metadata:
  /// - `result.isSuccess` - Check if reducer committed
  /// - `result.energyConsumed` - Energy used (null for lightweight responses)
  /// - `result.executionDuration` - How long it took (null for lightweight responses)
  ///
  /// Pass [optimisticChanges] to immediately update the local cache for offline-first UX.
  /// Changes are rolled back if the server rejects them.
  ///
  /// Throws [ReducerException] if the reducer fails or runs out of energy.
  /// Throws [TimeoutException] if the reducer doesn't complete within the timeout.
  Future<TransactionResult> init({
    List<OptimisticChange>? optimisticChanges,
    bool isEventTable = false,
  }) async {
    final encoder = BsatnEncoder();

    return await _reducerCaller.call(
      'init',
      encoder.toBytes(),
      optimisticChanges: optimisticChanges,
      isEventTable: isEventTable,
    );
  }

  /// Call the update_note reducer
  ///
  /// Returns [TransactionResult] with execution metadata:
  /// - `result.isSuccess` - Check if reducer committed
  /// - `result.energyConsumed` - Energy used (null for lightweight responses)
  /// - `result.executionDuration` - How long it took (null for lightweight responses)
  ///
  /// Pass [optimisticChanges] to immediately update the local cache for offline-first UX.
  /// Changes are rolled back if the server rejects them.
  ///
  /// Throws [ReducerException] if the reducer fails or runs out of energy.
  /// Throws [TimeoutException] if the reducer doesn't complete within the timeout.
  Future<TransactionResult> updateNote({
    required int noteId,
    required String title,
    required String content,
    List<OptimisticChange>? optimisticChanges,
    bool isEventTable = false,
  }) async {
    final encoder = BsatnEncoder();
    encoder.writeU32(noteId);
    encoder.writeString(title);
    encoder.writeString(content);

    return await _reducerCaller.call(
      'update_note',
      encoder.toBytes(),
      optimisticChanges: optimisticChanges,
      isEventTable: isEventTable,
    );
  }

  StreamSubscription<void> onCreateFolder(
    void Function(EventContext ctx, String path, String name) callback,
  ) {
    return _reducerEmitter.on('create_folder').listen((EventContext ctx) {
      // Pattern match to extract ReducerEvent
      final event = ctx.event;
      if (event is! ReducerEvent) return;

      // Type guard - ensures args is correct type
      final args = event.reducerArgs;
      if (args is! CreateFolderArgs) return;

      // Extract fields from strongly-typed object - NO CASTING
      callback(ctx, args.path, args.name);
    });
  }

  StreamSubscription<void> onCreateNote(
    void Function(EventContext ctx, String title, String content) callback,
  ) {
    return _reducerEmitter.on('create_note').listen((EventContext ctx) {
      // Pattern match to extract ReducerEvent
      final event = ctx.event;
      if (event is! ReducerEvent) return;

      // Type guard - ensures args is correct type
      final args = event.reducerArgs;
      if (args is! CreateNoteArgs) return;

      // Extract fields from strongly-typed object - NO CASTING
      callback(ctx, args.title, args.content);
    });
  }

  StreamSubscription<void> onDeleteAllFolders(
    void Function(EventContext ctx) callback,
  ) {
    return _reducerEmitter.on('delete_all_folders').listen((EventContext ctx) {
      // Pattern match to extract ReducerEvent
      final event = ctx.event;
      if (event is! ReducerEvent) return;

      // Type guard - ensures args is correct type
      final args = event.reducerArgs;
      if (args is! DeleteAllFoldersArgs) return;

      // Extract fields from strongly-typed object - NO CASTING
      callback(ctx);
    });
  }

  StreamSubscription<void> onDeleteAllNotes(
    void Function(EventContext ctx) callback,
  ) {
    return _reducerEmitter.on('delete_all_notes').listen((EventContext ctx) {
      // Pattern match to extract ReducerEvent
      final event = ctx.event;
      if (event is! ReducerEvent) return;

      // Type guard - ensures args is correct type
      final args = event.reducerArgs;
      if (args is! DeleteAllNotesArgs) return;

      // Extract fields from strongly-typed object - NO CASTING
      callback(ctx);
    });
  }

  StreamSubscription<void> onDeleteFolder(
    void Function(EventContext ctx, String path) callback,
  ) {
    return _reducerEmitter.on('delete_folder').listen((EventContext ctx) {
      // Pattern match to extract ReducerEvent
      final event = ctx.event;
      if (event is! ReducerEvent) return;

      // Type guard - ensures args is correct type
      final args = event.reducerArgs;
      if (args is! DeleteFolderArgs) return;

      // Extract fields from strongly-typed object - NO CASTING
      callback(ctx, args.path);
    });
  }

  StreamSubscription<void> onDeleteNote(
    void Function(EventContext ctx, int noteId) callback,
  ) {
    return _reducerEmitter.on('delete_note').listen((EventContext ctx) {
      // Pattern match to extract ReducerEvent
      final event = ctx.event;
      if (event is! ReducerEvent) return;

      // Type guard - ensures args is correct type
      final args = event.reducerArgs;
      if (args is! DeleteNoteArgs) return;

      // Extract fields from strongly-typed object - NO CASTING
      callback(ctx, args.noteId);
    });
  }

  StreamSubscription<void> onInit(void Function(EventContext ctx) callback) {
    return _reducerEmitter.on('init').listen((EventContext ctx) {
      // Pattern match to extract ReducerEvent
      final event = ctx.event;
      if (event is! ReducerEvent) return;

      // Type guard - ensures args is correct type
      final args = event.reducerArgs;
      if (args is! InitArgs) return;

      // Extract fields from strongly-typed object - NO CASTING
      callback(ctx);
    });
  }

  StreamSubscription<void> onUpdateNote(
    void Function(EventContext ctx, int noteId, String title, String content)
    callback,
  ) {
    return _reducerEmitter.on('update_note').listen((EventContext ctx) {
      // Pattern match to extract ReducerEvent
      final event = ctx.event;
      if (event is! ReducerEvent) return;

      // Type guard - ensures args is correct type
      final args = event.reducerArgs;
      if (args is! UpdateNoteArgs) return;

      // Extract fields from strongly-typed object - NO CASTING
      callback(ctx, args.noteId, args.title, args.content);
    });
  }
}
