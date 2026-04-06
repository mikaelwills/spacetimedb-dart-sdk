import 'package:code_builder/code_builder.dart';

String emitLibrary(Library library, {String? header}) {
  final emitter = DartEmitter(useNullSafetySyntax: true);
  final source = library.accept(emitter).toString();
  if (header != null) {
    return '$header\n\n$source';
  }
  return source;
}

const kGeneratedHeader = '// GENERATED CODE - DO NOT MODIFY BY HAND';

String toPascalCase(String input) {
  return input
      .split('_')
      .map((word) => word[0].toUpperCase() + word.substring(1).toLowerCase())
      .join('');
}

String toCamelCase(String input) {
  final parts = input.split('_');
  if (parts.isEmpty) return input;
  return parts[0].toLowerCase() +
      parts
          .skip(1)
          .map(
            (word) => word[0].toUpperCase() + word.substring(1).toLowerCase(),
          )
          .join('');
}

String toSnakeCase(String input) {
  return input
      .replaceAllMapped(
        RegExp(r'[A-Z]'),
        (match) => '_${match.group(0)!.toLowerCase()}',
      )
      .replaceFirst(RegExp(r'^_'), '');
}
