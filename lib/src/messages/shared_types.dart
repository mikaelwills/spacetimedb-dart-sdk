import 'dart:io';
import 'dart:typed_data';

import 'package:brotli/brotli.dart';
import 'package:fixnum/fixnum.dart';

import '../codec/bsatn_decoder.dart';

/// Row list with optional size hint for efficient decoding
class BsatnRowList {
  final RowSizeHint sizeHint;
  final Uint8List rowsData;

  BsatnRowList({required this.sizeHint, required this.rowsData});

  /// Create an empty BsatnRowList with no rows
  static BsatnRowList empty() {
    return BsatnRowList(
      sizeHint: RowSizeHint.fixedSize(0),
      rowsData: Uint8List(0),
    );
  }

  static BsatnRowList decode(BsatnDecoder decoder) {
    // Read RowSizeHint (enum)
    final hintTag = decoder.readU8();
    final RowSizeHint sizeHint;

    if (hintTag == 0) {
      // FixedSize variant - read row size (u16!)
      final rowSize = decoder.readU16();
      sizeHint = RowSizeHint.fixedSize(rowSize);
    } else if (hintTag == 1) {
      // RowOffsets variant - read offset list
      final numOffsets = decoder.readU32();
      final offsets = List<int>.generate(
        numOffsets,
        (_) => decoder.readU64().toInt(),
      );
      sizeHint = RowSizeHint.rowOffsets(offsets);
    } else {
      throw ArgumentError('Unknown RowSizeHint tag: $hintTag');
    }

    // Read rows_data bytes (Bytes type is encoded as Vec<u8>)
    final length = decoder.readU32();
    final rowsData = decoder.readBytes(length);

    return BsatnRowList(sizeHint: sizeHint, rowsData: rowsData);
  }

  /// Get individual row data chunks
  List<Uint8List> getRows() => sizeHint.splitRows(rowsData);
}

/// Query update with deletes and inserts
class QueryUpdate {
  final BsatnRowList deletes;
  final BsatnRowList inserts;

  QueryUpdate({required this.deletes, required this.inserts});

  static QueryUpdate decode(BsatnDecoder decoder) {
    final deletes = BsatnRowList.decode(decoder);
    final inserts = BsatnRowList.decode(decoder);
    return QueryUpdate(deletes: deletes, inserts: inserts);
  }
}

/// Compressable query update (enum with compression options)
class CompressableQueryUpdate {
  final QueryUpdate update;

  CompressableQueryUpdate(this.update);

  static CompressableQueryUpdate decode(BsatnDecoder decoder) {
    final tag = decoder.readU8();

    if (tag == 0) {
      return CompressableQueryUpdate(QueryUpdate.decode(decoder));
    } else if (tag == 1) {
      final compressed = decoder.readByteArray();
      final decompressed = Uint8List.fromList(brotli.decode(compressed));
      return CompressableQueryUpdate(
        QueryUpdate.decode(BsatnDecoder(decompressed)),
      );
    } else if (tag == 2) {
      final compressed = decoder.readByteArray();
      final decompressed = Uint8List.fromList(gzip.decode(compressed));
      return CompressableQueryUpdate(
        QueryUpdate.decode(BsatnDecoder(decompressed)),
      );
    }

    throw ArgumentError('Unknown CompressableQueryUpdate tag: $tag');
  }
}

/// Table update matching the actual protocol structure
class TableUpdate {
  final int tableId;
  final String tableName;
  final Int64 numRows;
  final List<CompressableQueryUpdate> updates;

  TableUpdate({
    required this.tableId,
    required this.tableName,
    required this.numRows,
    required this.updates,
  });

  static TableUpdate decode(BsatnDecoder decoder) {
    final tableId = decoder.readU32();
    final tableName = decoder.readString();
    final numRows = decoder.readU64();
    final updates = decoder.readList(
      () => CompressableQueryUpdate.decode(decoder),
    );

    return TableUpdate(
      tableId: tableId,
      tableName: tableName,
      numRows: numRows,
      updates: updates,
    );
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
