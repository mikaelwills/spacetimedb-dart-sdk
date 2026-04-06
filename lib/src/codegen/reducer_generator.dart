import 'package:spacetimedb_dart_sdk/src/codegen/models.dart';

class ReducerGenerator {
  final List<ReducerSchema> reducers;

  ReducerGenerator(this.reducers);

  String generate() {
    final buf = StringBuffer();

    buf.writeln('// GENERATED CODE - DO NOT MODIFY BY HAND');
    buf.writeln();
    buf.writeln("import 'dart:async';");
    buf.writeln(
      "import 'package:spacetimedb_dart_sdk/spacetimedb_dart_sdk.dart';",
    );
    buf.writeln("import 'reducer_args.dart';");
    buf.writeln();

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

    for (final reducer in reducers) {
      _generateReducerMethod(buf, reducer);
      buf.writeln();
    }

    for (final reducer in reducers) {
      _generateCompletionCallback(buf, reducer);
      buf.writeln();
    }

    buf.writeln('}');

    return buf.toString();
  }

  String generateArgDecoders() {
    final buf = StringBuffer();

    buf.writeln(
      '// GENERATED REDUCER ARGUMENT CLASSES AND DECODERS - DO NOT MODIFY BY HAND',
    );
    buf.writeln();
    buf.writeln(
      "import 'package:spacetimedb_dart_sdk/spacetimedb_dart_sdk.dart';",
    );
    buf.writeln();

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
        final dartType = param.type.toDartTypeName();
        buf.writeln('    required $dartType $paramName,');
      }
      buf.writeln('    List<OptimisticChange>? optimisticChanges,');
      buf.writeln('    bool isEventTable = false,');
      buf.writeln('  }) async {');
    }

    buf.writeln('    final encoder = BsatnEncoder();');
    for (final param in reducer.params.elements) {
      final paramName = _toCamelCase(param.name ?? 'unknown');
      buf.writeln('    encoder.${param.type.encoderMethod}($paramName);');
    }
    buf.writeln();

    buf.writeln(
      "    return await _reducerCaller.call('${reducer.name}', encoder.toBytes(), optimisticChanges: optimisticChanges, isEventTable: isEventTable);",
    );
    buf.writeln('  }');
  }

  void _generateCompletionCallback(StringBuffer buf, ReducerSchema reducer) {
    final methodName = 'on${_toPascalCase(reducer.name)}';
    final argsClassName = '${_toPascalCase(reducer.name)}Args';

    buf.write('  StreamSubscription<void> $methodName(');
    buf.write('void Function(EventContext ctx');

    for (final param in reducer.params.elements) {
      final paramName = _toCamelCase(param.name ?? 'unknown');
      final dartType = param.type.toDartTypeName();
      buf.write(', $dartType $paramName');
    }
    buf.writeln(') callback) {');

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

    for (final param in reducer.params.elements) {
      final paramName = _toCamelCase(param.name ?? 'unknown');
      buf.write(', args.$paramName');
    }
    buf.writeln(');');
    buf.writeln('    });');
    buf.writeln('  }');
  }

  void _generateReducerArgsClass(StringBuffer buf, ReducerSchema reducer) {
    final className = '${_toPascalCase(reducer.name)}Args';

    buf.writeln('/// Arguments for the ${reducer.name} reducer');
    buf.writeln('class $className {');

    for (final param in reducer.params.elements) {
      final paramName = _toCamelCase(param.name ?? 'unknown');
      final dartType = param.type.toDartTypeName();
      buf.writeln('  final $dartType $paramName;');
    }

    if (reducer.params.elements.isEmpty) {
      buf.writeln('  $className();');
    } else {
      buf.write('  $className({');
      for (final param in reducer.params.elements) {
        final paramName = _toCamelCase(param.name ?? 'unknown');
        buf.write('required this.$paramName, ');
      }
      buf.writeln('});');
    }

    buf.writeln('}');
  }

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

    for (final param in reducer.params.elements) {
      final paramName = _toCamelCase(param.name ?? 'unknown');
      _generateArgDecode(buf, paramName, param.type);
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

  void _generateArgDecode(
    StringBuffer buf,
    String fieldName,
    AlgebraicType type,
  ) {
    if (type.isPrimitive) {
      buf.writeln('      final $fieldName = decoder.${type.decoderMethod}();');
    } else {
      final typeName = _getDartClassName(type);
      buf.writeln('      final $fieldName = $typeName.decode(decoder);');
    }
  }

  String _getDartClassName(AlgebraicType type) {
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
