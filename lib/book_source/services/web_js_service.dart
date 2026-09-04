import 'dart:convert';

import 'http_service.dart';
import '../models/book_source.dart';

/// WebView 型（JS）书源执行服务（对齐官方“.js 书源”）。
///
/// 官方网页书源的 `bookSourceUrl` 以 `js:` 开头，指向一个 `.js` 文件，该文件
/// 定义 bookSearch / bookDetail / toc / content 等 JS 函数，函数内部用真实
/// 浏览器（`java.webView`）访问页面并返回 HTML 或结构化数据。
///
/// 本服务在 Flutter 里复刻同一载体：
/// - [isJsSource]：识别 `js:` 书源
/// - [getCode]：下载并缓存书源 JS 源码
/// - [buildRunScript]：把「书源源码 + 调用函数 + 参数」拼成一段可在 WebView 内
///   执行的脚本；运行在真实内核里，拥有 DOM 与页面级交互能力，结果经
///   `runJavaScriptReturningResult` 以 JSON 字符串取回（一次“加载页面 → 执行
///   书源JS → 取回结果”的往返）。
class WebJsService {
  WebJsService._();

  static final WebJsService instance = WebJsService._();

  /// 是否为 WebView（JS）书源：`bookSourceUrl` 以 `js:` 开头。
  bool isJsSource(BookSource src) {
    return src.bookSourceUrl.trim().toLowerCase().startsWith('js:');
  }

  /// 真实 .js 源码地址（去掉 `js:` 前缀）。
  String? scriptUrl(BookSource src) {
    final url = src.bookSourceUrl.trim();
    if (!url.toLowerCase().startsWith('js:')) return null;
    final real = url.substring(3).trim();
    return real.isEmpty ? null : real;
  }

  final Map<String, String> _cache = {};

  /// 下载书源 JS 源码（带缓存，避免重复请求）。
  Future<String?> getCode(BookSource src) async {
    final real = scriptUrl(src);
    if (real == null) return null;
    final cached = _cache[real];
    if (cached != null) return cached;
    try {
      final resp = await HttpService.instance.get(real);
      if (!resp.ok || resp.body.trim().isEmpty) return null;
      _cache[real] = resp.body;
      return resp.body;
    } catch (_) {
      return null;
    }
  }

  /// 构造 `js:` 书源的函数调用脚本。
  ///
  /// [code] 为书源 JS 源码（含被调函数定义）；[fnName] 为要调用的函数名
  /// （bookSearch / bookDetail / toc / content 等）；[args] 为传给该函数的参数
  /// 列表（JSON 数组）。
  ///
  /// 脚本内把按钮参数序列化后调用，并将结果包装为 JSON：
  /// `{"ok":true,"data":<返回>}` 或 `{"ok":false,"msg":...}`。返回是 Promise 时
  /// 延后到结算，保证书源内 `await`（含异步桥）可用。
  String buildRunScript(String code, String fnName, List<Object?> args) {
    final argJson = jsonEncode(args);
    final argsCode = argJson.isEmpty ? '[]' : argJson;
    final fn = jsonEncode(fnName);
    return '''
$code
;(function () {
  var __fn = window[$fn];
  if (typeof __fn !== 'function') {
    return JSON.stringify({ ok: false, msg: '书源函数不存在: $fnName' });
  }
  try {
    var args = $argsCode;
    var r = __fn.apply(null, args);
    if (r && typeof r.then === 'function') {
      return r.then(function (v) {
        return JSON.stringify({ ok: true, data: v });
      }, function (e) {
        return JSON.stringify({ ok: false, msg: String((e && e.message) || e) });
      });
    }
    return JSON.stringify({ ok: true, data: r });
  } catch (e) {
    return JSON.stringify({ ok: false, msg: String((e && e.message) || e) });
  }
})();
''';
  }

  /// 解析 `runJavaScriptReturningResult` 返回的 JSON 结果。
  ///
  /// 成功返回 [String] 类型 data；失败返回 null（错误信息可经 [lastError] 取）。
  static ({
    bool ok,
    Object? data,
    String? msg,
  }) parseResultRaw(Object? raw) {
    final s = raw?.toString() ?? '';
    Object? decoded;
    try {
      decoded = jsonDecode(s);
    } catch (_) {
      return (ok: false, data: null, msg: '无法解析脚本返回: ${s.length > 200 ? s.substring(0, 200) : s}');
    }
    if (decoded is Map) {
      final ok = decoded['ok'] == true;
      return (ok: ok, data: decoded['data'], msg: decoded['msg']?.toString());
    }
    return (ok: false, data: decoded, msg: null);
  }
}