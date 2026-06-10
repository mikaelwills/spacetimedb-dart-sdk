import 'dart:typed_data';

/// Greedy count of how many leading queue entries fit into one v3 outbound
/// frame at [maxFrameBytes]. Always returns at least 1 when the queue is
/// non-empty (a single oversized message ships solo).
int countClientMessagesForV3Frame(List<Uint8List> queue, int maxFrameBytes) {
  if (queue.isEmpty) return 0;
  var total = 0;
  var count = 0;
  for (final msg in queue) {
    final next = total + msg.length;
    if (count > 0 && next > maxFrameBytes) break;
    total = next;
    count++;
  }
  return count;
}

/// Concatenate the first [count] queue entries into a single v3 frame
/// payload. No separator, no length prefix — decoders read until end.
Uint8List encodeClientMessagesV3(List<Uint8List> queue, int count) {
  if (count == 0) return Uint8List(0);
  if (count == 1) return queue[0];
  final builder = BytesBuilder(copy: false);
  for (var i = 0; i < count; i++) {
    builder.add(queue[i]);
  }
  return builder.takeBytes();
}
