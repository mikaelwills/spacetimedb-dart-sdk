// ignore_for_file: avoid_print

enum SdkLogLevel { debug, info, warning, error, none }

typedef SdkLogCallback = void Function(String level, String message);

class SdkLogger {
  static SdkLogCallback? onLog;
  static SdkLogLevel level = SdkLogLevel.warning;

  static void d(String msg) {
    if (level.index > SdkLogLevel.debug.index) return;
    onLog != null ? onLog!('D', msg) : print('[SDK:D] $msg');
  }

  static void i(String msg) {
    if (level.index > SdkLogLevel.info.index) return;
    onLog != null ? onLog!('I', msg) : print('[SDK] $msg');
  }

  static void w(String msg) {
    if (level.index > SdkLogLevel.warning.index) return;
    onLog != null ? onLog!('W', msg) : print('[SDK:W] $msg');
  }

  static void e(String msg) {
    if (level.index > SdkLogLevel.error.index) return;
    onLog != null ? onLog!('E', msg) : print('[SDK:E] $msg');
  }
}
