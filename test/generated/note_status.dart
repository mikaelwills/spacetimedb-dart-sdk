// GENERATED CODE - DO NOT MODIFY BY HAND

import 'package:spacetimedb_dart_sdk/spacetimedb_dart_sdk.dart';

sealed class NoteStatus {
  const NoteStatus();

  factory NoteStatus.decode(BsatnDecoder decoder) {
    final tag = decoder.readU8();
    switch (tag) {
      case 0:
        return NoteStatusDraft.decode(decoder);
      case 1:
        return NoteStatusPublished.decode(decoder);
      case 2:
        return NoteStatusArchived.decode(decoder);
      default:
        throw Exception('Unknown NoteStatus variant: $tag');
    }
  }

  factory NoteStatus.fromJson(Map<String, dynamic> json) {
    final type = json['type'] ?? '';
    switch (type) {
      case 'draft':
        return NoteStatusDraft.fromJson(json);
      case 'published':
        return NoteStatusPublished.fromJson(json);
      case 'archived':
        return NoteStatusArchived.fromJson(json);
      default:
        throw Exception('Unknown NoteStatus variant: $type');
    }
  }

  void encode(BsatnEncoder encoder);
  Map<String, dynamic> toJson();
}

class NoteStatusDraft extends NoteStatus {
  const NoteStatusDraft();

  factory NoteStatusDraft.decode(BsatnDecoder decoder) {
    return const NoteStatusDraft();
  }

  factory NoteStatusDraft.fromJson(Map<String, dynamic> json) {
    return const NoteStatusDraft();
  }

  @override
  void encode(BsatnEncoder encoder) {
    encoder.writeU8(0);
  }

  @override
  Map<String, dynamic> toJson() {
    return {'type': 'draft'};
  }
}

class NoteStatusPublished extends NoteStatus {
  const NoteStatusPublished(this.value);

  factory NoteStatusPublished.decode(BsatnDecoder decoder) {
    return NoteStatusPublished(decoder.readU64());
  }

  factory NoteStatusPublished.fromJson(Map<String, dynamic> json) {
    return NoteStatusPublished(Int64(json['value'] ?? 0));
  }

  final Int64 value;

  @override
  void encode(BsatnEncoder encoder) {
    encoder.writeU8(1);
    encoder.writeU64(value);
  }

  @override
  Map<String, dynamic> toJson() {
    return {'type': 'published', 'value': value.toInt()};
  }
}

class NoteStatusArchived extends NoteStatus {
  const NoteStatusArchived();

  factory NoteStatusArchived.decode(BsatnDecoder decoder) {
    return const NoteStatusArchived();
  }

  factory NoteStatusArchived.fromJson(Map<String, dynamic> json) {
    return const NoteStatusArchived();
  }

  @override
  void encode(BsatnEncoder encoder) {
    encoder.writeU8(2);
  }

  @override
  Map<String, dynamic> toJson() {
    return {'type': 'archived'};
  }
}
