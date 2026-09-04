import 'dart:convert';

import '../js/fjs_engine.dart';
import '../js/js_interp.dart';
import '../models/book_source.dart';
import '../models/books.dart';

/// 书源事件回调分发（对应官方 `SourceCallBack` + `ruleContent.callBackJs`）。
///
/// 当书源 `eventListener = true` 且配置了 `ruleContent.callBackJs` 时，把它作为
/// 一段 JS 执行，注入与官方一致的变量：
/// `event` / `result` / `book` / `chapter` / `java` / `$api`。
///
/// 执行优先走 [FjsJsEngine]（真实 QuickJS，`$api`/`java` 网络桥可用）；
/// QuickJS 不可用或求值失败时降级到纯 Dart 迷你解释器。
///
/// 官方语义：callBackJs 返回 `false` 表示"书源拦截默认行为"，其余值执行默认。
/// 由于跨平台端对复杂 callBackJs（Rhino 专属语法）解析能力有限，
/// 统一视为**不拦截默认行为**（安全降级），仅通知书源 JS 执行副作用（如展示提示、网络封装等）。
class SourceCallback {
  SourceCallback._();

  /// 触发事件。
  ///
  /// [source] 书源；[event] 事件名（如 `clickCustomButton`/`startRead`）；
  /// [book]/[chapter] 上下文；[result] 附加结果。
  static Future<void> event({
    required BookSource? source,
    required String event,
    Book? book,
    BookChapter? chapter,
    String? result,
  }) async {
    if (source == null || !source.eventListener) return;
    final jsStr = source.ruleContent?.callBackJs;
    if (jsStr == null || jsStr.trim().isEmpty) return;

    final bindings = <String, Object?>{
      'event': event,
      'result': result,
      'book': _bookLite(book),
      'chapter': _chapterLite(chapter),
      'baseUrl': '',
    };

    // 优先 QuickJS（真实 $api/java 网络桥）。
    try {
      final fjsEngine = FjsJsEngine.instance;
      await fjsEngine.ensureReady();
      if (fjsEngine.isAvailable) {
        await fjsEngine.runScript(jsStr, bindings: bindings);
        return;
      }
    } catch (_) {
      // 降级到 DartJs
    }

    final dartBindings = <String, Object?>{...bindings};
    dartBindings[r'$api'] = DartJs.js(_apiBridge());
    dartBindings['api'] = DartJs.js(_apiBridge());
    dartBindings['java'] = DartJs.js(_javaBridge());

    try {
      DartJs(bindings: dartBindings).run(jsStr);
    } catch (_) {
      // 解析/求值失败：不拦截默认行为，静默。
    }
  }

  /// 书源是否有能力接收 [event] 回调（eventListener 开启且配了 callBackJs）。
  static bool canReceive(BookSource? source) {
    if (source == null || !source.eventListener) return false;
    final cb = source.ruleContent?.callBackJs;
    return cb != null && cb.trim().isNotEmpty;
  }

  static Map<String, Object?>? _bookLite(Book? book) {
    if (book == null) return null;
    return {
      'name': book.name,
      'author': book.author,
      'bookUrl': book.bookUrl,
      'origin': book.origin,
      'type': book.type,
    };
  }

  static Map<String, Object?>? _chapterLite(BookChapter? c) {
    if (c == null) return null;
    return {'title': c.title, 'url': c.url};
  }

  /// `$api` 桥（纯工具方法，网络类在同步解释器返回空）。
  static Map<String, dynamic> _apiBridge() => {
        'base64Encode': (String s) => base64.encode(utf8.encode(s)),
        'base64Decode': (String s) {
          try {
            return utf8.decode(base64.decode(s.trim()));
          } catch (_) {
            return '';
          }
        },
        'now': () => '${DateTime.now().millisecondsSinceEpoch}',
        'date': () => _now(),
      };

  static String _now() {
    final d = DateTime.now();
    String p(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${p(d.month)}-${p(d.day)} ${p(d.hour)}:${p(d.minute)}:${p(d.second)}';
  }

  /// `java` 桥（最小集合，网络类在同步解释器返回空）。
  static Map<String, dynamic> _javaBridge() => {
        'showMsg': (Object? m) => m?.toString() ?? '',
        'showToast': (Object? m) => m?.toString() ?? '',
        'network': _networkBridge(),
      };

  static Map<String, dynamic> _networkBridge() => {
        'get': (Object? _) => '',
        'ajax': (Object? _) => '',
        'http': (Object? _) => '',
      };
}