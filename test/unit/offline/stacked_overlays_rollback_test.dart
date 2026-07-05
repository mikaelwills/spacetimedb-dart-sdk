import 'package:test/test.dart';
import 'package:spacetimedb_sdk/codegen.dart';
import 'package:spacetimedb_sdk/protocol.dart';

import '../../generated/note.dart';
import '../../generated/note_status.dart';

Note _note(int id, String content) => Note(
  id: id,
  title: 'n',
  content: content,
  timestamp: Int64(0),
  status: const NoteStatusDraft(),
);

void main() {
  group('stacked optimistic overlays on one pk', () {
    late ClientCache cache;
    late TableCache<Note> table;
    late OptimisticStateManager optimistic;

    setUp(() {
      cache = ClientCache();
      cache.registerDecoder<Note>('note', NoteDecoder());
      table = cache.getTableByTypedName<Note>('note');
      optimistic = OptimisticStateManager(cache);
    });

    tearDown(() => table.dispose());

    test(
      'rolling back the older of two stacked overlays on the same pk keeps the '
      'newer overlay value, not the pre-optimistic snapshot',
      () {
        final server0 = _note(1, 'server-0');
        table.insertRow(server0);

        final editA = _note(1, 'edit-A');
        optimistic.applyOptimisticChanges('rA', [
          OptimisticChange.update('note', server0.toJson(), editA.toJson()),
        ]);
        expect(table.find(1)?.content, 'edit-A');

        final editB = _note(1, 'edit-B');
        optimistic.applyOptimisticChanges('rB', [
          OptimisticChange.update('note', editA.toJson(), editB.toJson()),
        ]);
        expect(table.find(1)?.content, 'edit-B');

        optimistic.rollbackOptimisticChanges('rA');

        expect(
          table.find(1)?.content,
          'edit-B',
          reason:
              'rB is still pending on pk 1; rolling back rA must leave rB\'s '
              'newer overlay in the cache, not resurrect the pre-optimistic '
              'server-0 value',
        );
      },
    );
  });
}
