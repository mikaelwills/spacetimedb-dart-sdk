import 'package:code_builder/code_builder.dart' hide TypeDef;
import 'package:spacetimedb_sdk/src/codegen/models.dart';
import 'package:spacetimedb_sdk/src/codegen/codegen_emitter.dart';

class ReducerGenerator {
  final List<ReducerSchema> reducers;
  final TypeSpace? typeSpace;
  final List<TypeDef>? typeDefs;

  ReducerGenerator(this.reducers, {this.typeSpace, this.typeDefs});

  String generate() {
    final lib = Library(
      (b) =>
          b
            ..directives.addAll([
              Directive.import('dart:async'),
              Directive.import('package:spacetimedb_sdk/codegen.dart'),
              Directive.import('reducer_args.dart'),
              ..._refTypeImports(),
            ])
            ..body.add(_buildReducersClass()),
    );

    return emitLibrary(lib, header: kGeneratedHeader);
  }

  String generateArgDecoders() {
    final specs = <Spec>[];
    for (final reducer in reducers) {
      specs.add(_buildArgsClass(reducer));
      specs.add(_buildArgsDecoder(reducer));
    }
    for (final reducer in reducers) {
      specs.add(_buildReducerDef(reducer));
    }

    final lib = Library(
      (b) =>
          b
            ..directives.addAll([
              Directive.import('package:spacetimedb_sdk/codegen.dart'),
              ..._refTypeImports(),
            ])
            ..body.addAll(specs),
    );

    return emitLibrary(
      lib,
      header:
          '// GENERATED REDUCER ARGUMENT CLASSES AND DECODERS - DO NOT MODIFY BY HAND',
    );
  }

  Iterable<Directive> _refTypeImports() {
    final defs = typeDefs;
    if (defs == null) return const [];
    final seen = <String>{};
    final imports = <Directive>[];
    for (final reducer in reducers) {
      for (final param in reducer.params.elements) {
        if (!param.type.isRef) continue;
        final refTypeName = param.type.refTypeName(defs);
        if (refTypeName == null) continue;
        final fileName = toSnakeCase(refTypeName);
        if (seen.add(fileName)) {
          imports.add(Directive.import('$fileName.dart'));
        }
      }
    }
    return imports;
  }

  Class _buildReducersClass() {
    return Class((b) {
      b.name = 'Reducers';

      b.fields.addAll([
        Field(
          (f) =>
              f
                ..name = '_reducerCaller'
                ..type = refer('ReducerCaller')
                ..modifier = FieldModifier.final$,
        ),
        Field(
          (f) =>
              f
                ..name = '_reducerEmitter'
                ..type = refer('ReducerEmitter')
                ..modifier = FieldModifier.final$,
        ),
      ]);

      b.constructors.add(
        Constructor(
          (c) =>
              c
                ..requiredParameters.addAll([
                  Parameter(
                    (p) =>
                        p
                          ..name = '_reducerCaller'
                          ..toThis = true,
                  ),
                  Parameter(
                    (p) =>
                        p
                          ..name = '_reducerEmitter'
                          ..toThis = true,
                  ),
                ]),
        ),
      );

      for (final reducer in reducers) {
        b.methods.add(_buildReducerMethod(reducer));
      }
      for (final reducer in reducers) {
        b.methods.add(_buildCompletionCallback(reducer));
      }
    });
  }

  Method _buildReducerMethod(ReducerSchema reducer) {
    final methodName = toCamelCase(reducer.name);

    final encoderStatements = StringBuffer();
    encoderStatements.writeln('final encoder = BsatnEncoder();');
    for (final param in reducer.params.elements) {
      final paramName = toCamelCase(param.name ?? 'unknown');
      encoderStatements.writeln(
        '${param.type.encodeExpression(paramName, typeSpace: typeSpace, typeDefs: typeDefs)};',
      );
    }
    final defName = '${toCamelCase(reducer.name)}Def';
    encoderStatements.writeln(
      "return await _reducerCaller.call($defName.name, encoder.toBytes(), optimisticChanges: optimisticChanges, dropIfOffline: dropIfOffline);",
    );

    return Method((m) {
      m
        ..name = methodName
        ..modifier = MethodModifier.async
        ..returns = refer('Future<TransactionResult>')
        ..docs.addAll([
          '/// Calls the `${reducer.name}` reducer.',
          '///',
          '/// Returns a [TransactionResult] on success. Throws',
          '/// [SpacetimeDbReducerException] if the reducer returns `Failed` or',
          '/// `InternalError`. The returned status is one of `Committed`,',
          '/// `Pending` (queued to offline storage), or `Dropped` (skipped via',
          '/// `dropIfOffline: true` while offline).',
        ]);

      for (final param in reducer.params.elements) {
        final paramName = toCamelCase(param.name ?? 'unknown');
        final dartType = param.type.toDartTypeName(
          typeSpace: typeSpace,
          typeDefs: typeDefs,
        );
        m.optionalParameters.add(
          Parameter(
            (p) =>
                p
                  ..name = paramName
                  ..named = true
                  ..required = true
                  ..type = refer(dartType),
          ),
        );
      }

      m.optionalParameters.addAll([
        Parameter(
          (p) =>
              p
                ..name = 'optimisticChanges'
                ..named = true
                ..type = refer('List<OptimisticChange>?'),
        ),
        Parameter(
          (p) =>
              p
                ..name = 'dropIfOffline'
                ..named = true
                ..defaultTo = const Code('false')
                ..type = refer('bool'),
        ),
      ]);

      m.body = Code(encoderStatements.toString());
    });
  }

  Method _buildCompletionCallback(ReducerSchema reducer) {
    final methodName = 'on${toPascalCase(reducer.name)}';
    final argsClassName = '${toPascalCase(reducer.name)}Args';

    final callbackParams = StringBuffer('EventContext ctx');
    for (final param in reducer.params.elements) {
      final paramName = toCamelCase(param.name ?? 'unknown');
      final dartType = param.type.toDartTypeName(
        typeSpace: typeSpace,
        typeDefs: typeDefs,
      );
      callbackParams.write(', $dartType $paramName');
    }

    final defName = '${toCamelCase(reducer.name)}Def';
    final argExtractors = StringBuffer();
    argExtractors.writeln(
      "return _reducerEmitter.on($defName).listen((EventContext ctx) {",
    );
    argExtractors.writeln('final event = ctx.event;');
    argExtractors.writeln('if (event is! ReducerEvent) return;');
    argExtractors.writeln('final args = event.reducerArgs;');
    argExtractors.writeln('if (args is! $argsClassName) return;');

    final callbackArgs = StringBuffer('callback(ctx');
    for (final param in reducer.params.elements) {
      final paramName = toCamelCase(param.name ?? 'unknown');
      callbackArgs.write(', args.$paramName');
    }
    callbackArgs.write(');');
    argExtractors.writeln(callbackArgs);
    argExtractors.writeln('});');

    return Method(
      (m) =>
          m
            ..name = methodName
            ..returns = refer('StreamSubscription<void>')
            ..requiredParameters.add(
              Parameter(
                (p) =>
                    p
                      ..name = 'callback'
                      ..type = refer('void Function($callbackParams)'),
              ),
            )
            ..body = Code(argExtractors.toString()),
    );
  }

  Class _buildArgsClass(ReducerSchema reducer) {
    final className = '${toPascalCase(reducer.name)}Args';

    return Class((b) {
      b.name = className;

      for (final param in reducer.params.elements) {
        final paramName = toCamelCase(param.name ?? 'unknown');
        final dartType = param.type.toDartTypeName(
          typeSpace: typeSpace,
          typeDefs: typeDefs,
        );
        b.fields.add(
          Field(
            (f) =>
                f
                  ..name = paramName
                  ..type = refer(dartType)
                  ..modifier = FieldModifier.final$,
          ),
        );
      }

      if (reducer.params.elements.isEmpty) {
        b.constructors.add(Constructor((c) => c));
      } else {
        b.constructors.add(
          Constructor((c) {
            for (final param in reducer.params.elements) {
              final paramName = toCamelCase(param.name ?? 'unknown');
              c.optionalParameters.add(
                Parameter(
                  (p) =>
                      p
                        ..name = paramName
                        ..named = true
                        ..required = true
                        ..toThis = true,
                ),
              );
            }
          }),
        );
      }
    });
  }

  Class _buildArgsDecoder(ReducerSchema reducer) {
    final argsClassName = '${toPascalCase(reducer.name)}Args';
    final decoderClassName = '${toPascalCase(reducer.name)}ArgsDecoder';

    final decodeBody = StringBuffer();
    for (final param in reducer.params.elements) {
      final paramName = toCamelCase(param.name ?? 'unknown');
      decodeBody.writeln(
        'final $paramName = ${param.type.decodeExpression(typeSpace: typeSpace, typeDefs: typeDefs)};',
      );
    }
    decodeBody.writeln('return $argsClassName(');
    for (final param in reducer.params.elements) {
      final paramName = toCamelCase(param.name ?? 'unknown');
      decodeBody.writeln('$paramName: $paramName,');
    }
    decodeBody.writeln(');');

    return Class(
      (b) =>
          b
            ..name = decoderClassName
            ..implements.add(refer('ReducerArgDecoder<$argsClassName>'))
            ..constructors.add(Constructor((c) => c..constant = true))
            ..methods.add(
              Method(
                (m) =>
                    m
                      ..name = 'decode'
                      ..annotations.add(refer('override'))
                      ..returns = refer(argsClassName)
                      ..requiredParameters.add(
                        Parameter(
                          (p) =>
                              p
                                ..name = 'decoder'
                                ..type = refer('BsatnDecoder'),
                        ),
                      )
                      ..body = Code(decodeBody.toString()),
              ),
            ),
    );
  }

  Code _buildReducerDef(ReducerSchema reducer) {
    final argsClassName = '${toPascalCase(reducer.name)}Args';
    final decoderClassName = '${toPascalCase(reducer.name)}ArgsDecoder';
    final defName = '${toCamelCase(reducer.name)}Def';
    return Code(
      "const $defName = ReducerDef<$argsClassName>('${reducer.name}', $decoderClassName());",
    );
  }
}
