// 简易日志工具
import 'package:flutter/foundation.dart';

class Log {
  static const _tag = 'Reader';

  static void d(Object? message, {String tag = _tag}) {
    if (kDebugMode) {
      debugPrint('[$tag][D] $message');
    }
  }

  static void i(Object? message, {String tag = _tag}) {
    debugPrint('[$tag][I] $message');
  }

  static void w(Object? message, {String tag = _tag}) {
    debugPrint('[$tag][W] $message');
  }

  static void e(Object? message, {Object? error, StackTrace? stack, String tag = _tag}) {
    debugPrint('[$tag][E] $message');
    if (error != null) debugPrint('[$tag][E] error: $error');
    if (stack != null) debugPrint('[$tag][E] stack: $stack');
  }
}
