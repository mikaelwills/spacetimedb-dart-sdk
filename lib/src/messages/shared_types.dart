import 'dart:typed_data';

import '../codec/bsatn_decoder.dart';

/// Row list with optional size hint for efficient decoding
class BsatnRowList {
  final RowSizeHint sizeHint;
  final Uint8List rowsData;

  BsatnRowList({required this.sizeHint, required this.rowsData});

  static BsatnRowList empty() {
    return BsatnRowList(
      sizeHint: RowSizeHint.fixedSize(0),
      rowsData: Uint8List(0),
    );
  }

  static BsatnRowList decode(BsatnDecoder decoder) {
    final hintTag = decoder.readU8();
    final RowSizeHint sizeHint;

    if (hintTag == 0) {
      final rowSize = decoder.readU16();
      sizeHint = RowSizeHint.fixedSize(rowSize);
    } else if (hintTag == 1) {
      final numOffsets = decoder.readU32();
      final offsets = List<int>.generate(
        numOffsets,
        (_) => decoder.readU64().toInt(),
      );
      sizeHint = RowSizeHint.rowOffsets(offsets);
    } else {
      throw ArgumentError('Unknown RowSizeHint tag: $hintTag');
    }

    final length = decoder.readU32();
    final rowsData = decoder.readBytes(length);

    return BsatnRowList(sizeHint: sizeHint, rowsData: rowsData);
  }

  List<Uint8List> getRows() => sizeHint.splitRows(rowsData);
}

/// Rows of a `TableUpdate`, separated by table kind (persistent vs event).
/// Wire: `v2.rs` `TableUpdateRows` sum — tag 0 `PersistentTable`, tag 1 `EventTable`.
sealed class TableUpdateRows {
  const TableUpdateRows();

  static TableUpdateRows decode(BsatnDecoder decoder) {
    final tag = decoder.readU8();
    if (tag == 0) return PersistentTableRows.decode(decoder);
    if (tag == 1) return EventTableRows.decode(decoder);
    throw ArgumentError('Unknown TableUpdateRows tag: $tag');
  }
}

class PersistentTableRows extends TableUpdateRows {
  final BsatnRowList inserts;
  final BsatnRowList deletes;

  const PersistentTableRows({required this.inserts, required this.deletes});

  static PersistentTableRows decode(BsatnDecoder decoder) {
    final inserts = BsatnRowList.decode(decoder);
    final deletes = BsatnRowList.decode(decoder);
    return PersistentTableRows(inserts: inserts, deletes: deletes);
  }
}

class EventTableRows extends TableUpdateRows {
  final BsatnRowList events;

  const EventTableRows({required this.events});

  static EventTableRows decode(BsatnDecoder decoder) {
    final events = BsatnRowList.decode(decoder);
    return EventTableRows(events: events);
  }
}

/// Table update — v2 wire shape per `v2.rs:316-321`.
/// `{ table_name: RawIdentifier, rows: Box<[TableUpdateRows]> }`
class TableUpdate {
  final String tableName;
  final List<TableUpdateRows> rows;

  TableUpdate({required this.tableName, required this.rows});

  static TableUpdate decode(BsatnDecoder decoder) {
    final tableName = decoder.readString();
    final rows = decoder.readList(() => TableUpdateRows.decode(decoder));
    return TableUpdate(tableName: tableName, rows: rows);
  }
}

/// A set of `TableUpdate`s scoped to a client-assigned `QuerySetId`.
/// Wire: `v2.rs:308-314`.
class QuerySetUpdate {
  final int querySetId;
  final List<TableUpdate> tables;

  QuerySetUpdate({required this.querySetId, required this.tables});

  static QuerySetUpdate decode(BsatnDecoder decoder) {
    final querySetId = decoder.readU32();
    final tables = decoder.readList(() => TableUpdate.decode(decoder));
    return QuerySetUpdate(querySetId: querySetId, tables: tables);
  }
}

/// Flat rows-per-table container used by `SubscribeApplied` / `UnsubscribeApplied`
/// / `OneOffQueryResult`. Wire: `v2.rs:223-237`.
class QueryRows {
  final List<SingleTableRows> tables;

  QueryRows({required this.tables});

  static QueryRows decode(BsatnDecoder decoder) {
    final tables = decoder.readList(() => SingleTableRows.decode(decoder));
    return QueryRows(tables: tables);
  }
}

class SingleTableRows {
  final String tableName;
  final BsatnRowList rows;

  SingleTableRows({required this.tableName, required this.rows});

  static SingleTableRows decode(BsatnDecoder decoder) {
    final tableName = decoder.readString();
    final rows = BsatnRowList.decode(decoder);
    return SingleTableRows(tableName: tableName, rows: rows);
  }
}

abstract class RowSizeHint {
  factory RowSizeHint.fixedSize(int size) = _FixedSizeHint;
  factory RowSizeHint.rowOffsets(List<int> offsets) = _RowOffsetsHint;
  List<Uint8List> splitRows(Uint8List data);
}

class _FixedSizeHint implements RowSizeHint {
  final int rowSize;
  _FixedSizeHint(this.rowSize);

  @override
  List<Uint8List> splitRows(Uint8List data) {
    final rows = <Uint8List>[];
    for (int i = 0; i < data.length; i += rowSize) {
      rows.add(data.sublist(i, i + rowSize));
    }
    return rows;
  }
}

class _RowOffsetsHint implements RowSizeHint {
  final List<int> offsets;
  _RowOffsetsHint(this.offsets);

  @override
  List<Uint8List> splitRows(Uint8List data) {
    final rows = <Uint8List>[];
    for (int i = 0; i < offsets.length; i++) {
      final start = offsets[i];
      final end = (i + 1 < offsets.length) ? offsets[i + 1] : data.length;
      rows.add(data.sublist(start, end));
    }
    return rows;
  }
}
