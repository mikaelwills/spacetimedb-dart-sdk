// GENERATED CODE - DO NOT MODIFY BY HAND

import 'package:spacetimedb_sdk/codegen.dart';

class OptionalItem {
  OptionalItem({
    required this.id,
    required this.nickname,
    required this.score,
    required this.resolvedAt,
  });

  factory OptionalItem.fromJson(Map<String, dynamic> json) {
    return OptionalItem(
      id: json['id'] ?? 0,
      nickname: json['nickname'],
      score: json['score'] == null ? null : Int64(json['score']),
      resolvedAt: json['resolvedAt'] == null ? null : Int64(json['resolvedAt']),
    );
  }

  final int id;

  final String? nickname;

  final Int64? score;

  final Int64? resolvedAt;

  void encodeBsatn(BsatnEncoder encoder) {
    encoder.writeU32(id);
    encoder.writeOption<String>(
      nickname,
      (value) => encoder.writeString(value),
    );
    encoder.writeOption<Int64>(score, (value) => encoder.writeU64(value));
    encoder.writeOption<Int64>(resolvedAt, (value) => encoder.writeU64(value));
  }

  static OptionalItem decodeBsatn(BsatnDecoder decoder) {
    return OptionalItem(
      id: decoder.readU32(),
      nickname: decoder.readOption<String>(() => decoder.readString()),
      score: decoder.readOption<Int64>(() => decoder.readU64()),
      resolvedAt: decoder.readOption<Int64>(() => decoder.readU64()),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'nickname': nickname,
      'score': score?.toInt(),
      'resolvedAt': resolvedAt?.toInt(),
    };
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is OptionalItem &&
            id == other.id &&
            nickname == other.nickname &&
            score == other.score &&
            resolvedAt == other.resolvedAt;
  }

  @override
  int get hashCode {
    return Object.hashAll([id, nickname, score, resolvedAt]);
  }

  @override
  String toString() {
    return 'OptionalItem(id: $id, nickname: $nickname, score: $score, resolvedAt: $resolvedAt)';
  }

  OptionalItem copyWith({
    int? id,
    String? nickname,
    Int64? score,
    Int64? resolvedAt,
  }) {
    return OptionalItem(
      id: id ?? this.id,
      nickname: nickname ?? this.nickname,
      score: score ?? this.score,
      resolvedAt: resolvedAt ?? this.resolvedAt,
    );
  }
}

class OptionalItemDecoder extends RowDecoder<OptionalItem> {
  @override
  OptionalItem decode(BsatnDecoder decoder) {
    return OptionalItem.decodeBsatn(decoder);
  }

  @override
  int? getPrimaryKey(OptionalItem row) {
    return row.id;
  }

  @override
  Map<String, dynamic>? toJson(OptionalItem row) {
    return row.toJson();
  }

  @override
  OptionalItem? fromJson(Map<String, dynamic> json) {
    return OptionalItem.fromJson(json);
  }

  @override
  bool get supportsJsonSerialization {
    return true;
  }
}
