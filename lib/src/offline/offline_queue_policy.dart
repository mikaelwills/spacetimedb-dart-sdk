import 'dart:async';

import 'pending_mutation.dart';

enum OverflowStrategy { rejectNew, dropOldest }

enum ReplayDecision { replay, discard }

/// Controls how the offline mutation queue accepts and replays mutations.
///
/// The default policy preserves the SDK's original behavior exactly:
/// no age limit, no queue bound, every queued mutation replays on reconnect.
///
/// - [maxMutationAge]: mutations older than this at flush time are discarded
///   (optimistic changes rolled back, surfaced as a failed
///   `MutationSyncResult` with `expired: true`) instead of replayed.
/// - [maxQueueLength]: enqueue-time bound. At the limit, [overflow] decides:
///   `rejectNew` throws `SpacetimeDbQueueFullException` before any optimistic
///   change is applied; `dropOldest` evicts and rolls back the oldest queued
///   mutation to make room.
/// - [onBeforeReplay]: per-mutation veto called at flush time. Returning
///   [ReplayDecision.discard] drops the mutation through the same surfaced
///   path as expiry. Must be fast; it runs on the sync path.
class OfflineQueuePolicy {
  final Duration? maxMutationAge;
  final int? maxQueueLength;
  final OverflowStrategy overflow;
  final FutureOr<ReplayDecision> Function(PendingMutation mutation)?
  onBeforeReplay;

  const OfflineQueuePolicy({
    this.maxMutationAge,
    this.maxQueueLength,
    this.overflow = OverflowStrategy.rejectNew,
    this.onBeforeReplay,
  });
}
