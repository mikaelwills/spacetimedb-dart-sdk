// GENERATED CODE - DO NOT MODIFY BY HAND

import 'package:spacetimedb_dart_sdk/codegen.dart';

class Entity {
  Entity({
    required this.id,
    required this.x,
    required this.y,
    required this.z,
    required this.health,
  });

  factory Entity.fromJson(Map<String, dynamic> json) {
    return Entity(
      id: Int64(json['id'] ?? 0),
      x: (json['x'] ?? 0.0).toDouble(),
      y: (json['y'] ?? 0.0).toDouble(),
      z: (json['z'] ?? 0.0).toDouble(),
      health: json['health'] ?? 0,
    );
  }

  final Int64 id;

  final double x;

  final double y;

  final double z;

  final int health;

  void encodeBsatn(BsatnEncoder encoder) {
    encoder.writeU64(id);
    encoder.writeF32(x);
    encoder.writeF32(y);
    encoder.writeF32(z);
    encoder.writeU32(health);
  }

  static Entity decodeBsatn(BsatnDecoder decoder) {
    return Entity(
      id: decoder.readU64(),
      x: decoder.readF32(),
      y: decoder.readF32(),
      z: decoder.readF32(),
      health: decoder.readU32(),
    );
  }

  Map<String, dynamic> toJson() {
    return {'id': id.toInt(), 'x': x, 'y': y, 'z': z, 'health': health};
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is Entity &&
            id == other.id &&
            x == other.x &&
            y == other.y &&
            z == other.z &&
            health == other.health;
  }

  @override
  int get hashCode {
    return Object.hash(id, x, y, z, health);
  }

  @override
  String toString() {
    return 'Entity(id: $id, x: $x, y: $y, z: $z, health: $health)';
  }

  Entity copyWith({Int64? id, double? x, double? y, double? z, int? health}) {
    return Entity(
      id: id ?? this.id,
      x: x ?? this.x,
      y: y ?? this.y,
      z: z ?? this.z,
      health: health ?? this.health,
    );
  }
}

class EntityDecoder extends RowDecoder<Entity> {
  @override
  Entity decode(BsatnDecoder decoder) {
    return Entity.decodeBsatn(decoder);
  }

  @override
  Int64? getPrimaryKey(Entity row) {
    return row.id;
  }

  @override
  Map<String, dynamic>? toJson(Entity row) {
    return row.toJson();
  }

  @override
  Entity? fromJson(Map<String, dynamic> json) {
    return Entity.fromJson(json);
  }

  @override
  bool get supportsJsonSerialization {
    return true;
  }
}
