import 'dart:typed_data';
import 'package:spacetimedb_dart_sdk/src/codec/bsatn_decoder.dart';
import 'package:spacetimedb_dart_sdk/src/reducers/reducer_arg_decoder.dart';
import 'package:spacetimedb_dart_sdk/src/reducers/reducer_def.dart';

class ReducerRegistry {
  final Map<String, ReducerArgDecoder> _decoders = {};

  void register<A>(ReducerDef<A> def) {
    if (_decoders.containsKey(def.name)) {
      throw ArgumentError(
        'Decoder for reducer "${def.name}" is already registered',
      );
    }
    _decoders[def.name] = def.argsDecoder;
  }

  dynamic deserializeArgs(String reducerName, Uint8List bytes) {
    final decoder = _decoders[reducerName];
    if (decoder == null) return null;
    return decoder.decode(BsatnDecoder(bytes));
  }

  bool hasDecoder(String reducerName) => _decoders.containsKey(reducerName);

  List<String> get registeredReducers => _decoders.keys.toList();

  int get count => _decoders.length;
}
