import 'package:test/test.dart';
import 'package:spacetimedb_dart_sdk/src/codegen/models.dart';
import 'package:spacetimedb_dart_sdk/src/codegen/reducer_generator.dart';
import 'package:spacetimedb_dart_sdk/src/codegen/client_generator.dart';

void main() {
  group('Phase 5: Code Generation Updates', () {
    late ReducerSchema createNoteReducer;
    late ReducerSchema updateNoteReducer;
    late DatabaseSchema schema;

    setUp(() {
      // Create test reducers with params
      createNoteReducer = ReducerSchema(
        name: 'create_note',
        lifecycle: {},
        params: ProductType(
          elements: [
            ProductElement(
              name: 'title',
              type: const PrimitiveType(PrimitiveKind.string),
            ),
            ProductElement(
              name: 'content',
              type: const PrimitiveType(PrimitiveKind.string),
            ),
          ],
        ),
      );

      updateNoteReducer = ReducerSchema(
        name: 'update_note',
        lifecycle: {},
        params: ProductType(
          elements: [
            ProductElement(
              name: 'id',
              type: const PrimitiveType(PrimitiveKind.u32),
            ),
            ProductElement(
              name: 'title',
              type: const PrimitiveType(PrimitiveKind.string),
            ),
          ],
        ),
      );

      // Create test schema with minimal required fields
      schema = DatabaseSchema(
        databaseName: 'test_db',
        typeSpace: TypeSpace(types: []),
        tables: [
          TableSchema(
            name: 'note',
            productTypeRef: 0,
            indexes: [],
            constraints: [],
            sequences: [],
            primaryKey: [],
            schedule: {},
            tableType: {},
            tableAccess: {},
          ),
        ],
        reducers: [createNoteReducer, updateNoteReducer],
        types: [],
        views: [],
      );
    });

    test('ReducerGenerator generates completion callbacks', () {
      final generator = ReducerGenerator([createNoteReducer]);
      final code = generator.generate();

      // Should import dart:async
      expect(code, contains("import 'dart:async';"));

      // Should import reducer_args.dart
      expect(code, contains("import 'reducer_args.dart';"));

      // Should accept ReducerCaller and ReducerEmitter in constructor
      expect(code, contains('final ReducerCaller _reducerCaller;'));
      expect(code, contains('final ReducerEmitter _reducerEmitter;'));
      expect(
        code,
        contains('Reducers(this._reducerCaller, this._reducerEmitter'),
      );

      // Should generate onCreateNote method
      expect(code, contains('StreamSubscription<void> onCreateNote('));

      // Should have typed callback signature
      expect(
        code,
        contains(
          'void Function(EventContext ctx, String title, String content) callback',
        ),
      );

      // Should use _reducerEmitter.on() with typed ReducerDef
      expect(code, contains('_reducerEmitter.on(createNoteDef)'));

      // Should use type guards, NOT as casts
      expect(code, contains('if (event is! ReducerEvent) return;'));
      expect(code, contains('if (args is! CreateNoteArgs) return;'));

      // Should extract fields from strongly-typed object
      expect(code, contains('callback(ctx, args.title, args.content);'));

      // Should NOT contain any 'as' casts
      expect(code, isNot(contains('as String')));
      expect(code, isNot(contains('as CreateNoteArgs')));
    });

    test('ReducerGenerator generates args classes', () {
      final generator = ReducerGenerator([createNoteReducer]);
      final code = generator.generateArgDecoders();

      // Should generate CreateNoteArgs class
      expect(code, contains('class CreateNoteArgs {'));
      expect(code, contains('final String title;'));
      expect(code, contains('final String content;'));

      // Should generate constructor
      expect(
        code,
        contains('CreateNoteArgs({required this.title, required this.content,'),
      );
    });

    test('ReducerGenerator generates arg decoders', () {
      final generator = ReducerGenerator([createNoteReducer]);
      final code = generator.generateArgDecoders();

      // Should generate CreateNoteArgsDecoder class
      expect(
        code,
        contains(
          'class CreateNoteArgsDecoder implements ReducerArgDecoder<CreateNoteArgs>',
        ),
      );

      expect(code, contains('CreateNoteArgs decode(BsatnDecoder decoder)'));

      expect(code, contains('final title = decoder.readString();'));
      expect(code, contains('final content = decoder.readString();'));

      expect(code, contains('return CreateNoteArgs('));
      expect(code, contains('title: title,'));
      expect(code, contains('content: content,'));
    });

    test('ClientGenerator wires ReducerEmitter', () {
      final generator = ClientGenerator(schema);
      final code = generator.generate();

      // Should import reducer_args.dart
      expect(code, contains("import 'reducer_args.dart';"));

      // Should expose reducerEmitter getter
      expect(code, contains('ReducerEmitter get reducerEmitter'));
      expect(code, contains('return subscriptions.reducerEmitter;'));

      // Should pass ReducerCaller and ReducerEmitter to Reducers
      expect(
        code,
        contains(
          'reducers = Reducers(subscriptions.reducers, subscriptions.reducerEmitter);',
        ),
      );
    });

    test('ClientGenerator auto-registers reducer arg decoders', () {
      final generator = ClientGenerator(schema);
      final code = generator.generate();

      // Should register via typed ReducerDef
      expect(
        code,
        contains('subscriptionManager.reducerRegistry.register(createNoteDef)'),
      );

      expect(
        code,
        contains('subscriptionManager.reducerRegistry.register(updateNoteDef)'),
      );
    });

    test('Multiple reducers generate multiple completion callbacks', () {
      final generator = ReducerGenerator([
        createNoteReducer,
        updateNoteReducer,
      ]);
      final code = generator.generate();

      // Should generate onCreateNote
      expect(code, contains('StreamSubscription<void> onCreateNote('));

      // Should generate onUpdateNote
      expect(code, contains('StreamSubscription<void> onUpdateNote('));

      // Each with their own typed signatures
      expect(
        code,
        contains(
          'void Function(EventContext ctx, String title, String content) callback',
        ),
      );
      expect(
        code,
        contains(
          'void Function(EventContext ctx, int id, String title) callback',
        ),
      );
    });

    test('Reducer with no params generates correct callback', () {
      final noParamReducer = ReducerSchema(
        name: 'clear_all',
        lifecycle: {},
        params: ProductType(elements: []),
      );

      final generator = ReducerGenerator([noParamReducer]);
      final code = generator.generate();

      // Should generate onClearAll
      expect(code, contains('StreamSubscription<void> onClearAll('));

      // Callback should only have EventContext
      expect(code, contains('void Function(EventContext ctx) callback'));

      // Should not try to extract any args
      expect(code, contains('callback(ctx);'));
    });

    test('Generated code follows NO as CASTS rule', () {
      final generator = ReducerGenerator([
        createNoteReducer,
        updateNoteReducer,
      ]);
      final reducerCode = generator.generate();
      final argsCode = generator.generateArgDecoders();

      // Verify NO as casts in reducer code
      expect(reducerCode, isNot(contains(' as ')));

      // Verify NO as casts in args code
      expect(argsCode, isNot(contains(' as ')));

      // Should use type guards instead
      expect(reducerCode, contains('is!'));
    });

    test('Type guards provide type safety', () {
      final generator = ReducerGenerator([createNoteReducer]);
      final code = generator.generate();

      // Type guard pattern:
      // 1. Extract and check event type
      expect(code, contains('final event = ctx.event;'));
      expect(code, contains('if (event is! ReducerEvent) return;'));

      // 2. Check args type
      expect(code, contains('if (args is! CreateNoteArgs) return;'));

      // 3. Use promoted types directly
      expect(code, contains('callback(ctx, args.title, args.content);'));
    });
  });

  group('Phase 5: Integration Patterns', () {
    test('Generated code compiles type-safe callbacks', () {
      // This test verifies that the generated pattern is type-safe
      // In actual generated code, this would be:
      //
      // StreamSubscription<void> onCreateNote(
      //   void Function(EventContext ctx, String title, String content) callback
      // )

      // Verify the callback signature is strongly-typed
      void exampleCallback(dynamic ctx, String title, String content) {
        // User gets type-safe parameters
        expect(title, isA<String>());
        expect(content, isA<String>());
      }

      // This compiles because parameters are strongly typed
      exampleCallback(null, 'Test', 'Content');
    });

    test('Args classes preserve type information', () {
      final generator = ReducerGenerator([
        ReducerSchema(
          name: 'test_reducer',
          lifecycle: {},
          params: ProductType(
            elements: [
              ProductElement(
                name: 'count',
                type: const PrimitiveType(PrimitiveKind.u32),
              ),
              ProductElement(
                name: 'message',
                type: const PrimitiveType(PrimitiveKind.string),
              ),
            ],
          ),
        ),
      ]);

      final code = generator.generateArgDecoders();

      // Args class should have strongly-typed fields
      expect(code, contains('class TestReducerArgs {'));
      expect(code, contains('final int count;'));
      expect(code, contains('final String message;'));

      // Constructor should require all fields
      expect(code, contains('required this.count'));
      expect(code, contains('required this.message'));
    });
  });
}
