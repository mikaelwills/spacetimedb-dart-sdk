// GENERATED CODE - DO NOT MODIFY BY HAND

import 'package:spacetimedb_sdk/codegen.dart';

class SingleField {
  SingleField({required this.id});

  factory SingleField.fromJson(Map<String, dynamic> json) {
    return SingleField(id: json['id'] ?? 0);
  }

  final int id;

  void encodeBsatn(BsatnEncoder encoder) {
    encoder.writeU32(id);
  }

  static SingleField decodeBsatn(BsatnDecoder decoder) {
    return SingleField(id: decoder.readU32());
  }

  Map<String, dynamic> toJson() {
    return {'id': id};
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) || other is SingleField && id == other.id;
  }

  @override
  int get hashCode {
    return Object.hashAll([id]);
  }

  @override
  String toString() {
    return 'SingleField(id: $id)';
  }

  SingleField copyWith({int? id}) {
    return SingleField(id: id ?? this.id);
  }
}

class SingleFieldDecoder extends RowDecoder<SingleField> {
  @override
  SingleField decode(BsatnDecoder decoder) {
    return SingleField.decodeBsatn(decoder);
  }

  @override
  int? getPrimaryKey(SingleField row) {
    return row.id;
  }

  @override
  Map<String, dynamic>? toJson(SingleField row) {
    return row.toJson();
  }

  @override
  SingleField? fromJson(Map<String, dynamic> json) {
    return SingleField.fromJson(json);
  }

  @override
  bool get supportsJsonSerialization {
    return true;
  }
}
