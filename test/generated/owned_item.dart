// GENERATED CODE - DO NOT MODIFY BY HAND

import 'package:spacetimedb_sdk/codegen.dart';

class OwnedItem {
  OwnedItem({required this.id, required this.owner, required this.label});

  factory OwnedItem.fromJson(Map<String, dynamic> json) {
    return OwnedItem(
      id: Int64(json['id'] ?? 0),
      owner: Identity.fromJson(json['owner'] ?? ''),
      label: json['label'] ?? '',
    );
  }

  final Int64 id;

  final Identity owner;

  final String label;

  void encodeBsatn(BsatnEncoder encoder) {
    encoder.writeU64(id);
    encoder.writeIdentity(owner);
    encoder.writeString(label);
  }

  static OwnedItem decodeBsatn(BsatnDecoder decoder) {
    return OwnedItem(
      id: decoder.readU64(),
      owner: decoder.readIdentity(),
      label: decoder.readString(),
    );
  }

  Map<String, dynamic> toJson() {
    return {'id': id.toInt(), 'owner': owner.toJson(), 'label': label};
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is OwnedItem &&
            id == other.id &&
            owner == other.owner &&
            label == other.label;
  }

  @override
  int get hashCode {
    return Object.hashAll([id, owner, label]);
  }

  @override
  String toString() {
    return 'OwnedItem(id: $id, owner: $owner, label: $label)';
  }

  OwnedItem copyWith({Int64? id, Identity? owner, String? label}) {
    return OwnedItem(
      id: id ?? this.id,
      owner: owner ?? this.owner,
      label: label ?? this.label,
    );
  }
}

class OwnedItemDecoder extends RowDecoder<OwnedItem> {
  @override
  OwnedItem decode(BsatnDecoder decoder) {
    return OwnedItem.decodeBsatn(decoder);
  }

  @override
  Int64? getPrimaryKey(OwnedItem row) {
    return row.id;
  }

  @override
  Map<String, dynamic>? toJson(OwnedItem row) {
    return row.toJson();
  }

  @override
  OwnedItem? fromJson(Map<String, dynamic> json) {
    return OwnedItem.fromJson(json);
  }

  @override
  bool get supportsJsonSerialization {
    return true;
  }
}
