// 文件说明：Legado 书源 JS 脚本引擎，基于 flutter_js(QuickJS) 提供与
// Legado Android 版兼容的 java.* 桥。同步语义的 ajax/get/post 通过
// "两阶段往返"协议实现：JS 桩抛出预取标记 → Dart 预取 → 注入结果重跑。
// 技术要点：QuickJS 运行时、JS/Dart 桥、Dio 预取。

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_js/flutter_js.dart';

import 'legado_cookie_jar.dart';
import 'legado_variable_store.dart';

class LegadoJsException implements Exception {
  const LegadoJsException(this.message);

  final String message;

  @override
  String toString() => message;
}

class LegadoJsEngine {
  LegadoJsEngine._() {
    final runtime = getJavascriptRuntime(xhr: false);
    final setup = runtime.evaluate(_bridgeScript);
    if (setup.isError) {
      runtime.dispose();
      throw LegadoJsException(
        'Failed to initialize the Legado JS bridge: ${setup.stringResult}',
      );
    }
    _runtime = runtime;
  }

  static LegadoJsEngine? _instance;
  static bool _unavailable = false;

  /// 全局共享实例；平台不支持时返回 null，调用方需同步降级。
  static LegadoJsEngine? get instance {
    if (_unavailable) return null;
    if (_instance != null) return _instance;
    try {
      return _instance = LegadoJsEngine._();
    } catch (error) {
      _unavailable = true;
      return null;
    }
  }

  static bool get available => instance != null;

  JavascriptRuntime? _runtime;
  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 10),
      responseType: ResponseType.plain,
      validateStatus: (status) => status != null && status < 500,
    ),
  );
  final Map<String, String> _responses = {};

  /// 执行一段 Legado 语句脚本（可含 return），返回字符串化结果。
  ///
  /// [variables] 注入为脚本全局变量（key/page/result/baseUrl/src/title/
  /// host/book/chapter）。脚本内 java.ajax 等网络调用自动往返预取。
  /// [prelude] 为源级 jsLib，先于脚本执行。
  /// [sourceUrl] 指定书源时，java.put/get 与 Dart 侧 `@get:`/`@put:`
  /// 语法共享同一变量池（按源隔离，跨请求持久）。
  Future<String> evaluateScript(
    String code,
    Map<String, Object?> variables, {
    String prelude = '',
    int maxHops = 8,
    String sourceUrl = '',
  }) async {
    return _run(
      _wrapStatement(_withPrelude(prelude, code), variables),
      maxHops,
      sourceUrl: sourceUrl,
    );
  }

  /// 执行一段 JS 表达式（用于 `{{...}}` 模板），返回字符串。
  Future<String> evaluateExpression(
    String expression,
    Map<String, Object?> variables, {
    String prelude = '',
    int maxHops = 8,
    String sourceUrl = '',
  }) async {
    return _run(
      _wrapExpression(expression, variables, prelude),
      maxHops,
      sourceUrl: sourceUrl,
    );
  }

  static String _withPrelude(String prelude, String code) {
    final trimmed = prelude.trim();
    return trimmed.isEmpty ? code : '$trimmed\n$code';
  }

  String _varsPrelude(Map<String, Object?> variables) {
    final encoded = jsonEncode(variables);
    return '(function(){var __vars=$encoded;'
        'var key=__vars.key,page=__vars.page,result=__vars.result,'
        'baseUrl=__vars.baseUrl,src=__vars.src,title=__vars.title,'
        'host=__vars.host,chapter=__vars.chapter;'
        'var book=__vars.book&&typeof __vars.book==="object"?__vars.book:null;';
  }

  String _wrapStatement(String code, Map<String, Object?> variables) {
    return '${_varsPrelude(variables)}'
        'var __out=(function(){\n$code\n})();'
        '__out=__out===undefined?"":__out;'
        'return typeof __out==="object"&&__out!==null?JSON.stringify(__out):String(__out);})()';
  }

  String _wrapExpression(
    String expression,
    Map<String, Object?> variables,
    String prelude,
  ) {
    final trimmedPrelude = prelude.trim();
    return '${_varsPrelude(variables)}'
        'var __out=(function(){${trimmedPrelude.isEmpty ? '' : '\n$trimmedPrelude\n'}return (\n$expression\n);})();'
        '__out=__out===undefined?"":__out;'
        'return typeof __out==="object"&&__out!==null?JSON.stringify(__out):String(__out);})()';
  }

  Future<String> _run(String script, int maxHops, {String sourceUrl = ''}) {
    // 整体预算：复杂脚本 + 多轮网络预取最多 15s，防止死循环或
    // 慢网络把阅读页永久卡在加载态。
    return _runUnchecked(script, maxHops, sourceUrl: sourceUrl).timeout(
      const Duration(seconds: 15),
      onTimeout: () =>
          throw const LegadoJsException('Legado JS evaluation timed out.'),
    );
  }

  Future<String> _runUnchecked(String script, int maxHops,
      {String sourceUrl = ''}) async {
    final runtime = _runtime;
    if (runtime == null) {
      throw const LegadoJsException('JS runtime is not available.');
    }
    // 注入 CookieJar 快照，供 java.getCookies(url) 同步读取。
    try {
      final snapshot = LegadoCookieJar.instance.cookieHeaderSnapshot();
      runtime.evaluate('java.__cookies = ${jsonEncode(snapshot)};');
    } catch (_) {}
    // 注入按源隔离的变量池快照，java.put/get 与 Dart 侧 `@get:` 共享。
    if (sourceUrl.isNotEmpty) {
      try {
        runtime.evaluate(
          'java.__sourceUrl=${jsonEncode(sourceUrl)};'
          'java.__vars=${jsonEncode(LegadoVariableStore.instance.snapshot(sourceUrl))};'
          'java.__varUpdates={};',
        );
      } catch (_) {}
    }
    for (var hop = 0; hop <= maxHops; hop++) {
      final result = runtime.evaluate(script);
      final text = result.stringResult;
      // flutter_js 各运行时都不抛 JS 异常，而是返回 isError=true。
      final marker = result.isError ? text.indexOf('PREFETCH:') : -1;
      if (marker >= 0) {
        if (hop == maxHops) {
          throw const LegadoJsException(
            'Legado JS exceeded its network round-trip budget.',
          );
        }
        await _prefetch(_extractPrefetchPayload(text, marker));
        runtime.evaluate('java.__responses = ${jsonEncode(_responses)};');
        continue;
      }
      if (result.isError) {
        final firstLine = text.split('\n').first.trim();
        throw LegadoJsException('Legado JS error: $firstLine');
      }
      _collectCookieUpdates(runtime);
      if (sourceUrl.isNotEmpty) _collectVariableUpdates(runtime, sourceUrl);
      return text == 'null' || text == 'undefined' ? '' : text;
    }
    throw const LegadoJsException('Legado JS execution failed.');
  }

  /// 错误文本形如 `JSError: Error: PREFETCH:{...}\n  at ...`（QuickJS）或
  /// `ERROR: PREFETCH:{...} \n  at ...`（JavaScriptCore）。载荷到行尾为止。
  static String _extractPrefetchPayload(String text, int marker) {
    var rest = text.substring(marker + 'PREFETCH:'.length);
    final newline = rest.indexOf('\n');
    if (newline >= 0) rest = rest.substring(0, newline);
    return rest.trim();
  }

  void _collectCookieUpdates(JavascriptRuntime runtime) {
    try {
      final raw = runtime.evaluate('JSON.stringify(java.__cookieUpdates || {})');
      if (raw.isError) return;
      final decoded = jsonDecode(raw.stringResult);
      if (decoded is Map && decoded.isNotEmpty) {
        for (final entry in decoded.entries) {
          final url = '$entry.key';
          if (entry.value is! Map) continue;
          for (final cookie in entry.value.entries) {
            LegadoCookieJar.instance.setCookie(
              url,
              '$cookie.key',
              '$cookie.value',
            );
          }
        }
        runtime.evaluate('java.__cookieUpdates = {};');
      }
    } catch (_) {
      // Cookie 回收失败不影响脚本结果。
    }
  }

  /// 回收脚本内 java.put 写入的变量更新到 Dart 侧变量池。
  void _collectVariableUpdates(JavascriptRuntime runtime, String sourceUrl) {
    try {
      final raw = runtime.evaluate('JSON.stringify(java.__varUpdates || {})');
      if (raw.isError) return;
      final decoded = jsonDecode(raw.stringResult);
      if (decoded is Map && decoded.isNotEmpty) {
        final updates = <String, String>{
          for (final entry in decoded.entries)
            if (entry.value is String) '$entry.key': entry.value as String,
        };
        LegadoVariableStore.instance.merge(sourceUrl, updates);
        runtime.evaluate('java.__varUpdates = {};');
      }
    } catch (_) {
      // 变量回收失败不影响脚本结果。
    }
  }

  Future<void> _prefetch(String requestJson) async {
    final decoded = jsonDecode(requestJson);
    if (decoded is! Map) {
      throw LegadoJsException('Invalid prefetch request: $requestJson');
    }
    final url = '${decoded['url'] ?? ''}'.trim();
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasAuthority ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw LegadoJsException('Legado JS requested a non-HTTP URL: $url');
    }
    final connectMode = decoded['__connect'] == true;
    final method = ('${decoded['method'] ?? 'GET'}').toUpperCase();
    final headers = <String, String>{
      'User-Agent':
          'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36',
      'Cookie': LegadoCookieJar.instance.headerFor(uri),
    };
    final rawHeaders = decoded['headers'];
    if (rawHeaders is Map) {
      for (final entry in rawHeaders.entries) {
        headers['${entry.key}'] = '${entry.value}';
      }
    }
    final body = decoded['body'];
    try {
      final response = await _dio.request<String>(
        url,
        data: body == null || '$body'.isEmpty ? null : '$body',
        options: Options(
          method: method,
          headers: headers,
          responseType: ResponseType.plain,
        ),
      );
      final setCookies = response.headers.map['set-cookie'] ?? const [];
      LegadoCookieJar.instance.storeFromResponse(uri, setCookies);
      if (connectMode) {
        final headerMap = <String, String>{};
        response.headers.map.forEach((name, values) {
          headerMap[name] = values.join('; ');
        });
        _responses[requestJson] = jsonEncode({
          'body': response.data ?? '',
          'code': response.statusCode ?? 200,
          'headers': headerMap,
        });
      } else {
        _responses[requestJson] = response.data ?? '';
      }
    } on DioException catch (error) {
      _responses[requestJson] = connectMode
          ? jsonEncode({'body': '', 'code': 0, 'headers': {}})
          : '';
      if (error.type == DioExceptionType.connectionTimeout ||
          error.type == DioExceptionType.receiveTimeout) {
        throw const LegadoJsException(
          'Legado JS network request timed out.',
        );
      }
    }
  }

  void dispose() {
    _runtime?.dispose();
    _runtime = null;
    _dio.close();
  }
}

/// 注入 QuickJS 的 Legado 兼容桥：base64/md5/mini-DOM/链式规则/全局函数。
const String _bridgeScript = r'''
(function (global) {
  'use strict';
  // ===================== base64 =====================
  var B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  function _utf8Bytes(str) {
    var out = [], i, c;
    for (i = 0; i < str.length; i++) {
      c = str.charCodeAt(i);
      if (c < 0x80) out.push(c);
      else if (c < 0x800) {
        out.push(0xC0 | (c >> 6), 0x80 | (c & 0x3F));
      } else if (c >= 0xD800 && c <= 0xDBFF && i + 1 < str.length) {
        var c2 = str.charCodeAt(++i);
        var cp = 0x10000 + ((c & 0x3FF) << 10) + (c2 & 0x3FF);
        out.push(0xF0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3F),
          0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F));
      } else {
        out.push(0xE0 | (c >> 12), 0x80 | ((c >> 6) & 0x3F), 0x80 | (c & 0x3F));
      }
    }
    return out;
  }
  function base64Encode(str) {
    var bytes = _utf8Bytes(String(str)), out = '', i;
    for (i = 0; i + 2 < bytes.length; i += 3) {
      out += B64[bytes[i] >> 2] + B64[((bytes[i] & 3) << 4) | (bytes[i + 1] >> 4)]
        + B64[((bytes[i + 1] & 15) << 2) | (bytes[i + 2] >> 6)]
        + B64[bytes[i + 2] & 63];
    }
    var rem = bytes.length - i;
    if (rem === 1) out += B64[bytes[i] >> 2] + B64[(bytes[i] & 3) << 4] + '==';
    else if (rem === 2) out += B64[bytes[i] >> 2]
      + B64[((bytes[i] & 3) << 4) | (bytes[i + 1] >> 4)]
      + B64[(bytes[i + 1] & 15) << 2] + '=';
    return out;
  }
  function base64Decode(str) {
    var s = String(str).replace(/[^A-Za-z0-9+/=]/g, '');
    var bytes = [], i, c1, c2, c3, e1, e2, e3, e4;
    for (i = 0; i + 3 < s.length; i += 4) {
      e1 = B64.indexOf(s[i]); e2 = B64.indexOf(s[i + 1]);
      e3 = B64.indexOf(s[i + 2]); e4 = B64.indexOf(s[i + 3]);
      c1 = (e1 << 2) | (e2 >> 4); c2 = ((e2 & 15) << 4) | (e3 >> 2);
      c3 = ((e3 & 3) << 6) | e4;
      bytes.push(c1);
      if (s[i + 2] !== '=') bytes.push(c2);
      if (s[i + 3] !== '=') bytes.push(c3);
    }
    var out = '', j;
    for (j = 0; j < bytes.length; j++) out += String.fromCharCode(bytes[j]);
    try { return decodeURIComponent(escape(out)); } catch (e) { return out; }
  }

  // ===================== md5 =====================
  function _md5cycle(x, k) {
    var a = x[0], b = x[1], c = x[2], d = x[3];
    a = _ff(a, b, c, d, k[0], 7, -680876936); d = _ff(d, a, b, c, k[1], 12, -389564586);
    c = _ff(c, d, a, b, k[2], 17, 606105819); b = _ff(b, c, d, a, k[3], 22, -1044525330);
    a = _ff(a, b, c, d, k[4], 7, -176418897); d = _ff(d, a, b, c, k[5], 12, 1200080426);
    c = _ff(c, d, a, b, k[6], 17, -1473231341); b = _ff(b, c, d, a, k[7], 22, -45705983);
    a = _ff(a, b, c, d, k[8], 7, 1770035416); d = _ff(d, a, b, c, k[9], 12, -1958414417);
    c = _ff(c, d, a, b, k[10], 17, -42063); b = _ff(b, c, d, a, k[11], 22, -1990404162);
    a = _ff(a, b, c, d, k[12], 7, 1804603682); d = _ff(d, a, b, c, k[13], 12, -40341101);
    c = _ff(c, d, a, b, k[14], 17, -1502002290); b = _ff(b, c, d, a, k[15], 22, 1236535329);
    a = _gg(a, b, c, d, k[1], 5, -165796510); d = _gg(d, a, b, c, k[6], 9, -1069501632);
    c = _gg(c, d, a, b, k[11], 14, 643717713); b = _gg(b, c, d, a, k[0], 20, -373897302);
    a = _gg(a, b, c, d, k[5], 5, -701558691); d = _gg(d, a, b, c, k[10], 9, 38016083);
    c = _gg(c, d, a, b, k[15], 14, -660478335); b = _gg(b, c, d, a, k[4], 20, -405537848);
    a = _gg(a, b, c, d, k[9], 5, 568446438); d = _gg(d, a, b, c, k[14], 9, -1019803690);
    c = _gg(c, d, a, b, k[3], 14, -187363961); b = _gg(b, c, d, a, k[8], 20, 1163531501);
    a = _gg(a, b, c, d, k[13], 5, -1444681467); d = _gg(d, a, b, c, k[2], 9, -51403784);
    c = _gg(c, d, a, b, k[7], 14, 1735328473); b = _gg(b, c, d, a, k[12], 20, -1926607734);
    a = _hh(a, b, c, d, k[5], 4, -378558); d = _hh(d, a, b, c, k[8], 11, -2022574463);
    c = _hh(c, d, a, b, k[11], 16, 1839030562); b = _hh(b, c, d, a, k[14], 23, -35309556);
    a = _hh(a, b, c, d, k[1], 4, -1530992060); d = _hh(d, a, b, c, k[4], 11, 1272893353);
    c = _hh(c, d, a, b, k[7], 16, -155497632); b = _hh(b, c, d, a, k[10], 23, -1094730640);
    a = _hh(a, b, c, d, k[13], 4, 681279174); d = _hh(d, a, b, c, k[0], 11, -358537222);
    c = _hh(c, d, a, b, k[3], 16, -722521979); b = _hh(b, c, d, a, k[6], 23, 76029189);
    a = _hh(a, b, c, d, k[9], 4, -640364487); d = _hh(d, a, b, c, k[12], 11, -421815835);
    c = _hh(c, d, a, b, k[15], 16, 530742520); b = _hh(b, c, d, a, k[2], 23, -995338651);
    a = _ii(a, b, c, d, k[0], 6, -198630844); d = _ii(d, a, b, c, k[7], 10, 1126891415);
    c = _ii(c, d, a, b, k[14], 15, -1416354905); b = _ii(b, c, d, a, k[5], 21, -57434055);
    a = _ii(a, b, c, d, k[12], 6, 1700485571); d = _ii(d, a, b, c, k[3], 10, -1894986606);
    c = _ii(c, d, a, b, k[10], 15, -1051523); b = _ii(b, c, d, a, k[1], 21, -2054922799);
    a = _ii(a, b, c, d, k[8], 6, 1873313359); d = _ii(d, a, b, c, k[15], 10, -30611744);
    c = _ii(c, d, a, b, k[6], 15, -1560198380); b = _ii(b, c, d, a, k[13], 21, 1309151649);
    a = _ii(a, b, c, d, k[4], 6, -145523070); d = _ii(d, a, b, c, k[11], 10, -1120210379);
    c = _ii(c, d, a, b, k[2], 15, 718787259); b = _ii(b, c, d, a, k[9], 21, -343485551);
    x[0] = _add32(a, x[0]); x[1] = _add32(b, x[1]); x[2] = _add32(c, x[2]); x[3] = _add32(d, x[3]);
  }
  function _cmn(q, a, b, x, s, t) {
    a = _add32(_add32(a, q), _add32(x, t));
    return _add32((a << s) | (a >>> (32 - s)), b);
  }
  function _ff(a, b, c, d, x, s, t) { return _cmn((b & c) | ((~b) & d), a, b, x, s, t); }
  function _gg(a, b, c, d, x, s, t) { return _cmn((b & d) | (c & (~d)), a, b, x, s, t); }
  function _hh(a, b, c, d, x, s, t) { return _cmn(b ^ c ^ d, a, b, x, s, t); }
  function _ii(a, b, c, d, x, s, t) { return _cmn(c ^ (b | (~d)), a, b, x, s, t); }
  function _add32(a, b) { return (a + b) & 0xFFFFFFFF; }
  function _md5blk(s) {
    var md5blks = [], i;
    for (i = 0; i < 64; i += 4) {
      md5blks[i >> 2] = s.charCodeAt(i) + (s.charCodeAt(i + 1) << 8)
        + (s.charCodeAt(i + 2) << 16) + (s.charCodeAt(i + 3) << 24);
    }
    return md5blks;
  }
  function md5(str) {
    var n = str.length, state = [1732584193, -271733879, -1732584194, 271733878], i;
    for (i = 64; i <= n; i += 64) _md5cycle(state, _md5blk(str.substring(i - 64, i)));
    str = str.substring(i - 64);
    var tail = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
    for (i = 0; i < str.length; i++) tail[i >> 2] |= str.charCodeAt(i) << ((i % 4) << 3);
    tail[i >> 2] |= 0x80 << ((i % 4) << 3);
    if (i > 55) { _md5cycle(state, tail); for (i = 0; i < 16; i++) tail[i] = 0; }
    tail[14] = n * 8;
    _md5cycle(state, tail);
    var out = '';
    for (i = 0; i < 4; i++) {
      for (var j = 0; j < 4; j++) {
        out += ((state[i] >> (j * 8 + 4)) & 0x0F).toString(16)
          + ((state[i] >> (j * 8)) & 0x0F).toString(16);
      }
    }
    return out;
  }

  // ===================== mini DOM =====================
  var VOID_TAGS = { area: 1, base: 1, br: 1, col: 1, embed: 1, hr: 1, img: 1,
    input: 1, link: 1, meta: 1, param: 1, source: 1, track: 1, wbr: 1 };
  function _parseAttrs(raw) {
    var attrs = {}, re = /([A-Za-z_:@][-\w:.]*)\s*(?:=\s*("([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?/g, m;
    while ((m = re.exec(raw)) !== null) {
      var name = m[1].toLowerCase();
      var value = m[3] !== undefined ? m[3] : (m[4] !== undefined ? m[4] : (m[5] !== undefined ? m[5] : ''));
      attrs[name] = value;
    }
    return attrs;
  }
  function parseHTML(html) {
    var root = { tag: '#root', attrs: {}, children: [], parent: null };
    var stack = [root];
    var re = /<(\/?)([a-zA-Z][-\w]*)((?:[^>'"]|'[^']*'|"[^"]*")*)(\/?)>|<!--[\s\S]*?-->|<![^>]*>/g;
    var last = 0, m;
    function top() { return stack[stack.length - 1]; }
    while ((m = re.exec(html)) !== null) {
      if (m.index > last) top().children.push({ tag: '#text', text: html.slice(last, m.index), parent: top() });
      last = re.index + m[0].length;
      if (m[2] === undefined) continue;
      var closing = m[1] === '/';
      var tag = m[2].toLowerCase();
      if (closing) {
        for (var i = stack.length - 1; i > 0; i--) {
          if (stack[i].tag === tag) { stack.length = i; break; }
        }
      } else {
        var el = { tag: tag, attrs: _parseAttrs(m[3] || ''), children: [], parent: top() };
        top().children.push(el);
        if (m[4] !== '/' && !VOID_TAGS[tag]) stack.push(el);
      }
    }
    if (last < html.length) top().children.push({ tag: '#text', text: html.slice(last), parent: top() });
    return root;
  }
  function _descendants(el, withSelf, out) {
    if (withSelf) out.push(el);
    for (var i = 0; i < el.children.length; i++) _descendants(el.children[i], true, out);
    return out;
  }
  function _matchCss(el, css) {
    if (css === '*' || css === el.tag) return true;
    var m = /^([a-zA-Z][-\w]*)?((?:\.[^.#]+)*(?:#[^.#]+)*)$/.exec(css);
    if (!m) return false;
    if (m[1] && m[1].toLowerCase() !== el.tag) return false;
    var rest = m[2] || '';
    var classes = (rest.match(/\.[^.#]+/g) || []).map(function (s) { return s.slice(1); });
    var ids = (rest.match(/#[^.#]+/g) || []).map(function (s) { return s.slice(1); });
    var elClass = ' ' + (el.attrs['class'] || '') + ' ';
    for (var i = 0; i < classes.length; i++) {
      if (elClass.indexOf(' ' + classes[i] + ' ') < 0) return false;
    }
    for (var j = 0; j < ids.length; j++) {
      if (el.attrs['id'] !== ids[j]) return false;
    }
    return true;
  }
  function _querySelectorAll(root, css) {
    var all = _descendants(root, false, []);
    return all.filter(function (el) { return _matchCss(el, css); });
  }
  function _elText(el) {
    var out = '';
    for (var i = 0; i < el.children.length; i++) {
      var c = el.children[i];
      out += c.tag === '#text' ? c.text : _elText(c);
    }
    return out;
  }
  function _elOwnText(el) {
    var out = '';
    for (var i = 0; i < el.children.length; i++) {
      if (el.children[i].tag === '#text') out += el.children[i].text;
    }
    return out.trim();
  }
  function _elHtml(el) {
    var out = '';
    for (var i = 0; i < el.children.length; i++) {
      var c = el.children[i];
      if (c.tag === '#text') out += c.text;
      else {
        out += '<' + c.tag;
        for (var k in c.attrs) out += ' ' + k + '="' + c.attrs[k] + '"';
        out += '>' + _elHtml(c) + '</' + c.tag + '>';
      }
    }
    return out;
  }
  function _elAll(el) { return '<' + el.tag + '>' + _elHtml(el) + '</' + el.tag + '>'; }
  var TERMINALS = { text: 1, ownText: 1, textNodes: 1, html: 1, all: 1,
    href: 1, src: 1, content: 1, value: 1, title: 1, alt: 1, data: 1, action: 1 };
  function _legacySelect(roots, raw, includeRoots) {
    var selector = String(raw || '').trim(), exclude = null, indexes = null, text = null;
    var m;
    if ((m = /!(-?\d+)$/.exec(selector))) { exclude = parseInt(m[1], 10); selector = selector.slice(0, m.index); }
    if ((m = /\.(-?\d+(?::-?\d+)*)$/.exec(selector))) {
      indexes = m[1].split(':').map(function (s) { return parseInt(s, 10); });
      selector = selector.slice(0, m.index);
    }
    if (selector.indexOf('class.') === 0) selector = '.' + selector.slice(6);
    else if (selector.indexOf('id.') === 0) selector = '#' + selector.slice(3);
    else if (selector.indexOf('tag.') === 0) selector = selector.slice(4);
    else if (selector.indexOf('text.') === 0) { text = selector.slice(5); selector = '*'; }
    if (!selector) selector = '*';
    var selected = [];
    for (var i = 0; i < roots.length; i++) {
      var root = roots[i];
      if (text !== null) {
        var candidates = _descendants(root, true, []);
        for (var j = 0; j < candidates.length; j++) {
          var t = _elText(candidates[j]).trim();
          if (t === text || t.indexOf(text) >= 0) selected.push(candidates[j]);
        }
      } else {
        if (includeRoots && _matchCss(root, selector)) selected.push(root);
        var found = _querySelectorAll(root, selector);
        Array.prototype.push.apply(selected, found);
      }
    }
    // dedupe
    var seen = {}, dedup = [];
    for (var k = 0; k < selected.length; k++) {
      if (!selected[k].__id) selected[k].__id = 'n' + (LegadoDomSeq++);
      if (!seen[selected[k].__id]) { seen[selected[k].__id] = 1; dedup.push(selected[k]); }
    }
    if (exclude !== null) {
      var idx = exclude < 0 ? dedup.length + exclude : exclude;
      if (idx >= 0 && idx < dedup.length) dedup.splice(idx, 1);
    }
    if (indexes === null) return dedup;
    var out = [];
    for (var l = 0; l < indexes.length; l++) {
      var ix = indexes[l] < 0 ? dedup.length + indexes[l] : indexes[l];
      if (ix >= 0 && ix < dedup.length) out.push(dedup[ix]);
    }
    return out;
  }
  var LegadoDomSeq = 0;
  function _terminalValue(nodes, segment) {
    var seg = String(segment || '').trim();
    if (TERMINALS[seg]) {
      return nodes.map(function (n) {
        if (seg === 'text') return _elText(n);
        if (seg === 'ownText' || seg === 'textNodes') return _elOwnText(n);
        if (seg === 'html') return _elHtml(n);
        if (seg === 'all') return _elAll(n);
        return n.attrs[seg] !== undefined ? n.attrs[seg] : '';
      });
    }
    for (var i = 0; i < nodes.length; i++) {
      if (nodes[i].attrs && nodes[i].attrs[seg] !== undefined) {
        return nodes.map(function (n) { return n.attrs[seg] !== undefined ? n.attrs[seg] : ''; });
      }
    }
    return null;
  }
  function evalRule(html, rule) {
    var root = parseHTML(String(html || ''));
    var segments = String(rule || '').split('@').filter(function (s) { return s.length > 0; });
    if (!segments.length) return _elText(root);
    var current = [root];
    for (var i = 0; i < segments.length; i++) {
      var seg = segments[i].trim();
      var terminal = _terminalValue(current, seg);
      if (terminal !== null && i === segments.length - 1) return terminal.join('');
      current = _legacySelect(current, seg, i === 0);
      if (!current.length) return '';
    }
    return current.map(function (n) { return _elText(n); }).join('');
  }
  function evalRuleList(html, rule) {
    var root = parseHTML(String(html || ''));
    var segments = String(rule || '').split('@').filter(function (s) { return s.length > 0; });
    if (!segments.length) return [];
    var current = [root];
    for (var i = 0; i < segments.length; i++) {
      var seg = segments[i].trim();
      current = _legacySelect(current, seg, i === 0);
      if (!current.length) return [];
    }
    return current.map(function (n) { return _elAll(n); });
  }

  // ===================== java 桥 =====================
  var __kv = {};
  function __needResp(req) {
    var key = JSON.stringify(req);
    if (java.__responses && Object.prototype.hasOwnProperty.call(java.__responses, key)) {
      return java.__responses[key];
    }
    // 必须抛 Error 对象（而非裸字符串），QuickJS 桥才能安全转成 JSError。
    throw new Error('PREFETCH:' + key);
  }
  function __pad2(n) { return n < 10 ? '0' + n : '' + n; }
  function timeFormat(timestamp) {
    var d = new Date(Number(timestamp) || Date.now());
    return d.getFullYear() + '-' + __pad2(d.getMonth() + 1) + '-' + __pad2(d.getDate())
      + ' ' + __pad2(d.getHours()) + ':' + __pad2(d.getMinutes()) + ':' + __pad2(d.getSeconds());
  }
  var java = {
    __responses: {},
    __cookieUpdates: {},
    __cookies: {},
    __vars: {},
    __varUpdates: {},
    isDebug: false,
    version: '20240701',
    put: function (key, value) {
      if (value === undefined) return __kv[key] || (java.__vars[key] !== undefined ? java.__vars[key] : '');
      var str = String(value);
      __kv[key] = str;
      java.__vars[key] = str;
      java.__varUpdates[key] = str;
      return value;
    },
    get: function (keyOrUrl, headers) {
      if (arguments.length === 1 && typeof keyOrUrl === 'string'
        && !/^https?:\/\//i.test(keyOrUrl)) {
        return __kv[key] !== undefined && __kv[key] !== ''
          ? __kv[key]
          : (java.__vars[keyOrUrl] || '');
      }
      return __needResp({ method: 'GET', url: keyOrUrl, headers: headers });
    },
    ajax: function (urlOrOptions, timeout) {
      if (typeof urlOrOptions === 'object' && urlOrOptions !== null) {
        return __needResp(urlOrOptions);
      }
      return __needResp({ method: 'GET', url: String(urlOrOptions) });
    },
    post: function (url, body, headers) {
      return __needResp({ method: 'POST', url: url, body: body == null ? '' : String(body), headers: headers });
    },
    connect: function (urlStr, headers, timeout) {
      var raw = __needResp({ __connect: true, url: String(urlStr), headers: headers });
      var o = {};
      try { o = JSON.parse(raw); } catch (e) { o = { body: '', code: 0, headers: {} }; }
      return {
        body: function () { return o.body || ''; },
        header: function (name) { return (o.headers || {})[name] || ''; },
        code: function () { return o.code || 0; },
        headers: o.headers || {}
      };
    },
    // WebView 类 API：本引擎不内嵌 WebView，抛出可诊断错误。
    // 多数标记 webView 的源用普通 HTTP 也能取到数据。
    webViewGet: function (url, js) {
      throw new Error('Legado JS error: webView is not available; source requires an embedded WebView');
    },
    webViewJs: function (url, js) {
      throw new Error('Legado JS error: webView is not available; source requires an embedded WebView');
    },
    getWebViewHtml: function () {
      throw new Error('Legado JS error: webView is not available; source requires an embedded WebView');
    },
    head: function (urlStr, headers) {
      var raw = __needResp({ __connect: true, method: 'HEAD', url: String(urlStr), headers: headers });
      try { return JSON.parse(raw); } catch (e) { return {}; }
    },
    getElement: function (html, rule) {
      var v = evalRule(html, rule);
      return v === '' ? null : v;
    },
    getElements: function (html, rule) { return evalRuleList(html, rule); },
    getElementList: function (html, rule) { return evalRuleList(html, rule); },
    base64Encode: base64Encode,
    base64Decode: base64Decode,
    md5Encode: md5,
    md5Encode16: function (str) { return md5(str).slice(8, 24); },
    strToMd5: md5,
    hexDecode: function (str) {
      var out = '';
      for (var i = 0; i + 1 < str.length; i += 2) {
        out += String.fromCharCode(parseInt(str.substr(i, 2), 16));
      }
      return out;
    },
    hexEncode: function (str) {
      var out = '', i, b;
      for (i = 0; i < str.length; i++) {
        b = str.charCodeAt(i).toString(16);
        out += b.length < 2 ? '0' + b : b;
      }
      return out;
    },
    urlEncode: function (str) { return encodeURIComponent(String(str)); },
    urlDecode: function (str) { return decodeURIComponent(String(str)); },
    encodeURI: function (str) { return encodeURI(String(str)); },
    decodeURI: function (str) { return decodeURI(String(str)); },
    timeFormat: timeFormat,
    timeFormatUTC: timeFormat,
    getRandom: function (min, max) {
      return Math.floor(Math.random() * (max - min + 1)) + min;
    },
    getCookies: function (url) {
      var map = java.__cookies || {};
      if (map[url]) return map[url];
      var m = /^[a-z]+:\/\/([^\/]+)/i.exec(String(url || ''));
      if (m && map[m[1]]) return map[m[1]];
      return '';
    },
    setCookie: function (url, name, value) {
      var store = java.__cookieUpdates[url] || (java.__cookieUpdates[url] = {});
      store[name] = value;
      java.__cookies[url] = java.__cookies[url] || '';
      return value;
    },
    log: function (msg) { try { console.log('[legado-js] ' + msg); } catch (e) {} },
    getUA: function () {
      return 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36';
    }
  };
  global.java = java;
  global.base64Encode = base64Encode;
  global.base64Decode = base64Decode;
  global.md5 = md5;
  global.encode_base64 = base64Encode;
  global.decode_base64 = base64Decode;
  global.parseHTML = parseHTML;
  global.timeFormat = timeFormat;
  var source = {
    get: function (key) { return __kv['source_' + key] || ''; },
    set: function (key, value) { __kv['source_' + key] = String(value); return value; },
    bookSourceUrl: '',
    bookSourceName: '',
    bookSourceGroup: '',
    loginUrl: '',
    enabledCookieJar: true,
    enabledExplore: true,
    exploreUrl: ''
  };
  global.source = source;
  var cookie = {
    get: function (url) { return java.getCookies(url); },
    set: function (url, name, value) { return java.setCookie(url, name, value); },
    remove: function (url, name) { java.setCookie(url, name, ''); }
  };
  global.cookie = cookie;
})(this);
''';
