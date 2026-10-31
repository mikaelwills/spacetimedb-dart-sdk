import 'package:fixnum/fixnum.dart';

import '../codec/bsatn_encoder.dart';
import '../codec/bsatn_decoder.dart';

sealed class ScheduleAt {
  const ScheduleAt();

  factory ScheduleAt.decodeBsatn(BsatnDecoder decoder) =>
      switch (decoder.readU8()) {
        0 => ScheduleAtInterval(decoder.readI64()),
        1 => ScheduleAtTime(decoder.readI64()),
        final tag => throw Exception('Unknown ScheduleAt variant: $tag'),
      };

  factory ScheduleAt.fromJson(Map<String, dynamic> json) =>
      switch (json['type'] ?? '') {
        'Interval' => ScheduleAtInterval(Int64(json['value'] ?? 0)),
        'Time' => ScheduleAtTime(Int64(json['value'] ?? 0)),
        final type => throw Exception('Unknown ScheduleAt variant: $type'),
      };

  void encodeBsatn(BsatnEncoder encoder);
  Map<String, dynamic> toJson();
}

class ScheduleAtInterval extends ScheduleAt {
  final Int64 micros;

  const ScheduleAtInterval(this.micros);

  @override
  void encodeBsatn(BsatnEncoder encoder) {
    encoder.writeU8(0);
    encoder.writeI64(micros);
  }

  @override
  Map<String, dynamic> toJson() => {
    'type': 'Interval',
    'value': micros.toInt(),
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ScheduleAtInterval && micros == other.micros;

  @override
  int get hashCode => micros.hashCode;

  @override
  String toString() => 'ScheduleAtInterval(micros: $micros)';
}

class ScheduleAtTime extends ScheduleAt {
  final Int64 microsSinceUnixEpoch;

  const ScheduleAtTime(this.microsSinceUnixEpoch);

  @override
  void encodeBsatn(BsatnEncoder encoder) {
    encoder.writeU8(1);
    encoder.writeI64(microsSinceUnixEpoch);
  }

  @override
  Map<String, dynamic> toJson() => {
    'type': 'Time',
    'value': microsSinceUnixEpoch.toInt(),
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ScheduleAtTime &&
          microsSinceUnixEpoch == other.microsSinceUnixEpoch;

  @override
  int get hashCode => microsSinceUnixEpoch.hashCode;

  @override
  String toString() =>
      'ScheduleAtTime(microsSinceUnixEpoch: $microsSinceUnixEpoch)';
}
