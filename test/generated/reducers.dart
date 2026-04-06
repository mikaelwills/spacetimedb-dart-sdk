// GENERATED CODE - DO NOT MODIFY BY HAND

import 'dart:async';
import 'package:spacetimedb_dart_sdk/spacetimedb_dart_sdk.dart';
import 'reducer_args.dart';

class Reducers {
  Reducers(this._reducerCaller, this._reducerEmitter);

  final ReducerCaller _reducerCaller;

  final ReducerEmitter _reducerEmitter;

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
    return _reducerEmitter.on('create_note').listen((EventContext ctx) {
      final event = ctx.event;
      if (event is! ReducerEvent) return;
      final args = event.reducerArgs;
      if (args is! CreateNoteArgs) return;
      callback(ctx, args.title, args.content);
    });
  }

  StreamSubscription<void> onDeleteAllFolders(
    void Function(EventContext ctx) callback,
  ) {
    return _reducerEmitter.on('delete_all_folders').listen((EventContext ctx) {
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
    return _reducerEmitter.on('delete_all_notes').listen((EventContext ctx) {
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
    return _reducerEmitter.on('delete_folder').listen((EventContext ctx) {
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
    return _reducerEmitter.on('delete_note').listen((EventContext ctx) {
      final event = ctx.event;
      if (event is! ReducerEvent) return;
      final args = event.reducerArgs;
      if (args is! DeleteNoteArgs) return;
      callback(ctx, args.noteId);
    });
  }

  StreamSubscription<void> onUpdateNote(
    void Function(EventContext ctx, int noteId, String title, String content)
    callback,
  ) {
    return _reducerEmitter.on('update_note').listen((EventContext ctx) {
      final event = ctx.event;
      if (event is! ReducerEvent) return;
      final args = event.reducerArgs;
      if (args is! UpdateNoteArgs) return;
      callback(ctx, args.noteId, args.title, args.content);
    });
  }
}
