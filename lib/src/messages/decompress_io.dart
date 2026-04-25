import 'dart:io';
import 'dart:typed_data';
import 'package:brotli/brotli.dart';

/// On Dart VM the pure-Dart `package:brotli` works correctly, so there's
/// no reason to negotiate `compression=None` at the URL level.
bool get brotliNativelySupported => true;

Future<Uint8List> decompressBrotli(Uint8List bytes) async {
  return Uint8List.fromList(brotli.decode(bytes));
}

Future<Uint8List> decompressGzip(Uint8List bytes) async {
  return Uint8List.fromList(gzip.decode(bytes));
}
