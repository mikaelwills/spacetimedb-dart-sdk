import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:spacetimedb_sdk/codegen.dart';
import 'package:spacetimedb_sdk/protocol.dart';

// Mock reducer args class
class CreateNoteArgs {
  final String title;
  final String content;

  CreateNoteArgs({required this.title, required this.content});

  @override
  String toString() => 'CreateNoteArgs(title: $title, content: $content)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CreateNoteArgs &&
          runtimeType == other.runtimeType &&
          title == other.title &&
          content == other.content;

  @override
  int get hashCode => title.hashCode ^ content.hashCode;
}

// Mock decoder implementation
class CreateNoteArgsDecoder implements ReducerArgDecoder<CreateNoteArgs> {
  @override
  CreateNoteArgs decode(BsatnDecoder decoder) {
    final title = decoder.readString();
    final content = decoder.readString();
    return CreateNoteArgs(title: title, content: content);
  }
}

void main() {
  group('ReducerRegistry', () {
    late ReducerRegistry registry;

    setUp(() {
      registry = ReducerRegistry();
    });

    test('starts empty', () {
      expect(registry.count, equals(0));
      expect(registry.registeredReducers, isEmpty);
    });

    test('registers decoder successfully', () {
      final def = ReducerDef('create_note', CreateNoteArgsDecoder());
      registry.register(def);

      expect(registry.count, equals(1));
      expect(registry.hasDecoder('create_note'), isTrue);
      expect(registry.registeredReducers, contains('create_note'));
    });

    test('throws on duplicate registration', () {
      final def = ReducerDef('create_note', CreateNoteArgsDecoder());
      registry.register(def);

      expect(() => registry.register(def), throwsArgumentError);
    });

    test('deserializes reducer arguments correctly', () {
      registry.register(ReducerDef('create_note', CreateNoteArgsDecoder()));

      // Encode arguments
      final encoder = BsatnEncoder();
      encoder.writeString('My Title');
      encoder.writeString('My Content');
      final bytes = encoder.toBytes();

      // Deserialize
      final args = registry.deserializeArgs('create_note', bytes);

      expect(args, isA<CreateNoteArgs>());
      if (args is! CreateNoteArgs) {
        fail('Expected CreateNoteArgs but got ${args.runtimeType}');
      }
      expect(args.title, equals('My Title'));
      expect(args.content, equals('My Content'));
    });

    test('returns null for unregistered reducer', () {
      final bytes = Uint8List.fromList([1, 2, 3]);
      final args = registry.deserializeArgs('unknown_reducer', bytes);

      expect(args, isNull);
    });

    test('logs error and returns null for malformed data', () {
      registry.register(ReducerDef('create_note', CreateNoteArgsDecoder()));

      final logs = <(String, String)>[];
      final prevCallback = SdkLogger.onLog;
      SdkLogger.onLog = (level, msg) => logs.add((level, msg));
      addTearDown(() => SdkLogger.onLog = prevCallback);

      final bytes = Uint8List.fromList([1, 2, 3]);
      final args = registry.deserializeArgs('create_note', bytes);

      expect(args, isNull);
      expect(
        logs.where((l) => l.$1 == 'E').map((l) => l.$2),
        contains(predicate<String>((msg) => msg.contains('create_note'))),
        reason: 'decode failure should log an error with the reducer name',
      );
    });

    test('does not log for unregistered reducer (unknown, not failure)', () {
      final logs = <(String, String)>[];
      final prevCallback = SdkLogger.onLog;
      SdkLogger.onLog = (level, msg) => logs.add((level, msg));
      addTearDown(() => SdkLogger.onLog = prevCallback);

      final bytes = Uint8List.fromList([1, 2, 3]);
      final args = registry.deserializeArgs('unknown_reducer', bytes);

      expect(args, isNull);
      expect(
        logs.where((l) => l.$1 == 'E'),
        isEmpty,
        reason: 'unknown reducer should be silent, not logged as error',
      );
    });

    test('handles multiple decoders', () {
      registry.register(ReducerDef('create_note', CreateNoteArgsDecoder()));
      registry.register(ReducerDef('update_note', CreateNoteArgsDecoder()));
      registry.register(ReducerDef('delete_note', CreateNoteArgsDecoder()));

      expect(registry.count, equals(3));
      expect(registry.hasDecoder('create_note'), isTrue);
      expect(registry.hasDecoder('update_note'), isTrue);
      expect(registry.hasDecoder('delete_note'), isTrue);
    });
  });

  // ReducerInfo group deleted: v1 `ReducerCallInfo` has no v2 counterpart on
  // the wire. Caller-side metadata is tracked locally in ReducerCaller's
  // _pendingRequests under v2 — see reducer_caller_test.dart.

  group('UpdateStatus', () {
    test('Committed toString', () {
      final status = Committed();
      expect(status.toString(), equals('Committed()'));
    });

    test('Failed carries decodable UTF-8 bytes', () {
      final status = Failed(Uint8List.fromList('Database error'.codeUnits));
      expect(status.errorMessage, equals('Database error'));
      expect(status.toString(), equals('Failed(message: Database error)'));
    });

    test('InternalError toString', () {
      final status = InternalError('db panic');
      expect(status.toString(), equals('InternalError(message: db panic)'));
    });

    test('sealed class hierarchy with v2 variants', () {
      final UpdateStatus committed = Committed();
      final UpdateStatus failed = Failed(Uint8List.fromList('error'.codeUnits));
      final UpdateStatus internalError = InternalError('panic');
      final UpdateStatus pending = Pending();

      String describe(UpdateStatus status) {
        return switch (status) {
          Committed() => 'success',
          Failed(errorMessage: final msg) => 'failed: $msg',
          InternalError(message: final msg) => 'internal: $msg',
          Pending() => 'pending',
          Dropped() => 'dropped',
        };
      }

      expect(describe(committed), equals('success'));
      expect(describe(failed), equals('failed: error'));
      expect(describe(internalError), equals('internal: panic'));
      expect(describe(pending), equals('pending'));
    });
  });
}
