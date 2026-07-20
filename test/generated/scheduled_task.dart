// GENERATED CODE - DO NOT MODIFY BY HAND

import 'package:spacetimedb_sdk/codegen.dart';

class ScheduledTask {
  ScheduledTask({
    required this.scheduledId,
    required this.scheduledAt,
    required this.label,
  });

  factory ScheduledTask.fromJson(Map<String, dynamic> json) {
    return ScheduledTask(
      scheduledId: Int64(json['scheduledId'] ?? 0),
      scheduledAt: ScheduleAt.fromJson(
        Map<String, dynamic>.from(json['scheduledAt'] ?? {}),
      ),
      label: json['label'] ?? '',
    );
  }

  final Int64 scheduledId;

  final ScheduleAt scheduledAt;

  final String label;

  void encodeBsatn(BsatnEncoder encoder) {
    encoder.writeU64(scheduledId);
    scheduledAt.encodeBsatn(encoder);
    encoder.writeString(label);
  }

  static ScheduledTask decodeBsatn(BsatnDecoder decoder) {
    return ScheduledTask(
      scheduledId: decoder.readU64(),
      scheduledAt: ScheduleAt.decodeBsatn(decoder),
      label: decoder.readString(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'scheduledId': scheduledId.toInt(),
      'scheduledAt': scheduledAt.toJson(),
      'label': label,
    };
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is ScheduledTask &&
            scheduledId == other.scheduledId &&
            scheduledAt == other.scheduledAt &&
            label == other.label;
  }

  @override
  int get hashCode {
    return Object.hashAll([scheduledId, scheduledAt, label]);
  }

  @override
  String toString() {
    return 'ScheduledTask(scheduledId: $scheduledId, scheduledAt: $scheduledAt, label: $label)';
  }

  ScheduledTask copyWith({
    Int64? scheduledId,
    ScheduleAt? scheduledAt,
    String? label,
  }) {
    return ScheduledTask(
      scheduledId: scheduledId ?? this.scheduledId,
      scheduledAt: scheduledAt ?? this.scheduledAt,
      label: label ?? this.label,
    );
  }
}

class ScheduledTaskDecoder extends RowDecoder<ScheduledTask> {
  @override
  ScheduledTask decode(BsatnDecoder decoder) {
    return ScheduledTask.decodeBsatn(decoder);
  }

  @override
  Int64? getPrimaryKey(ScheduledTask row) {
    return row.scheduledId;
  }

  @override
  Map<String, dynamic>? toJson(ScheduledTask row) {
    return row.toJson();
  }

  @override
  ScheduledTask? fromJson(Map<String, dynamic> json) {
    return ScheduledTask.fromJson(json);
  }

  @override
  bool get supportsJsonSerialization {
    return true;
  }
}
