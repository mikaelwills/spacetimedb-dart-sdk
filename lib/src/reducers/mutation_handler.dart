import 'package:spacetimedb_sdk/src/offline/pending_mutation.dart';

abstract class MutationHandler {
  void onMutationQueued(String requestId, List<OptimisticChange>? changes);
  void onOptimisticChanges(String requestId, List<OptimisticChange>? changes);
  void onRollbackOptimistic(String requestId);
  Future<void> onMutationDropped(PendingMutation mutation, String reason);
  void trySyncNow();
}
