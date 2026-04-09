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
    final event = table.lastEvent.value;
    if (event is TableInsertEvent<T> && condition(event.row)) {
      if (!completer.isCompleted) {
        completer.complete(event.row);
      }
    }
  }

  table.lastEvent.addListener(listener);
  return completer.future.timeout(timeout).whenComplete(() {
    table.lastEvent.removeListener(listener);
  });
}

Future<T> waitForNextInsert<T>(
  TableCache<T> table, {
  Duration timeout = const Duration(seconds: 5),
}) {
  final completer = Completer<T>();
  void listener() {
    final event = table.lastEvent.value;
    if (event is TableInsertEvent<T> && !completer.isCompleted) {
      completer.complete(event.row);
    }
  }

  table.lastEvent.addListener(listener);
  return completer.future.timeout(timeout).whenComplete(() {
    table.lastEvent.removeListener(listener);
  });
}

Future<T> waitForDelete<T>(
  TableCache<T> table,
  bool Function(T) condition, {
  Duration timeout = const Duration(seconds: 5),
}) {
  final completer = Completer<T>();
  void listener() {
    final event = table.lastEvent.value;
    if (event is TableDeleteEvent<T> && condition(event.row)) {
      if (!completer.isCompleted) {
        completer.complete(event.row);
      }
    }
  }

  table.lastEvent.addListener(listener);
  return completer.future.timeout(timeout).whenComplete(() {
    table.lastEvent.removeListener(listener);
  });
}

Future<T> waitForNextDelete<T>(
  TableCache<T> table, {
  Duration timeout = const Duration(seconds: 5),
}) {
  final completer = Completer<T>();
  void listener() {
    final event = table.lastEvent.value;
    if (event is TableDeleteEvent<T> && !completer.isCompleted) {
      completer.complete(event.row);
    }
  }

  table.lastEvent.addListener(listener);
  return completer.future.timeout(timeout).whenComplete(() {
    table.lastEvent.removeListener(listener);
  });
}

Future<({T oldRow, T newRow})> waitForUpdate<T>(
  TableCache<T> table,
  bool Function(T oldRow, T newRow) condition, {
  Duration timeout = const Duration(seconds: 5),
}) {
  final completer = Completer<({T oldRow, T newRow})>();
  void listener() {
    final event = table.lastEvent.value;
    if (event is TableUpdateEvent<T> && condition(event.oldRow, event.newRow)) {
      if (!completer.isCompleted) {
        completer.complete((oldRow: event.oldRow, newRow: event.newRow));
      }
    }
  }

  table.lastEvent.addListener(listener);
  return completer.future.timeout(timeout).whenComplete(() {
    table.lastEvent.removeListener(listener);
  });
}

Future<TableEvent<T>> waitForEvent<T>(
  TableCache<T> table, {
  bool Function(TableEvent<T>)? condition,
  Duration timeout = const Duration(seconds: 5),
}) {
  final completer = Completer<TableEvent<T>>();
  void listener() {
    final event = table.lastEvent.value;
    if (event != null && (condition == null || condition(event))) {
      if (!completer.isCompleted) {
        completer.complete(event);
      }
    }
  }

  table.lastEvent.addListener(listener);
  return completer.future.timeout(timeout).whenComplete(() {
    table.lastEvent.removeListener(listener);
  });
}

class EventCollector<T> {
  final TableCache<T> table;
  final List<TableEvent<T>> events = [];
  late final VoidCallback _listener;

  EventCollector(this.table, {bool Function(TableEvent<T>)? filter}) {
    _listener = () {
      final event = table.lastEvent.value;
      if (event != null && (filter == null || filter(event))) {
        events.add(event);
      }
    };
    table.lastEvent.addListener(_listener);
  }

  void dispose() {
    table.lastEvent.removeListener(_listener);
  }
}
