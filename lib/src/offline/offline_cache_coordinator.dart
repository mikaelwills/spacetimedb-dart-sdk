import 'package:spacetimedb_dart_sdk/src/cache/client_cache.dart';
import 'package:spacetimedb_dart_sdk/src/offline/offline_storage.dart';
import 'package:spacetimedb_dart_sdk/src/offline/optimistic_state_manager.dart';
import 'package:spacetimedb_dart_sdk/src/offline/mutation_syncer.dart';
import 'package:spacetimedb_dart_sdk/src/utils/sdk_logger.dart';

class OfflineCacheCoordinator {
  final OfflineStorage _storage;
  final ClientCache _cache;
  final OptimisticStateManager _optimisticState;
  final MutationSyncer _mutationSyncer;

  bool _initialized = false;
  bool _disposed = false;

  OfflineCacheCoordinator({
    required OfflineStorage storage,
    required ClientCache cache,
    required OptimisticStateManager optimisticState,
    required MutationSyncer mutationSyncer,
  }) : _storage = storage,
       _cache = cache,
       _optimisticState = optimisticState,
       _mutationSyncer = mutationSyncer;

  Future<void> ensureInitialized() async {
    if (_initialized) return;
    await _storage.initialize();
    _initialized = true;
  }

  Future<void> loadFromOfflineCache() async {
    try {
      await ensureInitialized();

      for (final tableName in _cache.registeredTableNames) {
        if (_cache.isEventTable(tableName)) continue;
        final rows = await _storage.loadTableSnapshot(tableName);
        if (rows != null && rows.isNotEmpty) {
          final table = _cache.getTableByName(tableName);
          if (table != null && table.decoder.supportsJsonSerialization) {
            table.loadFromSerializable(rows);
            SdkLogger.i(
              'Loaded ${rows.length} rows from offline cache for "$tableName"',
            );
          }
        }
      }

      final pending = await _storage.getPendingMutations();
      for (final mutation in pending) {
        _optimisticState.applyOptimisticChanges(
          mutation.requestId,
          mutation.optimisticChanges,
        );
      }

      await _mutationSyncer.updatePendingCount();
    } catch (e) {
      SdkLogger.e('Error loading from offline cache: $e');
    }
  }

  Future<void> persistTableSnapshots() async {
    if (_disposed) return;
    try {
      for (final tableName in _cache.activatedTableNames) {
        if (_cache.isEventTable(tableName)) continue;
        final table = _cache.getTableByName(tableName);
        if (table != null && table.decoder.supportsJsonSerialization) {
          final rows = table.toSerializable();
          await _storage.saveTableSnapshot(tableName, rows);
          await _storage.setLastSyncTime(tableName, DateTime.now());
        }
      }
    } catch (e) {
      SdkLogger.e('Error persisting table snapshots: $e');
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    await _storage.dispose();
  }
}
