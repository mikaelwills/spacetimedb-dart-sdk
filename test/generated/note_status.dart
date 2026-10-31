// GENERATED CODE - DO NOT MODIFY BY HAND

import 'package:spacetimedb_sdk/codegen.dart';

sealed class NoteStatus {
  const NoteStatus();

  factory NoteStatus.decodeBsatn(BsatnDecoder decoder) =>
      switch (decoder.readU8()) {
        0 => NoteStatusDraft.decodeBsatn(decoder),
        1 => NoteStatusPublished.decodeBsatn(decoder),
        2 => NoteStatusArchived.decodeBsatn(decoder),
        final tag => throw Exception('Unknown NoteStatus variant: $tag'),
      };

  factory NoteStatus.fromJson(Map<String, dynamic> json) =>
      switch (json['type'] ?? '') {
        'draft' => NoteStatusDraft.fromJson(json),
        'published' => NoteStatusPublished.fromJson(json),
        'archived' => NoteStatusArchived.fromJson(json),
        final type => throw Exception('Unknown NoteStatus variant: $type'),
      };

  void encodeBsatn(BsatnEncoder encoder);
  Map<String, dynamic> toJson();
}

class NoteStatusDraft extends NoteStatus {
  const NoteStatusDraft();

  factory NoteStatusDraft.decodeBsatn(BsatnDecoder decoder) {
    return const NoteStatusDraft();
  }

  factory NoteStatusDraft.fromJson(Map<String, dynamic> json) {
    return const NoteStatusDraft();
  }

  @override
  void encodeBsatn(BsatnEncoder encoder) {
    encoder.writeU8(0);
  }

  @override
  Map<String, dynamic> toJson() {
    return {'type': 'draft'};
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) || other is NoteStatusDraft;
  }

  @override
  int get hashCode {
    return runtimeType.hashCode;
  }

  @override
  String toString() {
    return 'NoteStatusDraft()';
  }
}

class NoteStatusPublished extends NoteStatus {
  const NoteStatusPublished(this.value);

  factory NoteStatusPublished.decodeBsatn(BsatnDecoder decoder) {
    return NoteStatusPublished(decoder.readU64());
  }

  factory NoteStatusPublished.fromJson(Map<String, dynamic> json) {
    return NoteStatusPublished(Int64(json['value'] ?? 0));
  }

  final Int64 value;

  @override
  void encodeBsatn(BsatnEncoder encoder) {
    encoder.writeU8(1);
    encoder.writeU64(value);
  }

  @override
  Map<String, dynamic> toJson() {
    return {'type': 'published', 'value': value.toInt()};
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is NoteStatusPublished && value == other.value;
  }

  @override
  int get hashCode {
    return value.hashCode;
  }

  @override
  String toString() {
    return 'NoteStatusPublished(value: $value)';
  }
}

class NoteStatusArchived extends NoteStatus {
  const NoteStatusArchived();

  factory NoteStatusArchived.decodeBsatn(BsatnDecoder decoder) {
    return const NoteStatusArchived();
  }

  factory NoteStatusArchived.fromJson(Map<String, dynamic> json) {
    return const NoteStatusArchived();
  }

  @override
  void encodeBsatn(BsatnEncoder encoder) {
    encoder.writeU8(2);
  }

  @override
  Map<String, dynamic> toJson() {
    return {'type': 'archived'};
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) || other is NoteStatusArchived;
  }

  @override
  int get hashCode {
    return runtimeType.hashCode;
  }

  @override
  String toString() {
    return 'NoteStatusArchived()';
  }
}
