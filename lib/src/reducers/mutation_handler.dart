import 'package:spacetimedb_dart_sdk/src/offline/optimistic_change.dart';

abstract class MutationHandler {
  void onMutationQueued(String requestId, List<OptimisticChange>? changes);
  void onOptimisticChanges(String requestId, List<OptimisticChange>? changes);
  void onRollbackOptimistic(String requestId);
  void trySyncNow();
}
