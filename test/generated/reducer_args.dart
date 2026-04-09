// GENERATED REDUCER ARGUMENT CLASSES AND DECODERS - DO NOT MODIFY BY HAND

import 'package:spacetimedb_dart_sdk/codegen.dart';

class CreateFolderArgs {
  CreateFolderArgs({required this.path, required this.name});

  final String path;

  final String name;
}

class CreateFolderArgsDecoder implements ReducerArgDecoder<CreateFolderArgs> {
  const CreateFolderArgsDecoder();

  @override
  CreateFolderArgs? decode(BsatnDecoder decoder) {
    try {
      final path = decoder.readString();
      final name = decoder.readString();
      return CreateFolderArgs(path: path, name: name);
    } catch (e) {
      return null;
    }
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
  CreateNoteArgs? decode(BsatnDecoder decoder) {
    try {
      final title = decoder.readString();
      final content = decoder.readString();
      return CreateNoteArgs(title: title, content: content);
    } catch (e) {
      return null;
    }
  }
}

class DeleteAllFoldersArgs {
  DeleteAllFoldersArgs();
}

class DeleteAllFoldersArgsDecoder
    implements ReducerArgDecoder<DeleteAllFoldersArgs> {
  const DeleteAllFoldersArgsDecoder();

  @override
  DeleteAllFoldersArgs? decode(BsatnDecoder decoder) {
    try {
      return DeleteAllFoldersArgs();
    } catch (e) {
      return null;
    }
  }
}

class DeleteAllNotesArgs {
  DeleteAllNotesArgs();
}

class DeleteAllNotesArgsDecoder
    implements ReducerArgDecoder<DeleteAllNotesArgs> {
  const DeleteAllNotesArgsDecoder();

  @override
  DeleteAllNotesArgs? decode(BsatnDecoder decoder) {
    try {
      return DeleteAllNotesArgs();
    } catch (e) {
      return null;
    }
  }
}

class DeleteFolderArgs {
  DeleteFolderArgs({required this.path});

  final String path;
}

class DeleteFolderArgsDecoder implements ReducerArgDecoder<DeleteFolderArgs> {
  const DeleteFolderArgsDecoder();

  @override
  DeleteFolderArgs? decode(BsatnDecoder decoder) {
    try {
      final path = decoder.readString();
      return DeleteFolderArgs(path: path);
    } catch (e) {
      return null;
    }
  }
}

class DeleteNoteArgs {
  DeleteNoteArgs({required this.noteId});

  final int noteId;
}

class DeleteNoteArgsDecoder implements ReducerArgDecoder<DeleteNoteArgs> {
  const DeleteNoteArgsDecoder();

  @override
  DeleteNoteArgs? decode(BsatnDecoder decoder) {
    try {
      final noteId = decoder.readU32();
      return DeleteNoteArgs(noteId: noteId);
    } catch (e) {
      return null;
    }
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
  UpdateNoteArgs? decode(BsatnDecoder decoder) {
    try {
      final noteId = decoder.readU32();
      final title = decoder.readString();
      final content = decoder.readString();
      return UpdateNoteArgs(noteId: noteId, title: title, content: content);
    } catch (e) {
      return null;
    }
  }
}

const createFolderDef = ReducerDef<CreateFolderArgs>(
  'create_folder',
  CreateFolderArgsDecoder(),
);
const createNoteDef = ReducerDef<CreateNoteArgs>(
  'create_note',
  CreateNoteArgsDecoder(),
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
const updateNoteDef = ReducerDef<UpdateNoteArgs>(
  'update_note',
  UpdateNoteArgsDecoder(),
);
