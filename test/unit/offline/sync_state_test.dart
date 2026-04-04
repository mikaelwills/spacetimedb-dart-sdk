import 'package:test/test.dart';
import 'package:spacetimedb_dart_sdk/src/offline/sync_state.dart';

void main() {
  group('SyncState', () {
    test('computed properties reflect status correctly', () {
      const idle = SyncState(status: SyncStatus.idle);
      const syncing = SyncState(status: SyncStatus.syncing);
      const error = SyncState(status: SyncStatus.error);

      expect(idle.isIdle, isTrue);
      expect(idle.isSyncing, isFalse);
      expect(idle.hasError, isFalse);

      expect(syncing.isSyncing, isTrue);
      expect(syncing.isIdle, isFalse);

      expect(error.hasError, isTrue);
      expect(error.isIdle, isFalse);
    });

    test('hasPending reflects count', () {
      const noPending = SyncState(pendingCount: 0);
      const withPending = SyncState(pendingCount: 5);

      expect(noPending.hasPending, isFalse);
      expect(withPending.hasPending, isTrue);
    });

    test('copyWith updates only specified fields', () {
      final now = DateTime.now();
      const original = SyncState(status: SyncStatus.idle, pendingCount: 5);

      final updated = original.copyWith(
        status: SyncStatus.syncing,
        lastSyncTime: now,
      );

      expect(updated.status, equals(SyncStatus.syncing));
      expect(updated.pendingCount, equals(5));
      expect(updated.lastSyncTime, equals(now));
    });
  });
}
