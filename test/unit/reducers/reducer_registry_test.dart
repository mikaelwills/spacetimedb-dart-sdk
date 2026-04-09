import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:spacetimedb_dart_sdk/codegen.dart';
import 'package:spacetimedb_dart_sdk/protocol.dart';

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
  CreateNoteArgs? decode(BsatnDecoder decoder) {
    try {
      final title = decoder.readString();
      final content = decoder.readString();
      return CreateNoteArgs(title: title, content: content);
    } catch (e) {
      return null;
    }
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

    test('returns null for malformed data', () {
      registry.register(ReducerDef('create_note', CreateNoteArgsDecoder()));

      final bytes = Uint8List.fromList([1, 2, 3]);
      final args = registry.deserializeArgs('create_note', bytes);

      expect(args, isNull);
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

  group('ReducerInfo', () {
    test('decodes correctly', () {
      final encoder = BsatnEncoder();
      encoder.writeString('create_note'); // reducerName
      encoder.writeU32(42); // reducerId
      encoder.writeU32(10); // args length
      encoder.writeBytes(
        Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]),
      ); // args
      encoder.writeU32(123); // requestId

      final decoder = BsatnDecoder(encoder.toBytes());
      final info = ReducerInfo.decode(decoder);

      expect(info.reducerName, equals('create_note'));
      expect(info.reducerId, equals(42));
      expect(info.args.length, equals(10));
      expect(
        info.args,
        equals(Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8, 9, 10])),
      );
      expect(info.requestId, equals(123));
    });

    test('handles empty args', () {
      final encoder = BsatnEncoder();
      encoder.writeString('ping'); // reducerName
      encoder.writeU32(1); // reducerId
      encoder.writeU32(0); // no args
      encoder.writeU32(456); // requestId

      final decoder = BsatnDecoder(encoder.toBytes());
      final info = ReducerInfo.decode(decoder);

      expect(info.reducerName, equals('ping'));
      expect(info.reducerId, equals(1));
      expect(info.args.length, equals(0));
      expect(info.requestId, equals(456));
    });
  });

  group('UpdateStatus', () {
    test('Committed toString', () {
      final status = Committed();
      expect(status.toString(), equals('Committed()'));
    });

    test('Failed toString', () {
      final status = Failed('Database error');
      expect(status.toString(), equals('Failed(message: Database error)'));
    });

    test('OutOfEnergy toString', () {
      final status = OutOfEnergy('Budget exceeded: 1000/500');
      expect(
        status.toString(),
        equals('OutOfEnergy(budgetInfo: Budget exceeded: 1000/500)'),
      );
    });

    test('sealed class hierarchy', () {
      final UpdateStatus committed = Committed();
      final UpdateStatus failed = Failed('error');
      final UpdateStatus outOfEnergy = OutOfEnergy('budget');
      final UpdateStatus pending = Pending();

      // Can use switch with exhaustive matching
      String describe(UpdateStatus status) {
        return switch (status) {
          Committed() => 'success',
          Failed(message: final msg) => 'failed: $msg',
          OutOfEnergy(budgetInfo: final info) => 'out of energy: $info',
          Pending() => 'pending',
          Dropped() => 'dropped',
        };
      }

      expect(describe(committed), equals('success'));
      expect(describe(failed), equals('failed: error'));
      expect(describe(outOfEnergy), equals('out of energy: budget'));
      expect(describe(pending), equals('pending'));
    });
  });
}
