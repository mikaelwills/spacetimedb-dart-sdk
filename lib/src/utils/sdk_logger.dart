// ignore_for_file: avoid_print
typedef SdkLogCallback = void Function(String level, String message);

class SdkLogger {
  static SdkLogCallback? onLog;

  static void d(String msg) {
    if (onLog != null) {
      onLog!('D', msg);
    } else {
      final loc = _getLocation();
      final div = '─' * 60;
      print('┌$div');
      print('│ 🐛 [SDK] $msg');
      print('│ at $loc');
      print('└$div');
    }
  }

  static void i(String msg) =>
      onLog != null ? onLog!('I', msg) : print('📘 [SDK] $msg');
  static void w(String msg) =>
      onLog != null ? onLog!('W', msg) : print('⚠️ [SDK] $msg');
  static void e(String msg) =>
      onLog != null ? onLog!('E', msg) : print('❌ [SDK] $msg');

  static String _getLocation() {
    for (final line in StackTrace.current.toString().split('\n')) {
      if (line.contains('sdk_logger.dart')) continue;
      final m = RegExp(r'\(([^)]+):(\d+):\d+\)').firstMatch(line);
      if (m != null) return '${m.group(1)!.split('/').last}:${m.group(2)}';
    }
    return 'unknown';
  }
}
