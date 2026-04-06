import 'package:spacetimedb_dart_sdk/src/reducers/reducer_arg_decoder.dart';

class ReducerDef<A> {
  final String name;
  final ReducerArgDecoder<A> argsDecoder;

  const ReducerDef(this.name, this.argsDecoder);
}
