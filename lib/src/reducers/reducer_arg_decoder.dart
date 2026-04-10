import 'package:spacetimedb_dart_sdk/src/codec/bsatn_decoder.dart';

abstract class ReducerArgDecoder<T> {
  T decode(BsatnDecoder decoder);
}
