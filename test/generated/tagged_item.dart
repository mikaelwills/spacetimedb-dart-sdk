// GENERATED CODE - DO NOT MODIFY BY HAND

import 'package:spacetimedb_dart_sdk/codegen.dart';

class TaggedItem {
  TaggedItem({
    required this.id,
    required this.name,
    required this.tagIds,
    required this.labels,
  });

  factory TaggedItem.fromJson(Map<String, dynamic> json) {
    return TaggedItem(
      id: json['id'] ?? 0,
      name: json['name'] ?? '',
      tagIds: (json['tagIds'] ?? []).cast<int>().map((e) => Int64(e)).toList(),
      labels: List<String>.from(json['labels'] ?? []),
    );
  }

  final int id;

  final String name;

  final List<Int64> tagIds;

  final List<String> labels;

  void encodeBsatn(BsatnEncoder encoder) {
    encoder.writeU32(id);
    encoder.writeString(name);
    encoder.writeArray<Int64>(tagIds, (item) => encoder.writeU64(item));
    encoder.writeArray<String>(labels, (item) => encoder.writeString(item));
  }

  static TaggedItem decodeBsatn(BsatnDecoder decoder) {
    return TaggedItem(
      id: decoder.readU32(),
      name: decoder.readString(),
      tagIds: decoder.readArray<Int64>(() => decoder.readU64()),
      labels: decoder.readArray<String>(() => decoder.readString()),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'tagIds': tagIds.map((e) => e.toInt()).toList(),
      'labels': labels,
    };
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is TaggedItem &&
            id == other.id &&
            name == other.name &&
            tagIds == other.tagIds &&
            labels == other.labels;
  }

  @override
  int get hashCode {
    return Object.hash(id, name, tagIds, labels);
  }

  @override
  String toString() {
    return 'TaggedItem(id: $id, name: $name, tagIds: $tagIds, labels: $labels)';
  }

  TaggedItem copyWith({
    int? id,
    String? name,
    List<Int64>? tagIds,
    List<String>? labels,
  }) {
    return TaggedItem(
      id: id ?? this.id,
      name: name ?? this.name,
      tagIds: tagIds ?? this.tagIds,
      labels: labels ?? this.labels,
    );
  }
}

class TaggedItemDecoder extends RowDecoder<TaggedItem> {
  @override
  TaggedItem decode(BsatnDecoder decoder) {
    return TaggedItem.decodeBsatn(decoder);
  }

  @override
  int? getPrimaryKey(TaggedItem row) {
    return row.id;
  }

  @override
  Map<String, dynamic>? toJson(TaggedItem row) {
    return row.toJson();
  }

  @override
  TaggedItem? fromJson(Map<String, dynamic> json) {
    return TaggedItem.fromJson(json);
  }

  @override
  bool get supportsJsonSerialization {
    return true;
  }
}
