// ignore_for_file: invalid_use_of_protected_member
import 'package:flutter/foundation.dart';
import 'package:spacetimedb_dart_sdk/spacetimedb_dart_sdk.dart';
import 'package:test/test.dart';

void main() {
  group('firstNonNull', () {
    test('returns current non-null value synchronously', () async {
      final notifier = ValueNotifier<String?>('present');
      expect(await notifier.firstNonNull(), equals('present'));
    });

    test('resolves when value becomes non-null later', () async {
      final notifier = ValueNotifier<int?>(null);
      final future = notifier.firstNonNull();
      notifier.value = 42;
      expect(await future, equals(42));
    });

    test('ignores intermediate null changes', () async {
      final notifier = ValueNotifier<int?>(null);
      final future = notifier.firstNonNull();
      notifier.value = null;
      notifier.value = 7;
      expect(await future, equals(7));
    });

    test('does not re-fire after resolving', () async {
      final notifier = ValueNotifier<int?>(null);
      final future = notifier.firstNonNull();
      notifier.value = 1;
      await future;
      notifier.value = 2;
      notifier.value = 3;
      final second = notifier.firstNonNull();
      expect(await second, equals(3));
    });

    test('removes listener after completing (no leak)', () async {
      final notifier = ValueNotifier<int?>(null);
      final future = notifier.firstNonNull();
      notifier.value = 1;
      await future;
      expect(notifier.hasListeners, isFalse);
    });

    test('multiple concurrent calls each resolve independently', () async {
      final notifier = ValueNotifier<int?>(null);
      final a = notifier.firstNonNull();
      final b = notifier.firstNonNull();
      notifier.value = 99;
      expect(await a, equals(99));
      expect(await b, equals(99));
      expect(notifier.hasListeners, isFalse);
    });
  });

  group('firstWhere', () {
    test('returns current matching value synchronously', () async {
      final notifier = ValueNotifier<int>(10);
      expect(await notifier.firstWhere((v) => v >= 5), equals(10));
    });

    test('resolves when predicate first matches', () async {
      final notifier = ValueNotifier<int>(0);
      final future = notifier.firstWhere((v) => v >= 3);
      notifier.value = 1;
      notifier.value = 2;
      notifier.value = 3;
      expect(await future, equals(3));
    });

    test('removes listener after completing', () async {
      final notifier = ValueNotifier<int>(0);
      final future = notifier.firstWhere((v) => v > 0);
      notifier.value = 1;
      await future;
      expect(notifier.hasListeners, isFalse);
    });
  });

  group('next', () {
    test('resolves on next change, ignoring current value', () async {
      final notifier = ValueNotifier<int>(5);
      final future = notifier.next;
      notifier.value = 6;
      expect(await future, equals(6));
    });

    test('does not resolve from current value alone', () async {
      final notifier = ValueNotifier<int>(5);
      final future = notifier.next;
      var resolved = false;
      future.then((_) => resolved = true);
      await Future<void>.delayed(Duration.zero);
      expect(resolved, isFalse);
      notifier.value = 6;
      await future;
      expect(resolved, isTrue);
    });

    test('removes listener after completing', () async {
      final notifier = ValueNotifier<int>(0);
      final future = notifier.next;
      notifier.value = 1;
      await future;
      expect(notifier.hasListeners, isFalse);
    });
  });

  group('toStream', () {
    test('emits current value synchronously on listen', () async {
      final notifier = ValueNotifier<String>('init');
      final events = <String>[];
      final sub = notifier.toStream().listen(events.add);
      await Future<void>.delayed(Duration.zero);
      expect(events, equals(['init']));
      await sub.cancel();
    });

    test('emits every subsequent change', () async {
      final notifier = ValueNotifier<int>(0);
      final events = <int>[];
      final sub = notifier.toStream().listen(events.add);
      await Future<void>.delayed(Duration.zero);
      notifier.value = 1;
      notifier.value = 2;
      notifier.value = 3;
      await Future<void>.delayed(Duration.zero);
      expect(events, equals([0, 1, 2, 3]));
      await sub.cancel();
    });

    test('removes listener on cancel', () async {
      final notifier = ValueNotifier<int>(0);
      final sub = notifier.toStream().listen((_) {});
      await Future<void>.delayed(Duration.zero);
      expect(notifier.hasListeners, isTrue);
      await sub.cancel();
      expect(notifier.hasListeners, isFalse);
    });
  });
}
