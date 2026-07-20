// GENERATED CODE - DO NOT MODIFY BY HAND

import 'package:spacetimedb_sdk/codegen.dart';

class CadenceItem {
  CadenceItem({required this.id, required this.cadence, required this.label});

  factory CadenceItem.fromJson(Map<String, dynamic> json) {
    return CadenceItem(
      id: json['id'] ?? 0,
      cadence: ScheduleAt.fromJson(
        Map<String, dynamic>.from(json['cadence'] ?? {}),
      ),
      label: json['label'] ?? '',
    );
  }

  final int id;

  final ScheduleAt cadence;

  final String label;

  void encodeBsatn(BsatnEncoder encoder) {
    encoder.writeU32(id);
    cadence.encodeBsatn(encoder);
    encoder.writeString(label);
  }

  static CadenceItem decodeBsatn(BsatnDecoder decoder) {
    return CadenceItem(
      id: decoder.readU32(),
      cadence: ScheduleAt.decodeBsatn(decoder),
      label: decoder.readString(),
    );
  }

  Map<String, dynamic> toJson() {
    return {'id': id, 'cadence': cadence.toJson(), 'label': label};
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is CadenceItem &&
            id == other.id &&
            cadence == other.cadence &&
            label == other.label;
  }

  @override
  int get hashCode {
    return Object.hashAll([id, cadence, label]);
  }

  @override
  String toString() {
    return 'CadenceItem(id: $id, cadence: $cadence, label: $label)';
  }

  CadenceItem copyWith({int? id, ScheduleAt? cadence, String? label}) {
    return CadenceItem(
      id: id ?? this.id,
      cadence: cadence ?? this.cadence,
      label: label ?? this.label,
    );
  }
}

class CadenceItemDecoder extends RowDecoder<CadenceItem> {
  @override
  CadenceItem decode(BsatnDecoder decoder) {
    return CadenceItem.decodeBsatn(decoder);
  }

  @override
  int? getPrimaryKey(CadenceItem row) {
    return row.id;
  }

  @override
  Map<String, dynamic>? toJson(CadenceItem row) {
    return row.toJson();
  }

  @override
  CadenceItem? fromJson(Map<String, dynamic> json) {
    return CadenceItem.fromJson(json);
  }

  @override
  bool get supportsJsonSerialization {
    return true;
  }
}
