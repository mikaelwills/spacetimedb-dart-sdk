// ignore_for_file: unnecessary_cast
import 'dart:js_interop';
import 'dart:typed_data';
import 'package:web/web.dart' as web;

bool? _brotliSupported;

/// True iff the browser's native DecompressionStream supports Brotli.
/// DecompressionStream('br') was added in Chrome 138 / Firefox 142. Caller
/// should check this at connect time and request `compression=None` from
/// the server when false.
bool get brotliNativelySupported {
  if (_brotliSupported != null) return _brotliSupported!;
  try {
    web.DecompressionStream('br');
    _brotliSupported = true;
  } catch (_) {
    _brotliSupported = false;
  }
  return _brotliSupported!;
}

Future<Uint8List> decompressBrotli(Uint8List bytes) => _decompress(bytes, 'br');

Future<Uint8List> decompressGzip(Uint8List bytes) => _decompress(bytes, 'gzip');

Future<Uint8List> _decompress(Uint8List bytes, String format) async {
  final stream = web.DecompressionStream(format);

  final writer = stream.writable.getWriter();
  final buffer = bytes.buffer.asUint8List(
    bytes.offsetInBytes,
    bytes.lengthInBytes,
  );
  await writer.write(buffer.toJS).toDart;
  await writer.close().toDart;

  final reader = stream.readable.getReader() as web.ReadableStreamDefaultReader;
  final chunks = <Uint8List>[];
  while (true) {
    final result = (await reader.read().toDart) as web.ReadableStreamReadResult;
    if (result.done) break;
    final value = result.value;
    if (value != null && value.isA<JSUint8Array>()) {
      chunks.add((value as JSUint8Array).toDart);
    }
  }

  final total = chunks.fold<int>(0, (n, c) => n + c.length);
  final out = Uint8List(total);
  var offset = 0;
  for (final c in chunks) {
    out.setRange(offset, offset + c.length, c);
    offset += c.length;
  }
  return out;
}
