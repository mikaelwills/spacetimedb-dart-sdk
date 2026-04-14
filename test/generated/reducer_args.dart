// GENERATED REDUCER ARGUMENT CLASSES AND DECODERS - DO NOT MODIFY BY HAND

import 'package:spacetimedb_dart_sdk/codegen.dart';

class BulkInsertEntitiesArgs {
  BulkInsertEntitiesArgs({required this.count});

  final int count;
}

class BulkInsertEntitiesArgsDecoder
    implements ReducerArgDecoder<BulkInsertEntitiesArgs> {
  const BulkInsertEntitiesArgsDecoder();

  @override
  BulkInsertEntitiesArgs decode(BsatnDecoder decoder) {
    final count = decoder.readU32();
    return BulkInsertEntitiesArgs(count: count);
  }
}

class CreateFolderArgs {
  CreateFolderArgs({required this.path, required this.name});

  final String path;

  final String name;
}

class CreateFolderArgsDecoder implements ReducerArgDecoder<CreateFolderArgs> {
  const CreateFolderArgsDecoder();

  @override
  CreateFolderArgs decode(BsatnDecoder decoder) {
    final path = decoder.readString();
    final name = decoder.readString();
    return CreateFolderArgs(path: path, name: name);
  }
}

class CreateNoteArgs {
  CreateNoteArgs({required this.title, required this.content});

  final String title;

  final String content;
}

class CreateNoteArgsDecoder implements ReducerArgDecoder<CreateNoteArgs> {
  const CreateNoteArgsDecoder();

  @override
  CreateNoteArgs decode(BsatnDecoder decoder) {
    final title = decoder.readString();
    final content = decoder.readString();
    return CreateNoteArgs(title: title, content: content);
  }
}

class CreateNotesBulkArgs {
  CreateNotesBulkArgs({required this.count, required this.titlePrefix});

  final int count;

  final String titlePrefix;
}

class CreateNotesBulkArgsDecoder
    implements ReducerArgDecoder<CreateNotesBulkArgs> {
  const CreateNotesBulkArgsDecoder();

  @override
  CreateNotesBulkArgs decode(BsatnDecoder decoder) {
    final count = decoder.readU32();
    final titlePrefix = decoder.readString();
    return CreateNotesBulkArgs(count: count, titlePrefix: titlePrefix);
  }
}

class CreateTaggedItemArgs {
  CreateTaggedItemArgs({
    required this.id,
    required this.name,
    required this.tagIds,
    required this.labels,
  });

  final int id;

  final String name;

  final List<Int64> tagIds;

  final List<String> labels;
}

class CreateTaggedItemArgsDecoder
    implements ReducerArgDecoder<CreateTaggedItemArgs> {
  const CreateTaggedItemArgsDecoder();

  @override
  CreateTaggedItemArgs decode(BsatnDecoder decoder) {
    final id = decoder.readU32();
    final name = decoder.readString();
    final tagIds = decoder.readArray<Int64>(() => decoder.readU64());
    final labels = decoder.readArray<String>(() => decoder.readString());
    return CreateTaggedItemArgs(
      id: id,
      name: name,
      tagIds: tagIds,
      labels: labels,
    );
  }
}

class DeleteAllFoldersArgs {
  DeleteAllFoldersArgs();
}

class DeleteAllFoldersArgsDecoder
    implements ReducerArgDecoder<DeleteAllFoldersArgs> {
  const DeleteAllFoldersArgsDecoder();

  @override
  DeleteAllFoldersArgs decode(BsatnDecoder decoder) {
    return DeleteAllFoldersArgs();
  }
}

class DeleteAllNotesArgs {
  DeleteAllNotesArgs();
}

class DeleteAllNotesArgsDecoder
    implements ReducerArgDecoder<DeleteAllNotesArgs> {
  const DeleteAllNotesArgsDecoder();

  @override
  DeleteAllNotesArgs decode(BsatnDecoder decoder) {
    return DeleteAllNotesArgs();
  }
}

class DeleteFolderArgs {
  DeleteFolderArgs({required this.path});

  final String path;
}

class DeleteFolderArgsDecoder implements ReducerArgDecoder<DeleteFolderArgs> {
  const DeleteFolderArgsDecoder();

  @override
  DeleteFolderArgs decode(BsatnDecoder decoder) {
    final path = decoder.readString();
    return DeleteFolderArgs(path: path);
  }
}

class DeleteNoteArgs {
  DeleteNoteArgs({required this.noteId});

  final int noteId;
}

class DeleteNoteArgsDecoder implements ReducerArgDecoder<DeleteNoteArgs> {
  const DeleteNoteArgsDecoder();

  @override
  DeleteNoteArgs decode(BsatnDecoder decoder) {
    final noteId = decoder.readU32();
    return DeleteNoteArgs(noteId: noteId);
  }
}

class DiagInsertFiveArgs {
  DiagInsertFiveArgs();
}

class DiagInsertFiveArgsDecoder
    implements ReducerArgDecoder<DiagInsertFiveArgs> {
  const DiagInsertFiveArgsDecoder();

  @override
  DiagInsertFiveArgs decode(BsatnDecoder decoder) {
    return DiagInsertFiveArgs();
  }
}

class MixedNoteBatchArgs {
  MixedNoteBatchArgs({
    required this.inserts,
    required this.updates,
    required this.deletes,
    required this.marker,
  });

  final int inserts;

  final int updates;

  final int deletes;

  final String marker;
}

class MixedNoteBatchArgsDecoder
    implements ReducerArgDecoder<MixedNoteBatchArgs> {
  const MixedNoteBatchArgsDecoder();

  @override
  MixedNoteBatchArgs decode(BsatnDecoder decoder) {
    final inserts = decoder.readU32();
    final updates = decoder.readU32();
    final deletes = decoder.readU32();
    final marker = decoder.readString();
    return MixedNoteBatchArgs(
      inserts: inserts,
      updates: updates,
      deletes: deletes,
      marker: marker,
    );
  }
}

class MutateRandomEntitiesArgs {
  MutateRandomEntitiesArgs({required this.count, required this.seed});

  final int count;

  final Int64 seed;
}

class MutateRandomEntitiesArgsDecoder
    implements ReducerArgDecoder<MutateRandomEntitiesArgs> {
  const MutateRandomEntitiesArgsDecoder();

  @override
  MutateRandomEntitiesArgs decode(BsatnDecoder decoder) {
    final count = decoder.readU32();
    final seed = decoder.readU64();
    return MutateRandomEntitiesArgs(count: count, seed: seed);
  }
}

class NoOpArgs {
  NoOpArgs();
}

class NoOpArgsDecoder implements ReducerArgDecoder<NoOpArgs> {
  const NoOpArgsDecoder();

  @override
  NoOpArgs decode(BsatnDecoder decoder) {
    return NoOpArgs();
  }
}

class UpdateAllNotesArgs {
  UpdateAllNotesArgs({required this.newContent});

  final String newContent;
}

class UpdateAllNotesArgsDecoder
    implements ReducerArgDecoder<UpdateAllNotesArgs> {
  const UpdateAllNotesArgsDecoder();

  @override
  UpdateAllNotesArgs decode(BsatnDecoder decoder) {
    final newContent = decoder.readString();
    return UpdateAllNotesArgs(newContent: newContent);
  }
}

class UpdateNoteArgs {
  UpdateNoteArgs({
    required this.noteId,
    required this.title,
    required this.content,
  });

  final int noteId;

  final String title;

  final String content;
}

class UpdateNoteArgsDecoder implements ReducerArgDecoder<UpdateNoteArgs> {
  const UpdateNoteArgsDecoder();

  @override
  UpdateNoteArgs decode(BsatnDecoder decoder) {
    final noteId = decoder.readU32();
    final title = decoder.readString();
    final content = decoder.readString();
    return UpdateNoteArgs(noteId: noteId, title: title, content: content);
  }
}

const bulkInsertEntitiesDef = ReducerDef<BulkInsertEntitiesArgs>(
  'bulk_insert_entities',
  BulkInsertEntitiesArgsDecoder(),
);
const createFolderDef = ReducerDef<CreateFolderArgs>(
  'create_folder',
  CreateFolderArgsDecoder(),
);
const createNoteDef = ReducerDef<CreateNoteArgs>(
  'create_note',
  CreateNoteArgsDecoder(),
);
const createNotesBulkDef = ReducerDef<CreateNotesBulkArgs>(
  'create_notes_bulk',
  CreateNotesBulkArgsDecoder(),
);
const createTaggedItemDef = ReducerDef<CreateTaggedItemArgs>(
  'create_tagged_item',
  CreateTaggedItemArgsDecoder(),
);
const deleteAllFoldersDef = ReducerDef<DeleteAllFoldersArgs>(
  'delete_all_folders',
  DeleteAllFoldersArgsDecoder(),
);
const deleteAllNotesDef = ReducerDef<DeleteAllNotesArgs>(
  'delete_all_notes',
  DeleteAllNotesArgsDecoder(),
);
const deleteFolderDef = ReducerDef<DeleteFolderArgs>(
  'delete_folder',
  DeleteFolderArgsDecoder(),
);
const deleteNoteDef = ReducerDef<DeleteNoteArgs>(
  'delete_note',
  DeleteNoteArgsDecoder(),
);
const diagInsertFiveDef = ReducerDef<DiagInsertFiveArgs>(
  'diag_insert_five',
  DiagInsertFiveArgsDecoder(),
);
const mixedNoteBatchDef = ReducerDef<MixedNoteBatchArgs>(
  'mixed_note_batch',
  MixedNoteBatchArgsDecoder(),
);
const mutateRandomEntitiesDef = ReducerDef<MutateRandomEntitiesArgs>(
  'mutate_random_entities',
  MutateRandomEntitiesArgsDecoder(),
);
const noOpDef = ReducerDef<NoOpArgs>('no_op', NoOpArgsDecoder());
const updateAllNotesDef = ReducerDef<UpdateAllNotesArgs>(
  'update_all_notes',
  UpdateAllNotesArgsDecoder(),
);
const updateNoteDef = ReducerDef<UpdateNoteArgs>(
  'update_note',
  UpdateNoteArgsDecoder(),
);
