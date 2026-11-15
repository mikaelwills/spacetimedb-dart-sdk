import 'package:spacetimedb_sdk/src/codegen/codegen_emitter.dart';
import 'package:spacetimedb_sdk/src/codegen/models.dart';

const _dartReservedWords = {
  'assert',
  'await',
  'break',
  'case',
  'catch',
  'class',
  'const',
  'continue',
  'default',
  'do',
  'else',
  'enum',
  'extends',
  'false',
  'final',
  'finally',
  'for',
  'if',
  'in',
  'is',
  'late',
  'new',
  'null',
  'required',
  'rethrow',
  'return',
  'super',
  'switch',
  'this',
  'throw',
  'true',
  'try',
  'var',
  'void',
  'while',
  'with',
  'yield',
};

const _generatedMemberNames = {
  'toJson',
  'fromJson',
  'copyWith',
  'hashCode',
  'toString',
  'runtimeType',
  'noSuchMethod',
  'encodeBsatn',
  'decodeBsatn',
};

const _generatedLocalNames = {'other', 'encoder', 'decoder'};

const _reducerLocalNames = {'ctx', 'optimisticChanges', 'dropIfOffline'};

const _unknownParamName = 'unknown';

const _escapeSuffix = '_';

final _memberReserved = {
  ..._dartReservedWords,
  ..._generatedMemberNames,
  ..._generatedLocalNames,
};

final _reducerParamReserved = {..._memberReserved, ..._reducerLocalNames};

String toSafeMemberName(String name) =>
    _memberReserved.contains(name) ? '$name$_escapeSuffix' : name;

String toSafeReducerParamName(String name) =>
    _reducerParamReserved.contains(name) ? '$name$_escapeSuffix' : name;

String reducerParamDartName(ProductElement param) =>
    toSafeReducerParamName(toCamelCase(param.name ?? _unknownParamName));
