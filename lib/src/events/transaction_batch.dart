import 'event_context.dart';
import 'table_event.dart';

enum TableEventKind { insert, update, delete }

class TableEventSpec {
  final TableEventKind kind;
  final Object? oldRow;
  final Object? newRow;

  const TableEventSpec.insert(Object? row)
    : kind = TableEventKind.insert,
      oldRow = null,
      newRow = row;

  const TableEventSpec.update(this.oldRow, this.newRow)
    : kind = TableEventKind.update;

  const TableEventSpec.delete(Object? row)
    : kind = TableEventKind.delete,
      oldRow = row,
      newRow = null;
}

class TransactionBatch<T> {
  final EventContext context;
  final List<TableEvent<T>> events;

  TransactionBatch(this.context, this.events);

  Iterable<TableInsertEvent<T>> get inserts =>
      events.whereType<TableInsertEvent<T>>();

  Iterable<TableUpdateEvent<T>> get updates =>
      events.whereType<TableUpdateEvent<T>>();

  Iterable<TableDeleteEvent<T>> get deletes =>
      events.whereType<TableDeleteEvent<T>>();

  int get length => events.length;
  bool get isEmpty => events.isEmpty;
  bool get isNotEmpty => events.isNotEmpty;
}
