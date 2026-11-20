import 'package:code_builder/code_builder.dart' hide TypeDef;
import 'package:spacetimedb_sdk/src/codegen/codegen_emitter.dart';
import 'package:spacetimedb_sdk/src/codegen/models.dart';
import 'package:spacetimedb_sdk/src/codegen/dart_identifiers.dart';

const _rowParam = 'row';
const _overrideAnnotation = 'override';
const _noPrimaryKey = <int>[];

class RowDecoderBuilder {
  final TypeSpace typeSpace;
  final List<TypeDef> typeDefs;
  final List<TableSchema> tables;

  RowDecoderBuilder({
    required this.typeSpace,
    required this.typeDefs,
    required this.tables,
  });

  Class buildRowTypeDecoder(String className, ProductType productType) =>
      buildDecoderClass(className, productType, _noPrimaryKey);

  Class buildDecoderClass(
    String className,
    ProductType productType,
    List<int> primaryKey,
  ) {
    return Class((b) {
      b.name = '${className}Decoder';
      b.extend = refer('RowDecoder<$className>');
      b.methods.addAll([
        _buildDecodeMethod(className),
        ..._buildPrimaryKeyMethods(className, productType, primaryKey),
        _buildToJsonMethod(className),
        _buildFromJsonMethod(className),
        _buildSupportsJsonGetter(),
      ]);
    });
  }

  Method _buildDecodeMethod(String className) {
    return Method(
      (m) => m
        ..name = 'decode'
        ..annotations.add(refer(_overrideAnnotation))
        ..returns = refer(className)
        ..requiredParameters.add(
          Parameter(
            (p) => p
              ..name = 'decoder'
              ..type = refer('BsatnDecoder'),
          ),
        )
        ..body = Code('return $className.decodeBsatn(decoder);'),
    );
  }

  List<Method> _buildPrimaryKeyMethods(
    String className,
    ProductType productType,
    List<int> primaryKey,
  ) {
    final pkElement = _primaryKeyElement(productType, primaryKey);
    if (pkElement == null) return _buildNullPrimaryKeyMethods(className);

    final pkFieldName = toSafeMemberName(
      toCamelCase(pkElement.name ?? 'unknown'),
    );
    final pkDartType = pkElement.type.toDartTypeName(
      typeSpace: typeSpace,
      typeDefs: typeDefs,
      tables: tables,
    );
    return [
      Method(
        (m) => m
          ..name = 'getPrimaryKey'
          ..annotations.add(refer(_overrideAnnotation))
          ..returns = refer('$pkDartType?')
          ..requiredParameters.add(_rowParameter(className))
          ..body = Code('return $_rowParam.$pkFieldName;'),
      ),
    ];
  }

  ProductElement? _primaryKeyElement(
    ProductType productType,
    List<int> primaryKey,
  ) {
    if (primaryKey.isEmpty) return null;
    final pkIndex = primaryKey.first;
    if (pkIndex >= productType.elements.length) return null;
    return productType.elements[pkIndex];
  }

  List<Method> _buildNullPrimaryKeyMethods(String className) {
    return [
      Method(
        (m) => m
          ..name = 'hasPrimaryKey'
          ..annotations.add(refer(_overrideAnnotation))
          ..type = MethodType.getter
          ..returns = refer('bool')
          ..body = const Code('return false;'),
      ),
      Method(
        (m) => m
          ..name = 'getPrimaryKey'
          ..annotations.add(refer(_overrideAnnotation))
          ..returns = refer('dynamic')
          ..requiredParameters.add(_rowParameter(className))
          ..body = const Code('return null;'),
      ),
    ];
  }

  Method _buildToJsonMethod(String className) {
    return Method(
      (m) => m
        ..name = 'toJson'
        ..annotations.add(refer(_overrideAnnotation))
        ..returns = refer('Map<String, dynamic>?')
        ..requiredParameters.add(_rowParameter(className))
        ..body = const Code('return $_rowParam.toJson();'),
    );
  }

  Method _buildFromJsonMethod(String className) {
    return Method(
      (m) => m
        ..name = 'fromJson'
        ..annotations.add(refer(_overrideAnnotation))
        ..returns = refer('$className?')
        ..requiredParameters.add(
          Parameter(
            (p) => p
              ..name = 'json'
              ..type = refer('Map<String, dynamic>'),
          ),
        )
        ..body = Code('return $className.fromJson(json);'),
    );
  }

  Method _buildSupportsJsonGetter() {
    return Method(
      (m) => m
        ..name = 'supportsJsonSerialization'
        ..annotations.add(refer(_overrideAnnotation))
        ..type = MethodType.getter
        ..returns = refer('bool')
        ..body = const Code('return true;'),
    );
  }

  Parameter _rowParameter(String className) => Parameter(
    (p) => p
      ..name = _rowParam
      ..type = refer(className),
  );
}
