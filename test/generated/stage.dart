// GENERATED CODE - DO NOT MODIFY BY HAND

import 'package:spacetimedb_sdk/codegen.dart';

class Stage {
  Stage({required this.id, required this.class_});

  factory Stage.fromJson(Map<String, dynamic> json) {
    return Stage(id: json['id'] ?? 0, class_: json['class'] ?? '');
  }

  final int id;

  final String class_;

  void encodeBsatn(BsatnEncoder encoder) {
    encoder.writeU32(id);
    encoder.writeString(class_);
  }

  static Stage decodeBsatn(BsatnDecoder decoder) {
    return Stage(id: decoder.readU32(), class_: decoder.readString());
  }

  Map<String, dynamic> toJson() {
    return {'id': id, 'class': class_};
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is Stage && id == other.id && class_ == other.class_;
  }

  @override
  int get hashCode {
    return Object.hashAll([id, class_]);
  }

  @override
  String toString() {
    return 'Stage(id: $id, class_: $class_)';
  }

  Stage copyWith({int? id, String? class_}) {
    return Stage(id: id ?? this.id, class_: class_ ?? this.class_);
  }
}

class StageDecoder extends RowDecoder<Stage> {
  @override
  Stage decode(BsatnDecoder decoder) {
    return Stage.decodeBsatn(decoder);
  }

  @override
  int? getPrimaryKey(Stage row) {
    return row.id;
  }

  @override
  Map<String, dynamic>? toJson(Stage row) {
    return row.toJson();
  }

  @override
  Stage? fromJson(Map<String, dynamic> json) {
    return Stage.fromJson(json);
  }

  @override
  bool get supportsJsonSerialization {
    return true;
  }
}
