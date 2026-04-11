import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:spacetimedb_dart_sdk/codegen.dart';

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
