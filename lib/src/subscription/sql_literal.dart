import 'package:fixnum/fixnum.dart';

const _hexPrefix = '0x';
const _hexRadix = 16;
const _hexDigitsPerByte = 2;

String sqlLiteral(Object? value) => switch (value) {
  String() => _stringLiteral(value),
  bool() => value ? 'TRUE' : 'FALSE',
  int() || Int64() => value.toString(),
  double() => _doubleLiteral(value),
  List<int>() => _bytesToHexLiteral(value),
  _ => throw ArgumentError(
    'Unsupported view argument type: ${value.runtimeType}',
  ),
};

String _stringLiteral(String value) => "'${value.replaceAll("'", "''")}'";

String _doubleLiteral(double value) {
  if (!value.isFinite) {
    throw ArgumentError('A view argument must be a finite number: $value');
  }
  return value.toString();
}

String _bytesToHexLiteral(List<int> bytes) {
  final digits = bytes
      .map((b) => b.toRadixString(_hexRadix).padLeft(_hexDigitsPerByte, '0'))
      .join();
  return '$_hexPrefix$digits';
}
