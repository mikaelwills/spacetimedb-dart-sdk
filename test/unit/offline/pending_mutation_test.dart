import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:spacetimedb_sdk/src/offline/pending_mutation.dart';

void main() {
  group('PendingMutation', () {
    test('JSON round-trip preserves all fields', () {
      final original = PendingMutation(
        requestId: 'req-xyz',
        reducerName: 'update_note',
        encodedArgs: Uint8List.fromList([10, 20, 30, 40]),
        createdAt: DateTime.utc(2024, 6, 15, 14, 30, 45),
        optimisticChanges: [
          OptimisticChange.insert('notes', {'id': 1, 'title': 'Test'}),
          OptimisticChange.update(
            'notes',
            {'id': 2, 'title': 'Old'},
            {'id': 2, 'title': 'New'},
          ),
          OptimisticChange.delete('notes', {'id': 3}),
        ],
      );

      final json = original.toJson();
      final restored = PendingMutation.fromJson(json);

      expect(restored.requestId, equals(original.requestId));
      expect(restored.reducerName, equals(original.reducerName));
      expect(restored.encodedArgs, equals(original.encodedArgs));
      expect(restored.createdAt, equals(original.createdAt));
      expect(restored.optimisticChanges!.length, equals(3));
      expect(
        restored.optimisticChanges![0].type,
        equals(OptimisticChangeType.insert),
      );
      expect(
        restored.optimisticChanges![1].type,
        equals(OptimisticChangeType.update),
      );
      expect(
        restored.optimisticChanges![2].type,
        equals(OptimisticChangeType.delete),
      );
    });

    test('JSON handles missing optional fields', () {
      final json = {
        'requestId': 'req-123',
        'reducerName': 'create_note',
        'encodedArgs': [1, 2, 3],
        'createdAt': '2024-01-15T10:30:00.000Z',
      };

      final mutation = PendingMutation.fromJson(json);

      expect(mutation.optimisticChanges, isNull);
    });
  });

  group('OptimisticChange', () {
    test('JSON round-trip preserves all change types', () {
      final insert = OptimisticChange.insert('notes', {
        'id': 1,
        'title': 'Test',
      });
      final update = OptimisticChange.update(
        'notes',
        {'id': 1, 'title': 'Old'},
        {'id': 1, 'title': 'New'},
      );
      final delete = OptimisticChange.delete('notes', {'id': 1});

      final restoredInsert = OptimisticChange.fromJson(insert.toJson());
      final restoredUpdate = OptimisticChange.fromJson(update.toJson());
      final restoredDelete = OptimisticChange.fromJson(delete.toJson());

      expect(restoredInsert.type, equals(OptimisticChangeType.insert));
      expect(restoredInsert.newRowJson, equals({'id': 1, 'title': 'Test'}));
      expect(restoredInsert.oldRowJson, isNull);

      expect(restoredUpdate.type, equals(OptimisticChangeType.update));
      expect(restoredUpdate.oldRowJson, equals({'id': 1, 'title': 'Old'}));
      expect(restoredUpdate.newRowJson, equals({'id': 1, 'title': 'New'}));

      expect(restoredDelete.type, equals(OptimisticChangeType.delete));
      expect(restoredDelete.oldRowJson, equals({'id': 1}));
      expect(restoredDelete.newRowJson, isNull);
    });
  });
}
