import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:spacetimedb_sdk/codegen.dart';

Future<T> waitForInsert<T>(
  TableCache<T> table,
  bool Function(T) condition, {
  Duration timeout = const Duration(seconds: 5),
}) {
  final completer = Completer<T>();
  void listener() {
    final batch = table.lastBatch.value;
    if (batch == null) return;
    for (final event in batch.events) {
      if (event is TableInsertEvent<T> && condition(event.row)) {
        if (!completer.isCompleted) {
          completer.complete(event.row);
        }
        return;
      }
    }
  }

  table.lastBatch.addListener(listener);
  return completer.future.timeout(timeout).whenComplete(() {
    table.lastBatch.removeListener(listener);
  });
}

Future<T> waitForNextInsert<T>(
  TableCache<T> table, {
  Duration timeout = const Duration(seconds: 5),
}) {
  final completer = Completer<T>();
  void listener() {
    final batch = table.lastBatch.value;
    if (batch == null) return;
    for (final event in batch.events) {
      if (event is TableInsertEvent<T> && !completer.isCompleted) {
        completer.complete(event.row);
        return;
      }
    }
  }

  table.lastBatch.addListener(listener);
  return completer.future.timeout(timeout).whenComplete(() {
    table.lastBatch.removeListener(listener);
  });
}

Future<T> waitForDelete<T>(
  TableCache<T> table,
  bool Function(T) condition, {
  Duration timeout = const Duration(seconds: 5),
}) {
  final completer = Completer<T>();
  void listener() {
    final batch = table.lastBatch.value;
    if (batch == null) return;
    for (final event in batch.events) {
      if (event is TableDeleteEvent<T> && condition(event.row)) {
        if (!completer.isCompleted) {
          completer.complete(event.row);
        }
        return;
      }
    }
  }

  table.lastBatch.addListener(listener);
  return completer.future.timeout(timeout).whenComplete(() {
    table.lastBatch.removeListener(listener);
  });
}

Future<T> waitForNextDelete<T>(
  TableCache<T> table, {
  Duration timeout = const Duration(seconds: 5),
}) {
  final completer = Completer<T>();
  void listener() {
    final batch = table.lastBatch.value;
    if (batch == null) return;
    for (final event in batch.events) {
      if (event is TableDeleteEvent<T> && !completer.isCompleted) {
        completer.complete(event.row);
        return;
      }
    }
  }

  table.lastBatch.addListener(listener);
  return completer.future.timeout(timeout).whenComplete(() {
    table.lastBatch.removeListener(listener);
  });
}

Future<({T oldRow, T newRow})> waitForUpdate<T>(
  TableCache<T> table,
  bool Function(T oldRow, T newRow) condition, {
  Duration timeout = const Duration(seconds: 5),
}) {
  final completer = Completer<({T oldRow, T newRow})>();
  void listener() {
    final batch = table.lastBatch.value;
    if (batch == null) return;
    for (final event in batch.events) {
      if (event is TableUpdateEvent<T> &&
          condition(event.oldRow, event.newRow)) {
        if (!completer.isCompleted) {
          completer.complete((oldRow: event.oldRow, newRow: event.newRow));
        }
        return;
      }
    }
  }

  table.lastBatch.addListener(listener);
  return completer.future.timeout(timeout).whenComplete(() {
    table.lastBatch.removeListener(listener);
  });
}

Future<TableEvent<T>> waitForEvent<T>(
  TableCache<T> table, {
  bool Function(TableEvent<T>)? condition,
  Duration timeout = const Duration(seconds: 5),
}) {
  final completer = Completer<TableEvent<T>>();
  void listener() {
    final batch = table.lastBatch.value;
    if (batch == null) return;
    for (final event in batch.events) {
      if (condition == null || condition(event)) {
        if (!completer.isCompleted) {
          completer.complete(event);
        }
        return;
      }
    }
  }

  table.lastBatch.addListener(listener);
  return completer.future.timeout(timeout).whenComplete(() {
    table.lastBatch.removeListener(listener);
  });
}

class EventCollector<T> {
  final TableCache<T> table;
  final List<TableEvent<T>> events = [];
  late final VoidCallback _listener;

  EventCollector(this.table, {bool Function(TableEvent<T>)? filter}) {
    _listener = () {
      final batch = table.lastBatch.value;
      if (batch == null) return;
      for (final event in batch.events) {
        if (filter == null || filter(event)) {
          events.add(event);
        }
      }
    };
    table.lastBatch.addListener(_listener);
  }

  void dispose() {
    table.lastBatch.removeListener(_listener);
  }
}

/// Records every fire of a [ValueListenable], capturing fire count and a
/// snapshot of the value at each fire.
///
/// Used by reactive-invariant tests to assert that N-row transactions fire
/// exactly once, and that the observed values match the post-transaction
/// state. Dispose removes the listener.
class NotifierFireRecorder<T> {
  final ValueListenable<T> listenable;
  int fireCount = 0;
  final List<T> values = [];
  late final VoidCallback _listener;

  NotifierFireRecorder(this.listenable) {
    _listener = () {
      fireCount++;
      values.add(listenable.value);
    };
    listenable.addListener(_listener);
  }

  T? get lastValue => values.isEmpty ? null : values.last;

  void reset() {
    fireCount = 0;
    values.clear();
  }

  void dispose() {
    listenable.removeListener(_listener);
  }
}
