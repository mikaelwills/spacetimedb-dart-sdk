import 'type_models.dart';

class ProcedureSchema {
  final String name;
  final ProductType params;
  AlgebraicType returnType;

  ProcedureSchema({
    required this.name,
    required this.params,
    required this.returnType,
  });

  bool get returnsUnit => switch (returnType) {
    IrProductType(:final elements) => elements.isEmpty,
    _ => false,
  };

  factory ProcedureSchema.fromJson(Map<String, dynamic> json) {
    final paramsJson = json['params'];
    final returnJson = json['return_type'];
    return ProcedureSchema(
      name: json['source_name'] ?? json['name'] ?? '',
      params: ProductType.fromJson(
        paramsJson is Map<String, dynamic> ? paramsJson : <String, dynamic>{},
      ),
      returnType: AlgebraicType.fromJson(
        returnJson is Map<String, dynamic>
            ? returnJson
            : <String, dynamic>{
                'Product': <String, dynamic>{'elements': []},
              },
      ),
    );
  }
}
