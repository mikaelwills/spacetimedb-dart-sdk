import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../offline_storage.dart';
import '../pending_mutation.dart';
import '../../utils/sdk_logger.dart';
import 'atomic_file_store.dart';
import 'lock_manager.dart';

class JsonFileStorage implements OfflineStorage {
  final String basePath;
  final AtomicFileStore _fileStore;
  final LockManager _locks = LockManager();

  Directory? _baseDir;
  File? _mutationsFile;
  File? _syncTimesFile;
  bool _initialized = false;
  bool _disposed = false;
  int _pendingOperations = 0;
  Completer<void>? _allOperationsComplete;

  JsonFileStorage({required this.basePath})
      : _fileStore = AtomicFileStore(basePath);

  Future<T> _tracked<T>(Future<T> Function() operation) async {
    if (_disposed) {
      SdkLogger.w('Operation attempted after dispose, ignoring');
      throw StateError('Storage has been disposed');
    }
    _pendingOperations++;
    try {
      return await operation();
    } finally {
      _pendingOperations--;
      if (_pendingOperations == 0 && _allOperationsComplete != null) {
        _allOperationsComplete!.complete();
        _allOperationsComplete = null;
      }
    }
  }

  @override
  Future<void> initialize() async {
    if (_initialized) return;

    _baseDir = Directory(basePath);
    if (!await _baseDir!.exists()) {
      await _baseDir!.create(recursive: true);
    }
    _mutationsFile = File('$basePath/pending_mutations.json');
    _syncTimesFile = File('$basePath/sync_times.json');

    await _fileStore.recoverFromTempFiles(_baseDir!);
    _initialized = true;
  }

  Future<void> _ensureInitialized() async {
    if (!_initialized) {
      await initialize();
    }
  }

  File _tableFile(String tableName) => File('$basePath/table_$tableName.json');

  @override
  Future<void> saveTableSnapshot(
    String tableName,
    List<Map<String, dynamic>> rows,
  ) async {
    await _tracked(() async {
      await _ensureInitialized();
      await _locks.getTableLock(tableName).synchronized(() async {
        final file = _tableFile(tableName);
        final json = jsonEncode(rows);
        await _fileStore.atomicWrite(file, json);
        await _fileStore.cleanupBackup(file);
      });
    });
  }

  @override
  Future<List<Map<String, dynamic>>?> loadTableSnapshot(
    String tableName,
  ) async {
    return _locks.getTableLock(tableName).synchronized(() async {
      final file = _tableFile(tableName);
      final content = await _fileStore.readWithFallback(file);
      if (content == null) return null;

      try {
        final data = jsonDecode(content) as List;
        await _fileStore.cleanupBackup(file);
        return data.cast<Map<String, dynamic>>();
      } catch (e) {
        SdkLogger.e('Failed to parse table snapshot for "$tableName": $e');
        return null;
      }
    });
  }

  @override
  Future<void> enqueueMutation(PendingMutation mutation) async {
    await _tracked(() async {
      await _ensureInitialized();
      await _locks.mutations.synchronized(() async {
        final mutations = await _loadMutationsUnsafe();
        mutations.add(mutation);
        await _saveMutationsUnsafe(mutations);
      });
    });
  }

  @override
  Future<List<PendingMutation>> getPendingMutations() async {
    await _ensureInitialized();
    return _locks.mutations.synchronized(() => _loadMutationsUnsafe());
  }

  Future<List<PendingMutation>> _loadMutationsUnsafe() async {
    final content = await _fileStore.readWithFallback(_mutationsFile!);
    if (content == null) return [];

    try {
      final data = jsonDecode(content) as List;
      return data
          .map((e) => PendingMutation.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      SdkLogger.e('Failed to parse pending mutations: $e');
      return [];
    }
  }

  @override
  Future<void> dequeueMutation(String requestId) async {
    await _tracked(() async {
      await _locks.mutations.synchronized(() async {
        final mutations = await _loadMutationsUnsafe();
        mutations.removeWhere((m) => m.requestId == requestId);
        await _saveMutationsUnsafe(mutations);
      });
    });
  }

  Future<void> _saveMutationsUnsafe(List<PendingMutation> mutations) async {
    final json = jsonEncode(mutations.map((m) => m.toJson()).toList());
    await _fileStore.atomicWrite(_mutationsFile!, json);
  }

  @override
  Future<void> setLastSyncTime(String tableName, DateTime time) async {
    await _tracked(() async {
      await _ensureInitialized();
      await _locks.syncTimes.synchronized(() async {
        final times = await _loadSyncTimesUnsafe();
        times[tableName] = time.toIso8601String();
        await _saveSyncTimesUnsafe(times);
      });
    });
  }

  @override
  Future<DateTime?> getLastSyncTime(String tableName) async {
    return _locks.syncTimes.synchronized(() async {
      final times = await _loadSyncTimesUnsafe();
      final timeStr = times[tableName];
      if (timeStr == null) return null;
      return DateTime.tryParse(timeStr);
    });
  }

  Future<Map<String, String>> _loadSyncTimesUnsafe() async {
    final content = await _fileStore.readWithFallback(_syncTimesFile!);
    if (content == null) return {};

    try {
      final data = jsonDecode(content) as Map<String, dynamic>;
      return data.cast<String, String>();
    } catch (e) {
      SdkLogger.e('Failed to parse sync times: $e');
      return {};
    }
  }

  Future<void> _saveSyncTimesUnsafe(Map<String, String> times) async {
    final json = jsonEncode(times);
    await _fileStore.atomicWrite(_syncTimesFile!, json);
  }

  @override
  Future<void> clearAll() async {
    await _tracked(() async {
      await _locks.global.synchronized(() async {
        await _locks.mutations.synchronized(() async {
          await _locks.syncTimes.synchronized(() async {
            if (await _baseDir!.exists()) {
              await _baseDir!.delete(recursive: true);
              await _baseDir!.create(recursive: true);
            }
            _locks.clearDynamicLocks();
          });
        });
      });
    });
  }

  @override
  Future<void> clearTableSnapshot(String tableName) async {
    await _tracked(() async {
      await _locks.getTableLock(tableName).synchronized(() async {
        final file = _tableFile(tableName);
        if (await file.exists()) {
          await file.delete();
        }
        await _fileStore.cleanupBackup(file);
      });
    });
  }

  @override
  Future<void> clearMutationQueue() async {
    await _tracked(() async {
      await _locks.mutations.synchronized(() async {
        if (await _mutationsFile!.exists()) {
          await _mutationsFile!.delete();
        }
      });
    });
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    if (_pendingOperations > 0) {
      _allOperationsComplete = Completer<void>();
      await _allOperationsComplete!.future;
    }
  }
}
