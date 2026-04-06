// GENERATED CODE - DO NOT MODIFY BY HAND

import 'package:spacetimedb_dart_sdk/spacetimedb_dart_sdk.dart';

class Folder {
  Folder({required this.path, required this.name, required this.createdAt});

  factory Folder.fromJson(Map<String, dynamic> json) {
    return Folder(
      path: json['path'] ?? '',
      name: json['name'] ?? '',
      createdAt: Int64(json['createdAt'] ?? 0),
    );
  }

  final String path;

  final String name;

  final Int64 createdAt;

  void encodeBsatn(BsatnEncoder encoder) {
    encoder.writeString(path);
    encoder.writeString(name);
    encoder.writeU64(createdAt);
  }

  static Folder decodeBsatn(BsatnDecoder decoder) {
    return Folder(
      path: decoder.readString(),
      name: decoder.readString(),
      createdAt: decoder.readU64(),
    );
  }

  Map<String, dynamic> toJson() {
    return {'path': path, 'name': name, 'createdAt': createdAt.toInt()};
  }
}

class FolderDecoder extends RowDecoder<Folder> {
  @override
  Folder decode(BsatnDecoder decoder) {
    return Folder.decodeBsatn(decoder);
  }

  @override
  String? getPrimaryKey(Folder row) {
    return row.path;
  }

  @override
  Map<String, dynamic>? toJson(Folder row) {
    return row.toJson();
  }

  @override
  Folder? fromJson(Map<String, dynamic> json) {
    return Folder.fromJson(json);
  }

  @override
  bool get supportsJsonSerialization {
    return true;
  }
}
