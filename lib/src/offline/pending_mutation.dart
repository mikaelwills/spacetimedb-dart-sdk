import 'dart:typed_data';

import 'optimistic_change.dart';

export 'optimistic_change.dart';

class PendingMutation {
  final String requestId;
  final String reducerName;
  final Uint8List encodedArgs;
  final DateTime createdAt;
  final List<OptimisticChange>? optimisticChanges;

  PendingMutation({
    required this.requestId,
    required this.reducerName,
    required this.encodedArgs,
    required this.createdAt,
    this.optimisticChanges,
  });

  PendingMutation copyWith({
    String? requestId,
    String? reducerName,
    Uint8List? encodedArgs,
    DateTime? createdAt,
    List<OptimisticChange>? optimisticChanges,
  }) {
    return PendingMutation(
      requestId: requestId ?? this.requestId,
      reducerName: reducerName ?? this.reducerName,
      encodedArgs: encodedArgs ?? this.encodedArgs,
      createdAt: createdAt ?? this.createdAt,
      optimisticChanges: optimisticChanges ?? this.optimisticChanges,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'requestId': requestId,
      'reducerName': reducerName,
      'encodedArgs': encodedArgs.toList(),
      'createdAt': createdAt.toIso8601String(),
      'optimisticChanges': optimisticChanges?.map((c) => c.toJson()).toList(),
    };
  }

  factory PendingMutation.fromJson(Map<String, dynamic> json) {
    final String requestId = json['requestId'] ?? '';
    final String reducerName = json['reducerName'] ?? '';
    final List encodedArgs = json['encodedArgs'] ?? const [];
    final String createdAt = json['createdAt'] ?? '';
    final List? changesJson = json['optimisticChanges'];

    if (requestId.isEmpty || reducerName.isEmpty || createdAt.isEmpty) {
      throw FormatException('Invalid PendingMutation JSON: $json');
    }

    return PendingMutation(
      requestId: requestId,
      reducerName: reducerName,
      encodedArgs: Uint8List.fromList(encodedArgs.cast<int>()),
      createdAt: DateTime.parse(createdAt),
      optimisticChanges:
          changesJson
              ?.whereType<Map<String, dynamic>>()
              .map(OptimisticChange.fromJson)
              .toList(),
    );
  }

  @override
  String toString() {
    return 'PendingMutation(requestId: $requestId, reducer: $reducerName)';
  }
}
