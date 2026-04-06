import 'package:spacetimedb_dart_sdk/src/codegen/client_generator.dart';
import 'package:spacetimedb_dart_sdk/src/codegen/reducer_generator.dart';
import 'package:spacetimedb_dart_sdk/src/codegen/models.dart';
import 'package:spacetimedb_dart_sdk/src/codegen/table_generator.dart';
import 'package:spacetimedb_dart_sdk/src/codegen/generators/sum_type_generator.dart';
import 'package:spacetimedb_dart_sdk/src/codegen/codegen_emitter.dart';
import 'package:spacetimedb_dart_sdk/src/utils/sdk_logger.dart';
import 'dart:io';

class DartGenerator {
  final DatabaseSchema schema;
  DartGenerator(this.schema);

  List<GeneratedFile> generateAll() {
    final files = <GeneratedFile>[];

    for (final typeDef in schema.types) {
      final type = schema.typeSpace.types[typeDef.typeRef];

      if (type.isSum) {
        final generator = SumTypeGenerator(
          enumName: typeDef.name,
          sumType: type.sum!,
          typeSpace: schema.typeSpace,
          typeDefs: schema.types,
        );

        final fileName = toSnakeCase(typeDef.name);
        files.add(
          GeneratedFile(
            filename: '$fileName.dart',
            content: generator.generate(),
          ),
        );
      }
    }

    for (final table in schema.tables) {
      final generator = TableGenerator(schema, table);
      files.add(
        GeneratedFile(
          filename: '${table.name}.dart',
          content: generator.generate(),
        ),
      );
    }

    if (schema.reducers.isNotEmpty) {
      final generator = ReducerGenerator(schema.reducers);
      files.add(
        GeneratedFile(filename: 'reducers.dart', content: generator.generate()),
      );

      files.add(
        GeneratedFile(
          filename: 'reducer_args.dart',
          content: generator.generateArgDecoders(),
        ),
      );
    }

    final clientGenerator = ClientGenerator(schema);
    files.add(
      GeneratedFile(
        filename: 'client.dart',
        content: clientGenerator.generate(),
      ),
    );

    return files;
  }

  Future<void> writeToDirectory(String outputPath) async {
    final dir = Directory(outputPath);
    await dir.create(recursive: true);

    final files = generateAll();

    for (final file in files) {
      final path = '${dir.path}/${file.filename}';
      await File(path).writeAsString(file.content);
      SdkLogger.i('Generated $path');
    }
  }
}

class GeneratedFile {
  final String filename;
  final String content;

  GeneratedFile({required this.filename, required this.content});
}
