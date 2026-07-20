// GENERATED CODE - DO NOT MODIFY BY HAND

import 'package:spacetimedb_sdk/codegen.dart';

class ServerPosition {
  ServerPosition({required this.x, required this.y});

  factory ServerPosition.fromJson(Map<String, dynamic> json) {
    return ServerPosition(
      x: (json['x'] ?? 0.0).toDouble(),
      y: (json['y'] ?? 0.0).toDouble(),
    );
  }

  final double x;

  final double y;

  void encodeBsatn(BsatnEncoder encoder) {
    encoder.writeF32(x);
    encoder.writeF32(y);
  }

  static ServerPosition decodeBsatn(BsatnDecoder decoder) {
    return ServerPosition(x: decoder.readF32(), y: decoder.readF32());
  }

  Map<String, dynamic> toJson() {
    return {'x': x, 'y': y};
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is ServerPosition && x == other.x && y == other.y;
  }

  @override
  int get hashCode {
    return Object.hashAll([x, y]);
  }

  @override
  String toString() {
    return 'ServerPosition(x: $x, y: $y)';
  }

  ServerPosition copyWith({double? x, double? y}) {
    return ServerPosition(x: x ?? this.x, y: y ?? this.y);
  }
}
