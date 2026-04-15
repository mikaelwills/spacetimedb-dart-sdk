import 'dart:typed_data';
import 'package:spacetimedb_sdk/src/codec/bsatn_decoder.dart';
import 'package:spacetimedb_sdk/src/reducers/reducer_arg_decoder.dart';
import 'package:spacetimedb_sdk/src/reducers/reducer_def.dart';
import 'package:spacetimedb_sdk/src/utils/sdk_logger.dart';

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
    try {
      return decoder.decode(BsatnDecoder(bytes));
    } catch (e) {
      SdkLogger.e(
        'Failed to decode args for reducer "$reducerName" (${bytes.length} bytes): $e',
      );
      return null;
    }
  }

  bool hasDecoder(String reducerName) => _decoders.containsKey(reducerName);

  List<String> get registeredReducers => _decoders.keys.toList();

  int get count => _decoders.length;
}
