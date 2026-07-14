import 'package:test/test.dart';
import 'package:spacetimedb_sdk/codegen.dart';

class _LogRow {
  _LogRow(this.text);
  final String text;
}

class _LogDecoder extends RowDecoder<_LogRow> {
  @override
  bool get hasPrimaryKey => false;

  @override
  _LogRow decode(BsatnDecoder decoder) => _LogRow(decoder.readString());

  @override
  dynamic getPrimaryKey(_LogRow row) => null;

  @override
  bool get supportsJsonSerialization => true;

  @override
  Map<String, dynamic> toJson(_LogRow row) => {'text': row.text};

  @override
  _LogRow fromJson(Map<String, dynamic> json) =>
      _LogRow(json['text'] ?? '');
}

void main() {
  group('no-PK table optimistic-insert rollback', () {
    late ClientCache cache;
    late TableCache<_LogRow> table;
    late OptimisticStateManager optimistic;

    setUp(() {
      cache = ClientCache();
      cache.registerDecoder<_LogRow>('logs', _LogDecoder());
      table = cache.getTableByTypedName<_LogRow>('logs');
      optimistic = OptimisticStateManager(cache);
    });

    tearDown(() => table.dispose());

    test('rolling back an optimistic insert on a no-PK table does not throw', () {
      optimistic.applyOptimisticChanges('r1', [
        OptimisticChange.insert('logs', {'text': 'my-unsynced-log'}),
      ]);
      expect(table.iter().map((r) => r.text), contains('my-unsynced-log'));

      expect(
        () => optimistic.rollbackOptimisticChanges('r1'),
        returnsNormally,
        reason:
            'a no-PK optimistic insert has primaryKey=null; rollback must not '
            'call deleteRow(null) which throws StateError and aborts the loop',
      );
      expect(
        table.iter().map((r) => r.text),
        isNot(contains('my-unsynced-log')),
        reason: 'the optimistic insert must actually be removed on rollback',
      );
    });
  });
}
