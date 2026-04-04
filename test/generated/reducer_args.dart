// GENERATED REDUCER ARGUMENT CLASSES AND DECODERS - DO NOT MODIFY BY HAND

import 'package:spacetimedb_dart_sdk/spacetimedb_dart_sdk.dart';

/// Arguments for the create_folder reducer
class CreateFolderArgs {
  final String path;
  final String name;
  CreateFolderArgs({required this.path, required this.name});
}

/// Decoder for create_folder reducer arguments
class CreateFolderArgsDecoder implements ReducerArgDecoder<CreateFolderArgs> {
  @override
  CreateFolderArgs? decode(BsatnDecoder decoder) {
    try {
      final path = decoder.readString();
      final name = decoder.readString();

      return CreateFolderArgs(path: path, name: name);
    } catch (e) {
      return null; // Deserialization failed
    }
  }
}

/// Arguments for the create_note reducer
class CreateNoteArgs {
  final String title;
  final String content;
  CreateNoteArgs({required this.title, required this.content});
}

/// Decoder for create_note reducer arguments
class CreateNoteArgsDecoder implements ReducerArgDecoder<CreateNoteArgs> {
  @override
  CreateNoteArgs? decode(BsatnDecoder decoder) {
    try {
      final title = decoder.readString();
      final content = decoder.readString();

      return CreateNoteArgs(title: title, content: content);
    } catch (e) {
      return null; // Deserialization failed
    }
  }
}

/// Arguments for the delete_all_folders reducer
class DeleteAllFoldersArgs {
  DeleteAllFoldersArgs();
}

/// Decoder for delete_all_folders reducer arguments
class DeleteAllFoldersArgsDecoder
    implements ReducerArgDecoder<DeleteAllFoldersArgs> {
  @override
  DeleteAllFoldersArgs? decode(BsatnDecoder decoder) {
    try {
      return DeleteAllFoldersArgs();
    } catch (e) {
      return null; // Deserialization failed
    }
  }
}

/// Arguments for the delete_all_notes reducer
class DeleteAllNotesArgs {
  DeleteAllNotesArgs();
}

/// Decoder for delete_all_notes reducer arguments
class DeleteAllNotesArgsDecoder
    implements ReducerArgDecoder<DeleteAllNotesArgs> {
  @override
  DeleteAllNotesArgs? decode(BsatnDecoder decoder) {
    try {
      return DeleteAllNotesArgs();
    } catch (e) {
      return null; // Deserialization failed
    }
  }
}

/// Arguments for the delete_folder reducer
class DeleteFolderArgs {
  final String path;
  DeleteFolderArgs({required this.path});
}

/// Decoder for delete_folder reducer arguments
class DeleteFolderArgsDecoder implements ReducerArgDecoder<DeleteFolderArgs> {
  @override
  DeleteFolderArgs? decode(BsatnDecoder decoder) {
    try {
      final path = decoder.readString();

      return DeleteFolderArgs(path: path);
    } catch (e) {
      return null; // Deserialization failed
    }
  }
}

/// Arguments for the delete_note reducer
class DeleteNoteArgs {
  final int noteId;
  DeleteNoteArgs({required this.noteId});
}

/// Decoder for delete_note reducer arguments
class DeleteNoteArgsDecoder implements ReducerArgDecoder<DeleteNoteArgs> {
  @override
  DeleteNoteArgs? decode(BsatnDecoder decoder) {
    try {
      final noteId = decoder.readU32();

      return DeleteNoteArgs(noteId: noteId);
    } catch (e) {
      return null; // Deserialization failed
    }
  }
}

/// Arguments for the init reducer
class InitArgs {
  InitArgs();
}

/// Decoder for init reducer arguments
class InitArgsDecoder implements ReducerArgDecoder<InitArgs> {
  @override
  InitArgs? decode(BsatnDecoder decoder) {
    try {
      return InitArgs();
    } catch (e) {
      return null; // Deserialization failed
    }
  }
}

/// Arguments for the update_note reducer
class UpdateNoteArgs {
  final int noteId;
  final String title;
  final String content;
  UpdateNoteArgs({
    required this.noteId,
    required this.title,
    required this.content,
  });
}

/// Decoder for update_note reducer arguments
class UpdateNoteArgsDecoder implements ReducerArgDecoder<UpdateNoteArgs> {
  @override
  UpdateNoteArgs? decode(BsatnDecoder decoder) {
    try {
      final noteId = decoder.readU32();
      final title = decoder.readString();
      final content = decoder.readString();

      return UpdateNoteArgs(noteId: noteId, title: title, content: content);
    } catch (e) {
      return null; // Deserialization failed
    }
  }
}
