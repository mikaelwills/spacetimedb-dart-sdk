import 'dart:typed_data';

import '../codec/bsatn_decoder.dart';
import '../codec/bsatn_encoder.dart';
import '../exceptions.dart';
import 'shared_types.dart';

typedef SubscribeBatchSet = ({int querySetId, List<String> queries});

typedef SubscribeSetResult = ({int querySetId, SubscribeSetOutcome outcome});

class SubscribeBatchMessage {
  static const int tag = 5;

  final int requestId;
  final List<SubscribeBatchSet> sets;

  SubscribeBatchMessage({required this.requestId, required this.sets});

  Uint8List encode() {
    final encoder = BsatnEncoder();
    encoder.writeU8(tag);
    encoder.writeU32(requestId);
    encoder.writeU32(sets.length);
    for (final set in sets) {
      encoder.writeU32(set.querySetId);
      encoder.writeU32(set.queries.length);
      for (final query in set.queries) {
        encoder.writeString(query);
      }
    }
    return encoder.toBytes();
  }
}

sealed class SubscribeSetOutcome {
  const SubscribeSetOutcome();

  static SubscribeSetOutcome decode(BsatnDecoder decoder) {
    final tag = decoder.readU8();
    return switch (tag) {
      0 => SubscribeSetApplied(QueryRows.decode(decoder)),
      1 => SubscribeSetError(decoder.readString()),
      _ => throw SpacetimeDbProtocolException(
        'Unknown SubscribeSetOutcome tag: $tag',
      ),
    };
  }
}

class SubscribeSetApplied extends SubscribeSetOutcome {
  final QueryRows rows;

  const SubscribeSetApplied(this.rows);
}

class SubscribeSetError extends SubscribeSetOutcome {
  final String error;

  const SubscribeSetError(this.error);
}

class SubscribeBatchApplied {
  static const int tag = 8;

  final int requestId;
  final List<SubscribeSetResult> results;

  SubscribeBatchApplied({required this.requestId, required this.results});

  static SubscribeBatchApplied decode(BsatnDecoder decoder) {
    final requestId = decoder.readU32();
    final results = decoder.readList<SubscribeSetResult>(() {
      final querySetId = decoder.readU32();
      return (
        querySetId: querySetId,
        outcome: SubscribeSetOutcome.decode(decoder),
      );
    });
    return SubscribeBatchApplied(requestId: requestId, results: results);
  }
}
