import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../entities/source_rule.dart';
import '../js/fjs_engine.dart';
import '../js/js_engine.dart';
import '../js/js_interp.dart';
import '../models/book_source.dart';
import '../services/cookie_service.dart';
import '../utils/encode_util.dart';
import '../utils/escape_util.dart';
import '../utils/url_util.dart';
import 'analyze_css.dart';
import 'analyze_json.dart';
import 'analyze_regex.dart';
import 'analyze_xpath.dart';

/// 解析数据的上下文（对应官方 `AnalyzeRule`）。
///
/// 负责：
/// - 把规则串拆分多段链（JS 模式 / WebJS / 普通规则）
/// - 逐段求值：CSS / XPath / Json / Regex / Js
/// - `@put:`、`@get:`、`{{}}`、`##` 替换等官方语义
/// - 变量存取（putVariable / getVariable）
class AnalyzeRule {
  AnalyzeRule({
    this.source,
    JsEngine? jsEngine,
    this.jsEvaluator,
  }) : jsEngine = jsEngine ?? const JsEngineStub();

  /// 数据源（书源，提供变量表），可为 null。
  final dynamic source;

  /// JS 引擎抽象（当前为 stub）。
  final JsEngine jsEngine;

  /// 同步 JS 求值回调（接入真实引擎后注入）。未接入时透传 null。
  String? Function(String js, Object? result)? jsEvaluator;

  final Map<String, List<SourceRule>> _stringRuleCache = {};
  final Map<String, RegExp?> _regexCache = {};

  /// jsLib 全局变量缓存（按书源 URL 一次执行）。
  final Map<String, Map<String, Object?>> _jsLibCache = {};

  /// 完整解析上下文（HTML / JSON / 文本）。
  Object? _content;
  String? _baseUrl;
  bool _isJson = false;
  bool _isRegex = false;

  /// 变量表（对应官方 BaseSource 的 putVariable / getVariable）。
  final Map<String, String> _variables = {};

  /// 临时本地绑定（setLocal）。
  final Map<String, String> _localBindings = {};

  /// 规则名（用于日志 tag）。
  String? ruleName;
  void setRuleName(String name) {
    if (name.trim().isNotEmpty) ruleName = name;
  }

  void setContent(Object? content, {String? baseUrl}) {
    if (content == null) {
      throw ArgumentError('内容不可空（Content cannot be null）');
    }
    _content = content;
    _isJson = content is Map || content is List
        ? true
        : _looksLikeJson(content.toString());
    setBaseUrl(baseUrl);
  }

  void setBaseUrl(String? baseUrl) {
    if (baseUrl != null && baseUrl.isNotEmpty) _baseUrl = baseUrl;
  }

  bool _looksLikeJson(String s) {
    final t = s.trim();
    if (t.startsWith('{') || t.startsWith('[')) {
      try {
        jsonDecode(t);
        return true;
      } catch (_) {
        return false;
      }
    }
    return false;
  }

  // ---------------------------------------------------------------------
  // 变量存取（putVariable / getVariable）
  // ---------------------------------------------------------------------

  /// 保存变量，返回新值（官方 `put`）。
  String put(String key, String value) {
    _variables[key] = value;
    return value;
  }

  /// 设置本地绑定（setLocal），在 get 中优先命中。
  AnalyzeRule setLocal(String key, String value) {
    _localBindings[key] = value;
    return this;
  }

  /// 取变量（官方 `get`）。
  String get(String key) {
    final local = _localBindings[key];
    if (local != null) return local;
    return _variables[key] ?? '';
  }

  /// 取变量（官方 `getVariable`）：先查本地绑定，再查变量表（`@` 前缀归一），最后解析特殊变量。
  String getVariable(String key) {
    final bare = key.startsWith('@') ? key.substring(1) : key;
    final local = _localBindings[bare];
    if (local != null) return local;
    final stored = _variables[bare];
    if (stored != null) return stored;
    if (key.startsWith('@')) {
      final special = _specialVar(key);
      if (special != null) return special;
    }
    return '';
  }

  /// 设置变量（官方 `putVariable`），写入变量表。
  void setVariable(String key, String value) {
    _variables[key] = value;
  }

  /// 取原始变量表（供调试/序列化）。
  Map<String, String> get variables => Map.of(_variables);

  String _resolveVar(String keyOrRule) {
    // `@put` 中存的值直接用键名取变量
    final special = _specialVar(keyOrRule);
    if (special != null) return special;
    return get(keyOrRule);
  }

  /// 解析官方预置的特殊变量（@baseUrl/@host/@source/@cookie/@date/...）。
  ///
  /// 仅值变量在此解析；函数式 `@xxx(...)` 交由 JS 绑定处理。
  String? _specialVar(String name) {
    final key = name.startsWith('@') ? name.substring(1) : name;
    return switch (key.toLowerCase()) {
      'baseurl' => _baseUrl ?? '',
      'host' || 'source' || 'sourceurl' =>
        _hostOfBaseUrl(),
      'sourcekey' => source != null
          ? ((source is BookSource) ? (source as BookSource).bookSourceUrl : source.toString())
          : '',
      'cook' || 'cookie' => _cookieForDomain(),
      'date' || 'now' => _nowStamp(),
      'dateweek' => _dateWeek(),
      'timestamp' => '${DateTime.now().millisecondsSinceEpoch}',
      _ => null,
    };
  }

  String _hostOfBaseUrl() {
    final b = _baseUrl;
    if (b != null && b.isNotEmpty) {
      final u = Uri.tryParse(b);
      if (u != null && u.host.isNotEmpty) return u.host;
    }
    return '';
  }

  String _cookieForDomain() {
    final host = _hostOfBaseUrl();
    if (host.isEmpty) return '';
    return CookieService.instance.cookieHeaderFor(host);
  }

  static String _nowStamp() {
    final d = DateTime.now();
    String p(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${p(d.month)}-${p(d.day)} ${p(d.hour)}:${p(d.minute)}:${p(d.second)}';
  }

  static String _dateWeek() {
    const weeks = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];
    return weeks[DateTime.now().weekday % 7];
  }

  /// `$api` / `java` 桥接对象的同步工具方法。
  ///
  /// 网络类接口（get/getStr/getJson/post）在同步解释器内无法阻塞返回，按官方
  /// `$api.get` 语义返回空串，规则链可正常继续；纯字符串/编码/URL/时间工具可直接调用。
  Map<String, dynamic> _jsApiBridge() {
    final baseUrl = _baseUrl;
    return {
      'base64Encode': (String s) => EncodeUtil.base64Encode(s),
      'base64Decode': (String s) => EncodeUtil.base64Decode(s),
      'base64UrlEncode': (String s) => EncodeUtil.base64UrlEncode(s),
      'base64UrlDecode': (String s) => EncodeUtil.base64UrlDecode(s),
      'encodeURIComponent': (String s) => EncodeUtil.uriEncode(s, component: true),
      'decodeURIComponent': (String s) => EncodeUtil.uriDecode(s),
      'escape': (String s) => EncodeUtil.escape(s),
      'unescape': (String s) => EncodeUtil.unescape(s),
      'jsonToString': (Object? o) => jsonEncode(o),
      // URL 相对转绝对（官方 $api.getAbsoluteURL / uriFull）
      'getAbsoluteURL': (String u) => UrlUtil.getAbsoluteURL(baseUrl, u),
      'uriFull': (String u) => UrlUtil.getAbsoluteURL(baseUrl, u),
      // 去掉 query/fragment 取纯净 URL
      'stripQuery': (String u) {
        final idx = u.indexOf(RegExp(r'[?#]'));
        return idx >= 0 ? u.substring(0, idx) : u;
      },
      'now': () => '${DateTime.now().millisecondsSinceEpoch}',
      'date': () => _nowStamp(),
      'formatDate': (Object? fmt) => _formatDate(fmt),
      // 网络请求在同步解释器内无法阻塞返回，统一返回空（合法 JS 用法不受影响）。
      'get': (_) => '',
      'getStr': (_) => '',
      'getJson': (_) => '',
      'post': (_) => '',
    };
  }

  Map<String, dynamic> _jsJavaBridge() => {
        'ajax': (Object? _) => '',
        'http': (Object? _) => '',
      };

  static String _formatDate(Object? fmt) {
    final f = fmt?.toString() ?? 'yyyy-MM-dd HH:mm:ss';
    final d = DateTime.now();
    String p(num n, [int w = 2]) => n.toString().padLeft(w, '0');
    return f
        .replaceAll('yyyy', '${d.year}')
        .replaceAll('MM', p(d.month))
        .replaceAll('dd', p(d.day))
        .replaceAll('HH', p(d.hour))
        .replaceAll('mm', p(d.minute))
        .replaceAll('ss', p(d.second));
  }

  // ---------------------------------------------------------------------
  // 规则拆分（官方 splitSourceRule）
  // ---------------------------------------------------------------------

  /// 拆分为规则链，缓存 key = 规则串。
  List<SourceRule> getStringRules(String ruleStr) {
    if (ruleStr.isEmpty) return const [];
    return _stringRuleCache.putIfAbsent(ruleStr, () => splitSourceRule(ruleStr));
  }

  /// 官方 `splitSourceRule`：按 JS 模式、WebJS 模式切分，其余按当前 mode 聚合。
  List<SourceRule> splitSourceRule(String ruleStr, {bool allInOne = false}) {
    if (ruleStr.trim().isEmpty) return const [];
    final ruleList = <SourceRule>[];
    var mode = RuleMode.css;
    var start = 0;

    // AllInOne 时 `:regex` 开头整个串为正则
    if (allInOne && ruleStr.startsWith(':')) {
      mode = RuleMode.regex;
      _isRegex = true;
      start = 1;
    } else if (_isRegex) {
      mode = RuleMode.regex;
    }

    // JS 内联：{{js}} / {{}} / <js>
    final jsMatches = kJsPattern.allMatches(ruleStr).toList();
    for (final m in jsMatches) {
      if (m.start > start) {
        final tmp = ruleStr.substring(start, m.start).trim();
        if (tmp.isNotEmpty) {
          ruleList.add(SourceRule(tmp, initialMode: mode, isJson: _isJson));
        }
      }
      ruleList.add(SourceRule((m.group(1) ?? m.group(2) ?? m.group(3) ?? '').trim(),
          initialMode: RuleMode.js));
      start = m.end;
    }
    // WebJS
    final webJsMatches = kWebJsPattern.allMatches(ruleStr).toList();
    for (final m in webJsMatches) {
      if (m.start > start) {
        final tmp = ruleStr.substring(start, m.start).trim();
        if (tmp.isNotEmpty) {
          ruleList.add(SourceRule(tmp, initialMode: mode, isJson: _isJson));
        }
      }
      ruleList.add(
          SourceRule(m.group(1) ?? m.group(2) ?? '', initialMode: RuleMode.webJs));
      start = m.end;
    }
    if (ruleStr.length > start) {
      final tmp = ruleStr.substring(start).trim();
      if (tmp.isNotEmpty) ruleList.add(SourceRule(tmp, initialMode: mode, isJson: _isJson));
    }
    return ruleList;
  }

  // ---------------------------------------------------------------------
  // 求值主路径
  // ---------------------------------------------------------------------

  /// 获取文本（官方 `getString`），多段链逐步求值。
  String getString(
    String sourceRule, {
    Object? mContent,
    bool isUrl = false,
    bool unescape = true,
  }) {
    if (sourceRule.trim().isEmpty) return '';
    final ruleList = getStringRules(sourceRule);
    return _getString(
      ruleList,
      mContent: mContent,
      isUrl: isUrl,
      unescape: unescape,
    );
  }

  String _getString(
    List<SourceRule> ruleList, {
    Object? mContent,
    bool isUrl = false,
    bool unescape = true,
  }) {
    Object? result = mContent ?? _content;
    if (ruleList.isEmpty || result == null) return '';

    // 键值 / JSON 直取（Map）
    if (result is Map) {
      final sr = ruleList.first;
      sr.makeUpRule(result,
          resolveVar: _resolveVar, evalJs: (js) => _jsEvalWrap(js, result));
      result = switch (sr.mode) {
        RuleMode.js => _evalJs(sr.rule, result),
        RuleMode.json => AnalyzeJson.getString(ruleValueOf(result), sr.rule),
        _ when sr.paramSize > 1 => sr.rule,
        _ => result[sr.rule],
      };
      if (result != null && sr.hasReplaceRegex) {
        result = _replaceRegex(result.toString(), sr);
      }
    } else {
      for (final sr in ruleList) {
        result = _evalSegment(sr, result, isUrl: isUrl);
      }
    }
    if (result == null) return '';
    var str = result.toString();
    if (unescape && str.contains('&')) {
      str = EscapeUtil.unescape(str);
    }
    if (isUrl) {
      if (str.trim().isEmpty) return _baseUrl ?? '';
      return UrlUtil.getAbsoluteURL(_baseUrl, str);
    }
    return str;
  }

  /// 获取字符串列表（官方 `getStringList`）。
  List<String>? getStringList(
    String sourceRule, {
    Object? mContent,
    bool isUrl = false,
  }) {
    if (sourceRule.trim().isEmpty) return null;
    final ruleList = getStringRules(sourceRule);
    Object? result = mContent ?? _content;
    if (result == null || ruleList.isEmpty) return null;

    if (result is Map) {
      final sr = ruleList.first;
      sr.makeUpRule(result, resolveVar: _resolveVar, evalJs: (js) => _jsEvalWrap(js, result));
      result = (sr.mode == RuleMode.js)
          ? _evalJs(sr.rule, result)
          : (sr.mode == RuleMode.json)
              ? AnalyzeJson.getList(ruleValueOf(result), sr.rule)
              : (sr.paramSize > 1 ? sr.rule : result[sr.rule]);
      result = _applyReplaceList(result, sr);
    } else {
      // 列表语义：CSS/XPath/Json/Regex 分别取全部匹配值
      final combined = <String>[];
      for (final sr in ruleList) {
        sr.makeUpRule(result, resolveVar: _resolveVar, evalJs: (js) => _jsEvalWrap(js, result));
        switch (sr.mode) {
          case RuleMode.css:
            combined.addAll(AnalyzeCss.getStringList(ruleValueOf(result), sr.rule));
          case RuleMode.regex:
            combined.addAll(AnalyzeRegex.getList(ruleValueOf(result), sr.rule)
                .map((v) => (v as RuleTextValue).text));
          case RuleMode.xPath:
            combined.addAll([
              for (final h in AnalyzeXPath.getElements(ruleValueOf(result), sr.rule))
                h.element.text.trim()
            ]);
          case RuleMode.json:
            combined.addAll(AnalyzeJson.getList(ruleValueOf(result), sr.rule)
                .map((v) => (v as RuleJsonValue).value.toString()));
          case RuleMode.webJs:
            break; // 无后端沙箱
          case RuleMode.js:
            final r = _evalJs(sr.rule, result);
            if (r != null) combined.add(r.toString());
        }
      }
      if (combined.isEmpty) return null;
      result = combined;
    }
    if (result == null) return null;
    if (result is String) result = result.split('\n');
    if (isUrl) {
      final urls = <String>[];
      for (final item in (result as List)) {
        final abs = UrlUtil.getAbsoluteURL(_baseUrl, item.toString());
        if (abs.isNotEmpty && !urls.contains(abs)) urls.add(abs);
      }
      return urls;
    }
    final r = result;
    return r is List ? r.map((e) => e.toString()).toList() : null;
  }

  /// 获取元素（官方 `getElement`）。
  Object? getElement(String sourceRule) {
    if (sourceRule.trim().isEmpty) return null;
    final ruleList = getStringRules(sourceRule);
    return _getElements(ruleList, asList: false);
  }

  /// 获取元素列表（官方 `getElements`）。
  List<Object> getElements(String sourceRule) {
    final r = _getElements(getStringRules(sourceRule), asList: true);
    return r is List ? r.whereType<Object>().toList() : const [];
  }

  Object? _getElements(List<SourceRule> ruleList, {required bool asList}) {
    var result = _content;
    if (result == null) return asList ? <Object>[] : null;
    for (final sr in ruleList) {
      final mode = sr.mode;
      sr.makeUpRule(result, resolveVar: _resolveVar, evalJs: (js) => _jsEvalWrap(js, result));
      switch (mode) {
        case RuleMode.regex:
          final regs = sr.rule.split('&&').where((e) => e.isNotEmpty).toList();
          result = asList
              ? AnalyzeRegex.getList(ruleValueOf(result), sr.rule)
                  .map((v) => (v as RuleTextValue).text)
                  .toList()
              : AnalyzeRegex.getElementsObject(result.toString(), regs);
        case RuleMode.webJs:
          result = null; // 跨平台版无后端沙箱
        case RuleMode.js:
          result = _evalJs(sr.rule, result);
        case RuleMode.json:
          result = asList
              ? AnalyzeJson.getList(ruleValueOf(result), sr.rule)
                  .map((v) => (v as RuleJsonValue).value)
                  .toList()
              : AnalyzeJson.getObject(ruleValueOf(result), sr.rule);
        case RuleMode.xPath:
          final hits = AnalyzeXPath.getElements(ruleValueOf(result), sr.rule);
          result = hits.map((h) => h.element).toList();
        case RuleMode.css:
          final hits = AnalyzeCss.getElements(ruleValueOf(result), sr.rule);
          result = hits.map((h) => h.element).toList();
      }
      if (result is Map || result is String) {
        if (sr.hasReplaceRegex) result = _replaceRegex(result.toString(), sr);
      } else if (result is List && sr.hasReplaceRegex) {
        result = result
            .map((e) => _replaceRegex(e.toString(), sr))
            .toList();
      }
    }
    return result;
  }

  /// 单步求值（字符串语义），官方 getString 主循环。
  Object? _evalSegment(SourceRule sr, Object? result, {bool isUrl = false}) {
    if (result == null) return null;
    // put 变量
    for (final e in sr.putMap.entries) {
      put(e.key, _evalValueRule(e.value, result));
    }
    final rule = sr.makeUpRule(result, resolveVar: _resolveVar, evalJs: (js) => _jsEvalWrap(js, result));
    if (rule.isNotEmpty) {
      switch (sr.mode) {
        case RuleMode.webJs:
          result = null; // 无后端沙箱
        case RuleMode.js:
          result = _evalJs(rule, result);
        case RuleMode.json:
          result = AnalyzeJson.getString(ruleValueOf(result), rule);
        case RuleMode.xPath:
          result = AnalyzeXPath.getString(ruleValueOf(result), rule);
        case RuleMode.regex:
          result = rule; // {{}} 构造串原样返回
        case RuleMode.css:
          result = AnalyzeCss.getString(ruleValueOf(result), rule, isUrl: isUrl);
      }
    }
    if (result != null && sr.hasReplaceRegex) {
      result = _replaceRegex(result.toString(), sr);
    }
    return result;
  }

  // ---------------------------------------------------------------------
  // 异步求值入口（JS 段走 Fjs QuickJS，非 JS 段保持同步）
  // ---------------------------------------------------------------------

  /// 异步版单步求值。
  Future<Object?> _evalSegmentAsync(
    SourceRule sr,
    Object? result, {
    bool isUrl = false,
  }) async {
    if (result == null) return null;
    for (final e in sr.putMap.entries) {
      put(e.key, _evalValueRule(e.value, result));
    }
    final rule = sr.makeUpRule(result, resolveVar: _resolveVar, evalJs: (js) => _jsEvalWrap(js, result));
    if (rule.isNotEmpty) {
      switch (sr.mode) {
        case RuleMode.webJs:
          result = null; // 无后端沙箱
        case RuleMode.js:
          result = await _evalJsAsync(rule, result);
        case RuleMode.json:
          result = AnalyzeJson.getString(ruleValueOf(result), rule);
        case RuleMode.xPath:
          result = AnalyzeXPath.getString(ruleValueOf(result), rule);
        case RuleMode.regex:
          result = rule;
        case RuleMode.css:
          result = AnalyzeCss.getString(ruleValueOf(result), rule, isUrl: isUrl);
      }
    }
    if (result != null && sr.hasReplaceRegex) {
      result = _replaceRegex(result.toString(), sr);
    }
    return result;
  }

  /// 异步获取文本。与 [getString] 语义一致，JS 段经 Fjs 求值。
  Future<String> getStringAsync(
    String sourceRule, {
    Object? mContent,
    bool isUrl = false,
    bool unescape = true,
  }) async {
    if (sourceRule.trim().isEmpty) return '';
    Object? result = mContent ?? _content;
    final ruleList = getStringRules(sourceRule);
    if (ruleList.isEmpty || result == null) return '';

    if (result is Map) {
      final sr = ruleList.first;
      sr.makeUpRule(result, resolveVar: _resolveVar, evalJs: (js) => _jsEvalWrap(js, result));
      result = switch (sr.mode) {
        RuleMode.js => await _evalJsAsync(sr.rule, result),
        RuleMode.json => AnalyzeJson.getString(ruleValueOf(result), sr.rule),
        _ when sr.paramSize > 1 => sr.rule,
        _ => result[sr.rule],
      };
      if (result != null && sr.hasReplaceRegex) {
        result = _replaceRegex(result.toString(), sr);
      }
    } else {
      for (final sr in ruleList) {
        result = await _evalSegmentAsync(sr, result, isUrl: isUrl);
      }
    }
    if (result == null) return '';
    var str = result.toString();
    if (unescape && str.contains('&')) str = EscapeUtil.unescape(str);
    if (isUrl) {
      if (str.trim().isEmpty) return _baseUrl ?? '';
      return UrlUtil.getAbsoluteURL(_baseUrl, str);
    }
    return str;
  }

  /// 异步获取元素。与 [getElements] 语义一致。
  Future<List<Object>> getElementsAsync(String sourceRule) async {
    final r = await _getElementsAsync(getStringRules(sourceRule), asList: true);
    return r is List ? r.whereType<Object>().toList() : const [];
  }

  /// 异步获取单个元素。
  Future<Object?> getElementAsync(String sourceRule) async {
    if (sourceRule.trim().isEmpty) return null;
    return _getElementsAsync(getStringRules(sourceRule), asList: false);
  }

  /// 异步获取字符串列表。
  Future<List<String>?> getStringListAsync(
    String sourceRule, {
    Object? mContent,
    bool isUrl = false,
  }) async {
    if (sourceRule.trim().isEmpty) return null;
    final ruleList = getStringRules(sourceRule);
    Object? result = mContent ?? _content;
    if (result == null || ruleList.isEmpty) return null;

    if (result is Map) {
      final sr = ruleList.first;
      sr.makeUpRule(result, resolveVar: _resolveVar, evalJs: (js) => _jsEvalWrap(js, result));
      result = (sr.mode == RuleMode.js)
          ? await _evalJsAsync(sr.rule, result)
          : (sr.mode == RuleMode.json)
              ? AnalyzeJson.getList(ruleValueOf(result), sr.rule)
              : (sr.paramSize > 1 ? sr.rule : result[sr.rule]);
      result = _applyReplaceList(result, sr);
    } else {
      final combined = <String>[];
      for (final sr in ruleList) {
        sr.makeUpRule(result, resolveVar: _resolveVar, evalJs: (js) => _jsEvalWrap(js, result));
        switch (sr.mode) {
          case RuleMode.css:
            combined.addAll(AnalyzeCss.getStringList(ruleValueOf(result), sr.rule));
          case RuleMode.regex:
            combined.addAll(AnalyzeRegex.getList(ruleValueOf(result), sr.rule)
                .map((v) => (v as RuleTextValue).text));
          case RuleMode.xPath:
            combined.addAll([
              for (final h in AnalyzeXPath.getElements(ruleValueOf(result), sr.rule))
                h.element.text.trim()
            ]);
          case RuleMode.json:
            combined.addAll(AnalyzeJson.getList(ruleValueOf(result), sr.rule)
                .map((v) => (v as RuleJsonValue).value.toString()));
          case RuleMode.webJs:
            break;
          case RuleMode.js:
            final r = await _evalJsAsync(sr.rule, result);
            if (r != null) combined.add(r.toString());
        }
      }
      if (combined.isEmpty) return null;
      result = combined;
    }
    if (result == null) return null;
    if (result is String) result = result.split('\n');
    if (isUrl) {
      final urls = <String>[];
      for (final item in (result as List)) {
        final abs = UrlUtil.getAbsoluteURL(_baseUrl, item.toString());
        if (abs.isNotEmpty && !urls.contains(abs)) urls.add(abs);
      }
      return urls;
    }
    final r = result;
    return r is List ? r.map((e) => e.toString()).toList() : null;
  }

  Future<Object?> _getElementsAsync(
    List<SourceRule> ruleList, {
    required bool asList,
  }) async {
    var result = _content;
    if (result == null) return asList ? <Object>[] : null;
    for (final sr in ruleList) {
      final mode = sr.mode;
      sr.makeUpRule(result, resolveVar: _resolveVar, evalJs: (js) => _jsEvalWrap(js, result));
      switch (mode) {
        case RuleMode.regex:
          final regs = sr.rule.split('&&').where((e) => e.isNotEmpty).toList();
          result = asList
              ? AnalyzeRegex.getList(ruleValueOf(result), sr.rule)
                  .map((v) => (v as RuleTextValue).text)
                  .toList()
              : AnalyzeRegex.getElementsObject(result.toString(), regs);
        case RuleMode.webJs:
          result = null;
        case RuleMode.js:
          result = await _evalJsAsync(sr.rule, result);
        case RuleMode.json:
          result = asList
              ? AnalyzeJson.getList(ruleValueOf(result), sr.rule)
                  .map((v) => (v as RuleJsonValue).value)
                  .toList()
              : AnalyzeJson.getObject(ruleValueOf(result), sr.rule);
        case RuleMode.xPath:
          final hits = AnalyzeXPath.getElements(ruleValueOf(result), sr.rule);
          result = hits.map((h) => h.element).toList();
        case RuleMode.css:
          final hits = AnalyzeCss.getElements(ruleValueOf(result), sr.rule);
          result = hits.map((h) => h.element).toList();
      }
      if (result is Map || result is String) {
        if (sr.hasReplaceRegex) result = _replaceRegex(result.toString(), sr);
      } else if (result is List && sr.hasReplaceRegex) {
        result = result.map((e) => _replaceRegex(e.toString(), sr)).toList();
      }
    }
    return result;
  }

  /// put 值本身可能含 `@get:` / `{{}}`，需递归求值。
  String _evalValueRule(String value, Object? result) {
    return getString(value, mContent: result);
  }

  Object? _applyReplaceList(Object? result, SourceRule sr) {
    if (result is List && sr.hasReplaceRegex) {
      return result.map((e) => _replaceRegex(e.toString(), sr)).toList();
    }
    if (result != null && sr.hasReplaceRegex) {
      return _replaceRegex(result.toString(), sr);
    }
    return result;
  }

  // ---------------------------------------------------------------------
  // 正则替换（官方 replaceRegex）
  // ---------------------------------------------------------------------

  String _replaceRegex(String result, SourceRule sr) {
    if (sr.replaceRegex.isEmpty) return result;
    final regex = compileRegex(sr.replaceRegex);
    if (sr.replaceFirst) {
      // ##m##r###：取第一个匹配替换
      if (regex == null) return sr.replacement;
      final m = regex.firstMatch(result);
      if (m == null) return '';
      return result.replaceRange(m.start, m.end, sr.replacement);
    }
    if (regex == null) {
      return result.replaceAll(sr.replaceRegex, sr.replacement);
    }
    return result.replaceAllMapped(regex, (m) {
      var out = sr.replacement;
      for (var i = 0; i <= m.groupCount; i++) {
        out = out.replaceAll('\$$i', m.group(i) ?? '');
      }
      return out;
    });
  }

  RegExp? compileRegex(String s) {
    try {
      return _regexCache.putIfAbsent(s, () => RegExp(s));
    } catch (_) {
      _regexCache[s] = null;
      return null;
    }
  }

  // ---------------------------------------------------------------------
  // JS 执行
  // ---------------------------------------------------------------------

  String? _jsEvalWrap(String js, Object? result) => _evalJs(js, result)?.toString();

  Object? _evalJs(String js, Object? result) {
    if (jsEvaluator != null) return jsEvaluator!(js, result);
    return _dartJsEval(js, result);
  }

  /// 异步求值 JS 段：优先用 Fjs（fjs QuickJS），不可用/失败降级到纯 Dart 解释器。
  Future<Object?> _evalJsAsync(String js, Object? result) async {
    try {
      final fjsEngine = FjsJsEngine.instance;
      await fjsEngine.ensureReady();
      if (fjsEngine.isAvailable) {
        final v =
            await fjsEngine.evaluate(js, bindings: _buildJsBindings(result));
        if (v != null) return v;
      }
    } catch (_) {}
    return _dartJsEval(js, result);
  }

  /// 提取 JS 段所需的响应式绑定（不含 `$api`/`java`，由各引擎注入）。
  Map<String, Object?> _buildJsBindings(Object? result) {
    final bindings = <String, Object?>{};
    if (result != null) bindings['result'] = result;
    if (_baseUrl != null) bindings['baseUrl'] = _baseUrl;
    bindings.addAll(_variables);
    bindings.addAll(_localBindings);
    bindings.putIfAbsent('host', () => _hostOfBaseUrl());
    bindings.putIfAbsent('cookie', () => _cookieForDomain());
    bindings.putIfAbsent('source',
        () => source is BookSource ? (source as BookSource).bookSourceName : '');
    bindings.putIfAbsent('date', () => _nowStamp());
    bindings.putIfAbsent('timestamp', () => '${DateTime.now().millisecondsSinceEpoch}');
    final src = source;
    if (src is BookSource) bindings.addAll(_jsLibOnce(src));
    return bindings;
  }

  /// 用纯 Dart 解释器执行 [js]。注入 `result` / `baseUrl` / 变量绑定，
  /// 求值失败或返回 undefined 时按空串处理，保证规则链继续。
  Object? _dartJsEval(String js, Object? result) {
    final bindings = <String, Object?>{};
    if (result != null) bindings['result'] = result;
    if (_baseUrl != null) bindings['baseUrl'] = _baseUrl;
    bindings.addAll(_variables);
    bindings.addAll(_localBindings);
    // 注入官方更名的预置变量（host/cookie/source/date 等），供 @js 规则引用。
    bindings.putIfAbsent('host', () => _hostOfBaseUrl());
    bindings.putIfAbsent('cookie', () => _cookieForDomain());
    bindings.putIfAbsent('source',
        () => source is BookSource ? (source as BookSource).bookSourceName : '');
    bindings.putIfAbsent('date', () => _nowStamp());
    bindings.putIfAbsent('timestamp', () => '${DateTime.now().millisecondsSinceEpoch}');
    // 注入 JS 桥接对象 `$api` / `java`（纯函数用法官方 $api.get/http 依赖网络，同步解释器返回空；
    // 字符串/编码/时间等工具直接可用）。
    bindings['api'] = DartJs.js(_jsApiBridge());
    bindings[r'$api'] = DartJs.js(_jsApiBridge());
    bindings['java'] = DartJs.js(_jsJavaBridge());
    // 注入书源 jsLib 定义的全局函数/变量，供 `@js:` / `<js>` 规则引用。
    final src = source;
    if (src is BookSource) bindings.addAll(_jsLibOnce(src));
    try {
      final v = DartJs(bindings: bindings).evaluateExpression(js);
      return v ?? '';
    } catch (_) {
      return '';
    }
  }

  /// 一次性执行书源 jsLib，缓存其全局变量。
  Map<String, Object?> _jsLibOnce(BookSource src) {
    return _jsLibCache.putIfAbsent(src.bookSourceUrl, () {
      final lib = src.jsLib;
      if (lib == null || lib.trim().isEmpty) return const {};
      try {
        return DartJs().runValues(lib);
      } catch (_) {
        return const {};
      }
    });
  }

  // ---------------------------------------------------------------------
  // 桥接辅助
  // ---------------------------------------------------------------------

  /// 把任意结果包装成 [RuleValue] 供分析器使用。
  RuleValue ruleValueOf(Object? v) {
    if (v is dom.Element) return RuleElementValue(v);
    if (v is Map || v is List) return RuleJsonValue(v);
    if (v is bool || v is num) return RuleJsonValue(v);
    return RuleTextValue(v?.toString() ?? '');
  }

  /// 从 HTML 文本解析出根节点。
  static dom.Document parseHtml(String html) => html_parser.parse(html);
}