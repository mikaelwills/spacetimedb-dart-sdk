import 'package:code_builder/code_builder.dart' hide TypeDef;
import 'package:spacetimedb_sdk/src/codegen/dart_identifiers.dart';
import 'package:spacetimedb_sdk/src/codegen/models.dart';

const _viewCallClass = 'ViewCall';
const _subscriptionsField = 'subscriptions';

class ParameterisedViewMethodBuilder {
  final DatabaseSchema schema;

  ParameterisedViewMethodBuilder(this.schema);

  Method build(ViewSchema view, String methodName, String rowType) {
    final parameters = _buildParameters(view);
    final argumentNames = parameters.map((p) => p.name).join(', ');
    return Method(
      (m) => m
        ..name = methodName
        ..returns = refer('$_viewCallClass<$rowType>')
        ..requiredParameters.addAll(parameters)
        ..body = Code('''
return $_viewCallClass<$rowType>(
  viewName: '${view.name}',
  arguments: [$argumentNames],
  subscriptions: $_subscriptionsField,
);
'''),
    );
  }

  List<Parameter> _buildParameters(ViewSchema view) => [
    for (final param in view.params.elements)
      Parameter(
        (p) => p
          ..name = reducerParamDartName(param)
          ..type = refer(
            param.type.toDartTypeName(
              typeSpace: schema.typeSpace,
              typeDefs: schema.types,
              tables: schema.tables,
            ),
          ),
      ),
  ];
}
