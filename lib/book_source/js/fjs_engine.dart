import 'dart:convert';

import 'package:fjs/fjs.dart' as fjs;
import 'package:flutter/foundation.dart';

import '../services/http_service.dart';

/// 基于 fjs（Rust 捆绑 QuickJS）的真实 JS 引擎实现。
///
/// 相比 [JsEngineStub] / 纯 Dart 迷你解释器，它提供完整 QuickJS 能力：
/// - 完整 JS 语法（ES2020+：async/await、正则、Proxy、BigInt 等）
/// - 注入 `bindings` 到全局作用域（`globalThis`）
/// - 文本/编码/日期工具用 QuickJS 内建实现
/// - 网络类经 `fjs.bridge_call` 异步桥接到 Dart 的 [HttpService]：
///   `java.ajax` / `java.http` / `$api.http` / `$api.get/getStr/getJson/post`
///
/// 注意：fjs 依赖原生 Rust/QuickJS 库。初始化失败（如测试宿主缺 dylib、
/// 平台不支持）时标记不可用并降级，调用方回退到 [JsEngineStub]/DartJs。
class FjsJsEngine {
  FjsJsEngine._();

  static final FjsJsEngine instance = FjsJsEngine._();

  fjs.JsEngine? _engine;
  bool _available = false;
  bool _initAttempted = false;

  bool get isAvailable => _available;

  /// 初始化底层引擎（幂等）。失败则 [isAvailable] 保持 false。
  Future<void> ensureReady() async {
    if (_initAttempted) return;
    _initAttempted = true;
    try {
      // 初始化 flutter_rust_bridge 运行时（加载 fjs 原生库）。已初始化时重复调用安全。
      await fjs.LibFjs.init();
      final engine = await fjs.JsEngine.create(
        builtins: fjs.JsBuiltinOptions(
          assert_: false,
          buffer: true,
          console: true,
          crypto: true,
          events: true,
          intl: true,
          os: true,
          path: true,
          process: true,
          streamWeb: true,
          stringDecoder: true,
          timers: true,
          url: true,
          util: true,
          json: true,
        ),
      );
      await engine.init(bridge: _handleBridge);
      _engine = engine;
      _available = true;
    } catch (e) {
      debugPrint('[FjsJsEngine] init failed, fallback to DartJs: $e');
      _available = false;
    }
  }

  /// 释放底层引擎。
  Future<void> dispose() async {
    try {
      await _engine?.close();
    } catch (_) {}
    _engine = null;
    _available = false;
    _initAttempted = false;
  }

  /// 求值入口（JS 段由 `_wrapExpr` 包成 async，网络桥为 Promise，支持顶层 await）。
  Future<String?> evaluate(
    String js, {
    Map<String, Object?> bindings = const {},
  }) async {
    if (!_available || _engine == null) return null;
    try {
      final result = await _engine!.eval(
        source: fjs.JsCode.code(_wrapExpr(js, bindings)),
      );
      return _valueToString(result);
    } catch (_) {
      return '';
    }
  }

  /// 以脚本方式执行（不关心返回值，如 jsLib / callBackJs）。
  Future<void> runScript(
    String js, {
    Map<String, Object?> bindings = const {},
  }) async {
    if (!_available || _engine == null) return;
    try {
      await _engine!.eval(
        source: fjs.JsCode.code('${_prelude(bindings)}\n$js'),
      );
    } catch (_) {}
  }

  /// 包成表达式：fjs 的 `eval` 默认启用顶层 await，故直接对 `$js` 求值并
  /// 把结果强制为字符串（规则内可用 `await` 等待 `$api.http` 网络桥）。
  String _wrapExpr(String js, Map<String, Object?> bindings) {
    return '${_prelude(bindings)}\n'
        'await (async () => { try { return String(await ($js)); } catch (e) { return ""; } })();';
  }

  /// fjs bridge 回调：JS 侧 `fjs.bridge_call(cfg)` 进入此处，执行真实网络请求。
  ///
  /// [cfg] 为 JS 传入的配置对象（继承自 `$api.http` / `java.ajax` 的参数字段）：
  /// - `url`: 请求地址
  /// - `method`: get / post
  /// - `headers`: 附加请求头
  /// - `body`: 请求体（POST 时）
  /// - `baseUrl`: 相对地址解析基准
  /// - `returnType`: `'json'` 时把响应按 JSON 解析后再返回
  /// 返回值经 [HttpService] 完成，非 JSON 时返回响应正文文本。
  Future<fjs.JsResult> _handleBridge(fjs.JsValue value) async {
    Map<String, dynamic> cfg;
    try {
      final raw = value.value;
      cfg = raw is Map<String, dynamic>
          ? raw
          : raw is String && raw.trim().isNotEmpty
              ? (jsonDecode(raw) as Map<String, dynamic>)
              : <String, dynamic>{};
    } catch (_) {
      return fjs.JsResult.ok(fjs.JsValue.string(''));
    }

    final url = (cfg['url'] ?? '').toString();
    if (url.trim().isEmpty) {
      return fjs.JsResult.ok(fjs.JsValue.string(''));
    }

    final method = (cfg['method'] ?? 'get').toString().toUpperCase();
    final headers = _stringMap(cfg['headers']);
    final base = cfg['baseUrl'] is String && (cfg['baseUrl'] as String).isNotEmpty
        ? Uri.tryParse(cfg['baseUrl'] as String)
        : null;

    try {
      final http = HttpService.instance;
      final resp = method == 'POST'
          ? await http.post(url,
              base: base, headers: headers, bodyRaw: cfg['body']?.toString())
          : await http.get(url, base: base, headers: headers);
      if (!resp.ok) {
        return fjs.JsResult.ok(fjs.JsValue.string(''));
      }
      final returnType = (cfg['returnType'] ?? '').toString().toLowerCase();
      if (returnType == 'json') {
        try {
          return fjs.JsResult.ok(fjs.JsValue.from(jsonDecode(resp.body)));
        } catch (_) {
          return fjs.JsResult.ok(fjs.JsValue.string(resp.body));
        }
      }
      return fjs.JsResult.ok(fjs.JsValue.string(resp.body));
    } catch (e) {
      debugPrint('[FjsJsEngine] bridge http failed: $e');
      return fjs.JsResult.ok(fjs.JsValue.string(''));
    }
  }

  Map<String, String>? _stringMap(Object? v) {
    if (v is! Map || v.isEmpty) return null;
    return v.map((k, val) => MapEntry(k.toString(), val.toString()));
  }

  /// 生成桥与变量注入 prelude。
  String _prelude(Map<String, Object?> bindings) {
    final cfgJson = jsonEncode({
      for (final e in bindings.entries)
        if (e.value != null || e.key.startsWith('@')) e.key: e.value,
    });
    // 注入 bindings 到全局作用域。
    final sb = StringBuffer("""
(function () {
  var __cfg = $cfgJson;
  for (var k in __cfg) {
    try { globalThis[k] = __cfg[k]; } catch (e) {}
  }
})();
globalThis.__store = globalThis.__store || {};
""");
    sb.write(r'''
globalThis.$jsBridge = function (cfg) {
  return fjs.bridge_call(cfg);
};
''');
    // `$api` / `java` 桥：文本/编码/日期用 QuickJS 内建；网络类经 bridge 异步桥接 Dart。
    sb.write(r'''
globalThis.$api = {
  base64Encode: function (s) { return btoa(unescape(encodeURIComponent(String(s)))); },
  base64Decode: function (s) {
    try { return decodeURIComponent(escape(atob(String(s)))); } catch (e) { return ''; }
  },
  base64UrlEncode: function (s) {
    return globalThis.$api.base64Encode(s).replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/,'');
  },
  base64UrlDecode: function (s) {
    var b = String(s).replace(/-/g,'+').replace(/_/g,'/');
    while (b.length % 4 !== 0) b += '=';
    return globalThis.$api.base64Decode(b);
  },
  encodeURIComponent: encodeURIComponent,
  decodeURIComponent: decodeURIComponent,
  escape: function (s) { return escape(s); },
  unescape: function (s) { try { return unescape(s); } catch (e) { return ''; } },
  jsonToString: function (o) { return JSON.stringify(o); },
  getAbsoluteURL: function (u) { return u; },
  uriFull: function (u) { return u; },
  stripQuery: function (u) { var i = String(u).search(/[?#]/); return i >= 0 ? String(u).substring(0, i) : u; },
  now: function () { return String(Date.now()); },
  date: function () {
    var d = new Date(); var p = function (n, w) { n = String(n); while (n.length < (w||2)) n = '0'+n; return n; };
    return d.getFullYear()+'-'+p(d.getMonth()+1)+'-'+p(d.getDate())+' '+p(d.getHours())+':'+p(d.getMinutes())+':'+p(d.getSeconds());
  },
  formatDate: function (fmt) {
    var d = new Date(); var p = function (n, w) { n = String(n); while (n.length < (w||2)) n = '0'+n; return n; };
    var f = fmt || 'yyyy-MM-dd HH:mm:ss';
    return f.replace(/yyyy/g, d.getFullYear()).replace(/MM/g, p(d.getMonth()+1))
      .replace(/dd/g, p(d.getDate())).replace(/HH/g, p(d.getHours()))
      .replace(/mm/g, p(d.getMinutes())).replace(/ss/g, p(d.getSeconds()));
  },
  baseUrl: function () { return globalThis.baseUrl || ''; },
  get: function (u, o) { return globalThis.$api.http(Object.assign({ url: u, method: 'get' }, o || {})); },
  getStr: function (u, o) { return globalThis.$api.http(Object.assign({ url: u, method: 'get' }, o || {})); },
  getJson: function (u, o) {
    return globalThis.$api.http(Object.assign({ url: u, method: 'get', returnType: 'json' }, o || {}));
  },
  post: function (u, o) { return globalThis.$api.http(Object.assign({ url: u, method: 'post' }, o || {})); },
  put: function (k, v) { return globalThis.__store[k] = v; },
  get: function (k) { return globalThis.__store[k]; },
  remove: function (k) { var v = globalThis.__store[k]; delete globalThis.__store[k]; return v; },
  containKey: function (k) { return Object.prototype.hasOwnProperty.call(globalThis.__store, k); },
  trim: function (s) { return String(s).replace(/^\s+|\s+$/g, ''); },
  toInt: function (s) { var n = parseInt(String(s), 10); return isNaN(n) ? 0 : n; },
  toFloat: function (s) { var n = parseFloat(String(s)); return isNaN(n) ? 0 : n; },
  substring: function (s, a, b) { return String(s).substring(a, b); },
  charAt: function (s, i) { return String(s).charAt(i); },
  replaceAll: function (s, a, b) { try { return String(s).replace(new RegExp(a, 'g'), b); } catch (e) { return String(s).split(a).join(b); } },
  regex: function (s, expr) { try { var m = String(s).match(new RegExp(expr)); return m ? m[0] : ''; } catch (e) { return ''; } },
  regexMatches: function (s, expr) { try { return String(s).match(new RegExp(expr, 'g')) || []; } catch (e) { return []; } },
  http: function (cfg) {
    return globalThis.$jsBridge(cfg);
  }
};
globalThis.api = globalThis.$api;
globalThis.java = {
  ajax: function (u, o) {
    return globalThis.$jsBridge(Object.assign({ url: u, method: (o && o.method) || 'get' }, o || {}));
  },
  http: function (cfg) { return globalThis.$jsBridge(cfg || {}); }
};
''');
    return sb.toString();
  }

  /// 把 fjs [JsValue] 转成 Dart 字符串（JS 侧已用 String() 强制为字符串）。
  String _valueToString(fjs.JsValue v) {
    return switch (v) {
      fjs.JsValue_String(:final field0) => field0,
      fjs.JsValue_Integer(:final field0) => '$field0',
      fjs.JsValue_Float(:final field0) => '$field0',
      fjs.JsValue_Boolean(:final field0) => '$field0',
      fjs.JsValue_Bigint(:final field0) => field0.toString(),
      fjs.JsValue_None() => '',
      _ => '',
    };
  }
}