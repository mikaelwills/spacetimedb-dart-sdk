import 'dart:async';

class AsyncLock {
  Completer<void>? _completer;

  Future<T> synchronized<T>(Future<T> Function() action) async {
    while (_completer != null) {
      await _completer!.future;
    }
    _completer = Completer<void>();
    try {
      return await action();
    } finally {
      final c = _completer!;
      _completer = null;
      c.complete();
    }
  }
}

class LockManager {
  final AsyncLock global = AsyncLock();
  final AsyncLock mutations = AsyncLock();
  final AsyncLock syncTimes = AsyncLock();
  final Map<String, AsyncLock> _tableLocks = {};

  AsyncLock getTableLock(String tableName) {
    return _tableLocks.putIfAbsent(tableName, () => AsyncLock());
  }

  void clearDynamicLocks() {
    _tableLocks.clear();
  }
}
