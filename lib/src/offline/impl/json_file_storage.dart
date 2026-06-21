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
  File? _journalFile;
  File? _syncTimesFile;
  bool _initialized = false;
  bool _disposed = false;
  int _pendingOperations = 0;
  Completer<void>? _allOperationsComplete;

  final List<PendingMutation> _queue = [];
  bool _queueLoaded = false;
  int _journalOpCount = 0;

  JsonFileStorage({required this.basePath})
    : _fileStore = AtomicFileStore(basePath);

  @override
  Future<void> initialize() async {
    if (_initialized) return;

    _baseDir = Directory(basePath);
    if (!await _baseDir!.exists()) {
      await _baseDir!.create(recursive: true);
    }
    _mutationsFile = File('$basePath/pending_mutations.json');
    _journalFile = File('$basePath/pending_mutations.jsonl');
    _syncTimesFile = File('$basePath/sync_times.json');

    await _fileStore.recoverFromTempFiles(_baseDir!);
    _initialized = true;
  }

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
        final data = jsonDecode(content);
        if (data is! List) {
          throw FormatException('Expected JSON list, got ${data.runtimeType}');
        }
        await _fileStore.cleanupBackup(file);
        return data.cast<Map<String, dynamic>>();
      } catch (e) {
        SdkLogger.e('Failed to parse table snapshot for "$tableName": $e');
        final backupFile = File('${file.path}.bak');
        if (await backupFile.exists()) {
          try {
            final backupContent = await backupFile.readAsString();
            final data = jsonDecode(backupContent);
            if (data is! List) {
              throw FormatException(
                'Expected JSON list in backup, got ${data.runtimeType}',
              );
            }
            SdkLogger.i(
              'Recovered table snapshot for "$tableName" from backup',
            );
            return data.cast<Map<String, dynamic>>();
          } catch (backupError) {
            SdkLogger.e('Backup also corrupted for "$tableName": $backupError');
          }
        }
        return null;
      }
    });
  }

  @override
  Future<void> enqueueMutation(PendingMutation mutation) async {
    await _tracked(() async {
      await _ensureInitialized();
      await _locks.mutations.synchronized(() async {
        await _ensureQueueLoadedUnsafe();
        _queue.add(mutation);
        await _appendJournalUnsafe({
          'op': 'enqueue',
          'mutation': mutation.toJson(),
        });
      });
    });
  }

  @override
  Future<List<PendingMutation>> getPendingMutations() async {
    await _ensureInitialized();
    return _locks.mutations.synchronized(() async {
      await _ensureQueueLoadedUnsafe();
      return List<PendingMutation>.of(_queue);
    });
  }

  @override
  Future<void> dequeueMutation(String requestId) async {
    await _tracked(() async {
      await _ensureInitialized();
      await _locks.mutations.synchronized(() async {
        await _ensureQueueLoadedUnsafe();
        _queue.removeWhere((m) => m.requestId == requestId);
        await _appendJournalUnsafe({'op': 'dequeue', 'requestId': requestId});
        await _maybeCompactUnsafe();
      });
    });
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
            _queue.clear();
            _queueLoaded = true;
            _journalOpCount = 0;
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
      await _ensureInitialized();
      await _locks.mutations.synchronized(() async {
        _queue.clear();
        _queueLoaded = true;
        _journalOpCount = 0;
        if (await _mutationsFile!.exists()) {
          await _mutationsFile!.delete();
        }
        if (await _journalFile!.exists()) {
          await _journalFile!.delete();
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

  Future<void> _ensureInitialized() async {
    if (!_initialized) {
      await initialize();
    }
  }

  File _tableFile(String tableName) => File('$basePath/table_$tableName.json');

  Future<void> _ensureQueueLoadedUnsafe() async {
    if (_queueLoaded) return;

    if (await _mutationsFile!.exists()) {
      final legacy = await _loadMutationsUnsafe();
      _queue
        ..clear()
        ..addAll(legacy);
      await _compactUnsafe();
      await _mutationsFile!.delete();
      await _fileStore.cleanupBackup(_mutationsFile!);
      SdkLogger.i(
        'Migrated ${legacy.length} pending mutations from legacy file to journal',
      );
    } else if (await _journalFile!.exists()) {
      await _replayJournalUnsafe();
    }

    _queueLoaded = true;
  }

  Future<void> _replayJournalUnsafe() async {
    final lines = await _journalFile!.readAsLines();
    _queue.clear();
    var ops = 0;
    var skipped = 0;
    for (final line in lines) {
      if (line.trim().isEmpty) continue;
      try {
        final decoded = jsonDecode(line);
        if (decoded is! Map<String, dynamic>) {
          throw const FormatException('journal entry is not an object');
        }
        final op = decoded['op'] ?? '';
        if (op == 'enqueue') {
          final mutationJson = decoded['mutation'];
          if (mutationJson is! Map<String, dynamic>) {
            throw const FormatException('enqueue entry missing mutation');
          }
          _queue.add(PendingMutation.fromJson(mutationJson));
        } else if (op == 'dequeue') {
          final requestId = decoded['requestId'] ?? '';
          _queue.removeWhere((m) => m.requestId == requestId);
        } else {
          throw FormatException('unknown journal op "$op"');
        }
        ops++;
      } catch (e) {
        skipped++;
        SdkLogger.w('Skipping unreadable journal line: $e');
      }
    }
    _journalOpCount = ops;
    if (skipped > 0) {
      SdkLogger.e(
        'Mutation journal recovery: $skipped unreadable line(s) skipped, '
        '${_queue.length} mutations recovered',
      );
      await _compactUnsafe();
    }
  }

  Future<void> _appendJournalUnsafe(Map<String, dynamic> entry) async {
    await _journalFile!.writeAsString(
      '${jsonEncode(entry)}\n',
      mode: FileMode.append,
      flush: true,
    );
    _journalOpCount++;
  }

  Future<void> _maybeCompactUnsafe() async {
    if (_journalOpCount > 64 && _journalOpCount > _queue.length * 4) {
      await _compactUnsafe();
    }
  }

  Future<void> _compactUnsafe() async {
    final buffer = StringBuffer();
    for (final mutation in _queue) {
      buffer.writeln(
        jsonEncode({'op': 'enqueue', 'mutation': mutation.toJson()}),
      );
    }
    await _fileStore.atomicWrite(_journalFile!, buffer.toString());
    await _fileStore.cleanupBackup(_journalFile!);
    _journalOpCount = _queue.length;
  }

  Future<List<PendingMutation>> _loadMutationsUnsafe() async {
    final content = await _fileStore.readWithFallback(_mutationsFile!);
    if (content == null) return [];

    try {
      final data = jsonDecode(content);
      if (data is! List) {
        throw FormatException('Expected JSON list, got ${data.runtimeType}');
      }
      return data
          .whereType<Map<String, dynamic>>()
          .map(PendingMutation.fromJson)
          .toList();
    } catch (e) {
      SdkLogger.e('Failed to parse pending mutations: $e');
      final backupFile = File('${_mutationsFile!.path}.bak');
      if (await backupFile.exists()) {
        try {
          final backupContent = await backupFile.readAsString();
          final data = jsonDecode(backupContent);
          if (data is! List) {
            throw FormatException(
              'Expected JSON list in backup, got ${data.runtimeType}',
            );
          }
          SdkLogger.i('Recovered ${data.length} pending mutations from backup');
          return data
              .whereType<Map<String, dynamic>>()
              .map(PendingMutation.fromJson)
              .toList();
        } catch (backupError) {
          SdkLogger.e(
            'Backup also corrupted, pending mutations lost: $backupError',
          );
        }
      } else {
        SdkLogger.e('No backup file available, pending mutations lost');
      }
      return [];
    }
  }

  Future<Map<String, String>> _loadSyncTimesUnsafe() async {
    final content = await _fileStore.readWithFallback(_syncTimesFile!);
    if (content == null) return {};

    try {
      final data = jsonDecode(content);
      if (data is! Map) {
        throw FormatException('Expected JSON object, got ${data.runtimeType}');
      }
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
}
