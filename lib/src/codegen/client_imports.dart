import 'package:code_builder/code_builder.dart' hide TypeDef;
import 'package:spacetimedb_sdk/src/codegen/models.dart';
import 'package:spacetimedb_sdk/src/codegen/view_generator.dart';

class ClientImports {
  final DatabaseSchema schema;
  final ViewGenerator viewGenerator;

  ClientImports(this.schema, this.viewGenerator);

  List<Directive> build() {
    final imports = <Directive>[
      Directive.import('dart:async'),
      Directive.import('package:spacetimedb_sdk/codegen.dart'),
      Directive.import('reducers.dart'),
    ];

    if (schema.reducers.isNotEmpty) {
      imports.add(Directive.import('reducer_args.dart'));
    }

    if (schema.procedures.isNotEmpty) {
      imports.add(Directive.import('procedures.dart'));
    }

    final tableFileNames = {
      for (final table in schema.tables) '${table.name}.dart',
    };
    final viewRowFileNames = viewGenerator.getViewRowFileNames().difference(
      tableFileNames,
    );

    for (final fileName in [...tableFileNames, ...viewRowFileNames]) {
      imports.add(Directive.import(fileName));
    }

    return imports;
  }
}
