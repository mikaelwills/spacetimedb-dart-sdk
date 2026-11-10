import 'package:code_builder/code_builder.dart' hide TypeDef;
import 'package:spacetimedb_sdk/src/codegen/models.dart';
import 'package:spacetimedb_sdk/src/codegen/codegen_emitter.dart';

class ProcedureGenerator {
  final List<ProcedureSchema> procedures;
  final TypeSpace? typeSpace;
  final List<TypeDef>? typeDefs;
  final List<TableSchema> tables;

  ProcedureGenerator(
    this.procedures, {
    this.typeSpace,
    this.typeDefs,
    this.tables = const [],
  });

  String generate() {
    final lib = Library(
      (b) => b
        ..directives.addAll([
          Directive.import('dart:async'),
          Directive.import('package:spacetimedb_sdk/codegen.dart'),
          ..._refTypeImports(),
        ])
        ..body.add(_buildProceduresClass()),
    );

    return emitLibrary(lib, header: kGeneratedHeader);
  }

  Iterable<Directive> _refTypeImports() {
    final defs = typeDefs;
    if (defs == null) return const [];
    final types = [
      for (final procedure in procedures) ...[
        for (final param in procedure.params.elements) param.type,
        procedure.returnType,
      ],
    ];
    final fileNames = <String>{
      for (final type in types) ?type.refImportFile(defs, tables),
    };
    return (fileNames.toList()..sort()).map(Directive.import);
  }

  Class _buildProceduresClass() {
    return Class((b) {
      b.name = 'Procedures';
      b.fields.add(
        Field(
          (f) => f
            ..name = '_procedureCaller'
            ..type = refer('ProcedureCaller')
            ..modifier = FieldModifier.final$,
        ),
      );
      b.constructors.add(
        Constructor(
          (c) => c
            ..requiredParameters.add(
              Parameter(
                (p) => p
                  ..name = '_procedureCaller'
                  ..toThis = true,
              ),
            ),
        ),
      );
      for (final procedure in procedures) {
        b.methods.add(_buildProcedureMethod(procedure));
      }
    });
  }

  String _returnDartType(ProcedureSchema procedure) {
    if (procedure.returnsUnit) return 'void';
    return procedure.returnType.toDartTypeName(
      typeSpace: typeSpace,
      typeDefs: typeDefs,
      tables: tables,
    );
  }

  String _returnDecoder(ProcedureSchema procedure) {
    if (procedure.returnsUnit) return '(_) {}';
    final decodeExpr = procedure.returnType.decodeExpression(
      typeSpace: typeSpace,
      typeDefs: typeDefs,
      tables: tables,
    );
    return '(decoder) => $decodeExpr';
  }

  Method _buildProcedureMethod(ProcedureSchema procedure) {
    final returnType = _returnDartType(procedure);

    final body = StringBuffer()..writeln('final encoder = BsatnEncoder();');
    for (final param in procedure.params.elements) {
      final paramName = toCamelCase(param.name ?? 'unknown');
      body.writeln(
        '${param.type.encodeExpression(paramName, typeSpace: typeSpace, typeDefs: typeDefs, tables: tables)};',
      );
    }
    body.writeln(
      "return _procedureCaller.call<$returnType>('${procedure.name}', encoder.toBytes(), ${_returnDecoder(procedure)}, timeout: timeout,);",
    );

    return Method((m) {
      m
        ..name = toCamelCase(procedure.name)
        ..returns = refer('Future<$returnType>')
        ..docs.addAll([
          '/// Calls the `${procedure.name}` procedure and returns its result.',
          '///',
          '/// Throws [SpacetimeDbProcedureException] with the server\'s message',
          '/// when the procedure fails, and [SpacetimeDbConnectionException]',
          '/// when the connection is down or drops before the result arrives.',
        ]);

      for (final param in procedure.params.elements) {
        m.optionalParameters.add(
          Parameter(
            (p) => p
              ..name = toCamelCase(param.name ?? 'unknown')
              ..named = true
              ..required = true
              ..type = refer(
                param.type.toDartTypeName(
                  typeSpace: typeSpace,
                  typeDefs: typeDefs,
                  tables: tables,
                ),
              ),
          ),
        );
      }
      m.optionalParameters.add(
        Parameter(
          (p) => p
            ..name = 'timeout'
            ..named = true
            ..type = refer('Duration?'),
        ),
      );

      m.body = Code(body.toString());
    });
  }
}
