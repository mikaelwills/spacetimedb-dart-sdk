import 'dart:async';

import 'package:flutter/foundation.dart';

extension ValueListenableExtensions<T> on ValueListenable<T> {
  /// Resolves on the next value change. Ignores the current value.
  ///
  /// ```dart
  /// await player.positionNotifier.next;
  /// runTween(player.positionNotifier.value);
  /// ```
  Future<T> get next {
    final completer = Completer<T>();
    late VoidCallback listener;
    listener = () {
      if (!completer.isCompleted) {
        removeListener(listener);
        completer.complete(value);
      }
    };
    addListener(listener);
    return completer.future;
  }

  /// Resolves with the first value (current or future) that satisfies
  /// [predicate]. Emits synchronously if the current value already matches.
  ///
  /// ```dart
  /// await client.connection.stateNotifier
  ///     .firstWhere((s) => s is Connected);
  /// ```
  Future<T> firstWhere(bool Function(T) predicate) {
    if (predicate(value)) return Future.value(value);

    final completer = Completer<T>();
    late VoidCallback listener;
    listener = () {
      final v = value;
      if (predicate(v) && !completer.isCompleted) {
        removeListener(listener);
        completer.complete(v);
      }
    };
    addListener(listener);
    return completer.future;
  }

  /// Bridge to `Stream<T>` for consumers interoperating with rxdart,
  /// `StreamBuilder`, or other stream-based ecosystems.
  ///
  /// Emits the current value synchronously on listen, then every subsequent
  /// change. The stream is single-subscription and removes the underlying
  /// listener on cancel.
  ///
  /// ```dart
  /// StreamBuilder<User?>(
  ///   stream: client.currentUser.toStream(),
  ///   builder: (ctx, snap) => ...,
  /// );
  /// ```
  Stream<T> toStream() {
    late StreamController<T> controller;
    late VoidCallback listener;
    listener = () => controller.add(value);

    controller = StreamController<T>(
      onListen: () {
        controller.add(value);
        addListener(listener);
      },
      onCancel: () {
        removeListener(listener);
      },
    );
    return controller.stream;
  }
}

extension ValueListenableFirstNonNull<T extends Object> on ValueListenable<T?> {
  /// Resolves with the first non-null value (current or future).
  ///
  /// Equivalent to `firstWhere((v) => v != null)`, but preserves the
  /// non-nullable return type `Future<T>` rather than `Future<T?>`.
  ///
  /// ```dart
  /// final user = await client.currentUser.firstNonNull();
  /// print('logged in as ${user.name}');
  /// ```
  Future<T> firstNonNull() {
    final current = value;
    if (current != null) return Future.value(current);

    final completer = Completer<T>();
    late VoidCallback listener;
    listener = () {
      final v = value;
      if (v != null && !completer.isCompleted) {
        removeListener(listener);
        completer.complete(v);
      }
    };
    addListener(listener);
    return completer.future;
  }
}
