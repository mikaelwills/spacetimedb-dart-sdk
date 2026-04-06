// GENERATED REDUCER ARGUMENT CLASSES AND DECODERS - DO NOT MODIFY BY HAND

import 'package:spacetimedb_dart_sdk/spacetimedb_dart_sdk.dart';

class CreateFolderArgs {
  CreateFolderArgs({required this.path, required this.name});

  final String path;

  final String name;
}

class CreateFolderArgsDecoder implements ReducerArgDecoder<CreateFolderArgs> {
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
