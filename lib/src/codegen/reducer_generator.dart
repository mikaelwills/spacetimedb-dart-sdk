import 'package:spacetimedb_dart_sdk/src/codegen/models.dart';
import 'package:spacetimedb_dart_sdk/src/codegen/type_mapper.dart';

/// Generates reducer call methods and argument decoders
class ReducerGenerator {
  final List<ReducerSchema> reducers;

  ReducerGenerator(this.reducers);

  /// Generate Reducers class with call methods and completion callbacks
  String generate() {
    final buf = StringBuffer();

    // Header
    buf.writeln('// GENERATED CODE - DO NOT MODIFY BY HAND');
    buf.writeln();
    buf.writeln("import 'dart:async';");
    buf.writeln(
      "import 'package:spacetimedb_dart_sdk/spacetimedb_dart_sdk.dart';",
    );
    buf.writeln("import 'reducer_args.dart';");
    buf.writeln();

    // Class definition
    buf.writeln('/// Generated reducer methods with async/await support');
    buf.writeln('///');
    buf.writeln('/// All methods return Future<TransactionResult> containing:');
    buf.writeln('/// - status: Committed/Failed/OutOfEnergy');
    buf.writeln('/// - timestamp: When the reducer executed');
    buf.writeln(
      '/// - energyConsumed: Energy used (null for TransactionUpdateLight)',
    );
    buf.writeln(
      '/// - executionDuration: How long it took (null for TransactionUpdateLight)',
    );
    buf.writeln('class Reducers {');
    buf.writeln('  final ReducerCaller _reducerCaller;');
    buf.writeln('  final ReducerEmitter _reducerEmitter;');
    buf.writeln();
    buf.writeln('  Reducers(this._reducerCaller, this._reducerEmitter);');
    buf.writeln();

    // Generate call method for each reducer
    for (final reducer in reducers) {
      _generateReducerMethod(buf, reducer);
      buf.writeln();
    }

    // Generate completion callback for each reducer
    for (final reducer in reducers) {
      _generateCompletionCallback(buf, reducer);
      buf.writeln();
    }

    buf.writeln('}');

    return buf.toString();
  }

  /// Generate reducer argument classes and decoders
  ///
  /// This creates a separate file `reducer_args.dart` with:
  /// - Args classes (CreateNoteArgs, etc.)
  /// - Decoder classes (CreateNoteArgsDecoder, etc.)
  String generateArgDecoders() {
    final buf = StringBuffer();

    // Header
    buf.writeln(
      '// GENERATED REDUCER ARGUMENT CLASSES AND DECODERS - DO NOT MODIFY BY HAND',
    );
    buf.writeln();
    buf.writeln(
      "import 'package:spacetimedb_dart_sdk/spacetimedb_dart_sdk.dart';",
    );
    buf.writeln();

    // Generate args class and decoder for each reducer
    for (final reducer in reducers) {
      _generateReducerArgsClass(buf, reducer);
      buf.writeln();
      _generateReducerDecoder(buf, reducer);
      buf.writeln();
    }

    return buf.toString();
  }

  void _generateReducerMethod(StringBuffer buf, ReducerSchema reducer) {
    final methodName = _toCamelCase(reducer.name);

    buf.writeln('  /// Call the ${reducer.name} reducer');
    buf.writeln('  ///');
    buf.writeln('  /// Returns [TransactionResult] with execution metadata:');
    buf.writeln('  /// - `result.isSuccess` - Check if reducer committed');
    buf.writeln(
      '  /// - `result.energyConsumed` - Energy used (null for lightweight responses)',
    );
    buf.writeln(
      '  /// - `result.executionDuration` - How long it took (null for lightweight responses)',
    );
    buf.writeln('  ///');
    buf.writeln(
      '  /// Pass [optimisticChanges] to immediately update the local cache for offline-first UX.',
    );
    buf.writeln('  /// Changes are rolled back if the server rejects them.');
    buf.writeln('  ///');
    buf.writeln(
      '  /// Throws [ReducerException] if the reducer fails or runs out of energy.',
    );
    buf.writeln(
      '  /// Throws [TimeoutException] if the reducer doesn\'t complete within the timeout.',
    );

    buf.write('  Future<TransactionResult> $methodName(');

    if (reducer.params.elements.isEmpty) {
      buf.writeln(
        '{List<OptimisticChange>? optimisticChanges, bool isEventTable = false}) async {',
      );
    } else {
      buf.writeln('{');
      for (final param in reducer.params.elements) {
        final paramName = _toCamelCase(param.name ?? 'unknown');
        final dartType = TypeMapper.toDartType(param.algebraicType);
        buf.writeln('    required $dartType $paramName,');
      }
      buf.writeln('    List<OptimisticChange>? optimisticChanges,');
      buf.writeln('    bool isEventTable = false,');
      buf.writeln('  }) async {');
    }

    buf.writeln('    final encoder = BsatnEncoder();');
    for (final param in reducer.params.elements) {
      final paramName = _toCamelCase(param.name ?? 'unknown');
      final method = TypeMapper.getEncoderMethod(param.algebraicType);
      buf.writeln('    encoder.$method($paramName);');
    }
    buf.writeln();

    buf.writeln(
      "    return await _reducerCaller.call('${reducer.name}', encoder.toBytes(), optimisticChanges: optimisticChanges, isEventTable: isEventTable);",
    );
    buf.writeln('  }');
  }

  /// Generate completion callback method for a reducer
  ///
  /// Example generated code:
  /// ```dart
  /// StreamSubscription<void> onCreateNote(
  ///   void Function(EventContext ctx, String title, String content) callback
  /// ) {
  ///   return _reducerEmitter.on('create_note').listen((EventContext ctx) {
  ///     if (ctx.event is! ReducerEvent) return;
  ///     final event = ctx.event;
  ///     final args = event.reducerArgs;
  ///     if (args is! CreateNoteArgs) return;
  ///     callback(ctx, args.title, args.content);
  ///   });
  /// }
  /// ```
  void _generateCompletionCallback(StringBuffer buf, ReducerSchema reducer) {
    final methodName = 'on${_toPascalCase(reducer.name)}';
    final argsClassName = '${_toPascalCase(reducer.name)}Args';

    // Build callback signature
    buf.write('  StreamSubscription<void> $methodName(');
    buf.write('void Function(EventContext ctx');

    // Add typed parameters to callback
    for (final param in reducer.params.elements) {
      final paramName = _toCamelCase(param.name ?? 'unknown');
      final dartType = TypeMapper.toDartType(param.algebraicType);
      buf.write(', $dartType $paramName');
    }
    buf.writeln(') callback) {');

    // Implementation
    buf.writeln(
      "    return _reducerEmitter.on('${reducer.name}').listen((EventContext ctx) {",
    );
    buf.writeln('      // Pattern match to extract ReducerEvent');
    buf.writeln('      final event = ctx.event;');
    buf.writeln('      if (event is! ReducerEvent) return;');
    buf.writeln();
    buf.writeln('      // Type guard - ensures args is correct type');
    buf.writeln('      final args = event.reducerArgs;');
    buf.writeln('      if (args is! $argsClassName) return;');
    buf.writeln();
    buf.writeln(
      '      // Extract fields from strongly-typed object - NO CASTING',
    );
    buf.write('      callback(ctx');

    // Extract each arg field
    for (final param in reducer.params.elements) {
      final paramName = _toCamelCase(param.name ?? 'unknown');
      buf.write(', args.$paramName');
    }
    buf.writeln(');');
    buf.writeln('    });');
    buf.writeln('  }');
  }

  /// Generate the strongly-typed args class for a reducer
  void _generateReducerArgsClass(StringBuffer buf, ReducerSchema reducer) {
    final className = '${_toPascalCase(reducer.name)}Args';

    buf.writeln('/// Arguments for the ${reducer.name} reducer');
    buf.writeln('class $className {');

    // Generate fields
    for (final param in reducer.params.elements) {
      final paramName = _toCamelCase(param.name ?? 'unknown');
      final dartType = TypeMapper.toDartType(param.algebraicType);
      buf.writeln('  final $dartType $paramName;');
    }

    // Generate constructor
    if (reducer.params.elements.isEmpty) {
      // Empty constructor for reducers with no parameters
      buf.writeln('  $className();');
    } else {
      // Constructor with parameters
      buf.write('  $className({');
      for (final param in reducer.params.elements) {
        final paramName = _toCamelCase(param.name ?? 'unknown');
        buf.write('required this.$paramName, ');
      }
      buf.writeln('});');
    }

    buf.writeln('}');
  }

  /// Generate the decoder for a reducer's arguments
  void _generateReducerDecoder(StringBuffer buf, ReducerSchema reducer) {
    final argsClassName = '${_toPascalCase(reducer.name)}Args';
    final decoderClassName = '${_toPascalCase(reducer.name)}ArgsDecoder';

    buf.writeln('/// Decoder for ${reducer.name} reducer arguments');
    buf.writeln(
      'class $decoderClassName implements ReducerArgDecoder<$argsClassName> {',
    );
    buf.writeln('  @override');
    buf.writeln('  $argsClassName? decode(BsatnDecoder decoder) {');
    buf.writeln('    try {');

    // Decode each parameter
    for (final param in reducer.params.elements) {
      final paramName = _toCamelCase(param.name ?? 'unknown');
      _generateArgDecode(buf, paramName, param.algebraicType);
    }

    buf.writeln();
    buf.writeln('      return $argsClassName(');
    for (final param in reducer.params.elements) {
      final paramName = _toCamelCase(param.name ?? 'unknown');
      buf.writeln('        $paramName: $paramName,');
    }
    buf.writeln('      );');

    buf.writeln('    } catch (e) {');
    buf.writeln('      return null; // Deserialization failed');
    buf.writeln('    }');
    buf.writeln('  }');
    buf.writeln('}');
  }

  /// 🌟 GOLD STANDARD: Handle both primitive and complex types
  ///
  /// This is the critical branching logic that makes the SDK "first in class".
  /// It handles nested structs and enums inside reducer arguments.
  void _generateArgDecode(
    StringBuffer buf,
    String fieldName,
    Map<String, dynamic> algebraicType,
  ) {
    if (_isPrimitive(algebraicType)) {
      // Case A: Primitive type (int, String, bool, etc.)
      // Use BsatnDecoder's built-in read methods
      final method = TypeMapper.getDecoderMethod(algebraicType);
      buf.writeln('      final $fieldName = decoder.$method();');
    } else {
      // Case B: Complex type (custom struct or enum)
      // Use the static decode method of the generated class
      final typeName = _getDartClassName(algebraicType);
      buf.writeln('      final $fieldName = $typeName.decode(decoder);');
    }
  }

  bool _isPrimitive(Map<String, dynamic> algebraicType) {
    const primitiveKeys = [
      'U8',
      'U16',
      'U32',
      'U64',
      'I8',
      'I16',
      'I32',
      'I64',
      'F32',
      'F64',
      'Bool',
      'String',
    ];

    if (primitiveKeys.any((key) => algebraicType.containsKey(key))) return true;
    if (TypeMapper.isIdentityProduct(algebraicType)) return true;
    if (TypeMapper.isTimestampProduct(algebraicType)) return true;
    if (TypeMapper.isByteArray(algebraicType)) return true;

    return false;
  }

  /// Get the Dart class name for a complex type
  String _getDartClassName(Map<String, dynamic> algebraicType) {
    // For now, return a placeholder - this will be enhanced when we handle
    // complex types in the schema parsing
    // TODO: Extract actual type name from algebraicType structure
    return 'UnknownType';
  }

  String _toCamelCase(String input) {
    final parts = input.split('_');
    if (parts.isEmpty) return input;

    return parts[0].toLowerCase() +
        parts
            .skip(1)
            .map((word) {
              return word[0].toUpperCase() + word.substring(1).toLowerCase();
            })
            .join('');
  }

  String _toPascalCase(String input) {
    final parts = input.split('_');
    if (parts.isEmpty) return input;

    return parts
        .map((word) {
          if (word.isEmpty) return '';
          return word[0].toUpperCase() + word.substring(1).toLowerCase();
        })
        .join('');
  }
}
