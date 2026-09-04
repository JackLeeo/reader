import 'package:html/dom.dart' as dom;

/// JS 内联片段：官方 `AppPattern.JS_PATTERN`，`<js>...</js>` 或 `@js:...`。
/// group(1)=`<js>`体，group(2)=`@js:...`体。
final RegExp kJsPattern =
    RegExp(r'<js>([\w\W]*?)</js>|@js:([\w\W]*)', caseSensitive: false);

/// WebJs 片段：官方 `WebJS_PATTERN`，`@webjs:...`。
final RegExp kWebJsPattern = RegExp(r'@webjs:([\w\W]{5,})', caseSensitive: false);

/// 内联求值段（经 SourceRule 内部 resolve）：`@get:{...}` 取变量、`{{...}}` JS。
/// 官方 `AnalyzeRule.evalPattern`。
final RegExp kEvalPattern =
    RegExp(r'@get:\{[^}]+?\}|\{\{[\w\W]*?\}\}', caseSensitive: false);

/// `@put:{...}` 保存变量：官方 `AnalyzeRule.putPattern`。
final RegExp kPutPattern = RegExp(r'@put:\{([^}]+?)\}', caseSensitive: false);

/// 反向引用 `$1`：官方 `AnalyzeRule.regexPattern`。
final RegExp kBackrefPattern = RegExp(r'\$\d{1,2}');

/// 规则执行类型（对应官方 `AnalyzeRule.Mode`）。
enum RuleMode {
  /// jsoup CSS（Default）
  css,
  /// JSONPath
  json,
  /// XPath
  xPath,
  /// JavaScript
  js,
  /// 正则（也用于 `{{}}` 构造字符串后原样返回）
  regex,
  /// Web 后端沙箱（跨平台版不可用，透传）
  webJs,
}

/// 一条已解析的规则（对应官方 `AnalyzeRule.SourceRule`）。
///
/// 语义完整对齐官方：
/// - `rule`         规则体（去前缀/拆分后）
/// - `mode`         执行类型（构造时推导，`{{}}` 参与时改为 regex 构造串）
/// - `putMap`        `@put:{json}` 需保存的变量
/// - `ruleParam`/`ruleType`  `@get:{k}` / `{{js}}` / `$1` 参数（在 [makeUpRule] 展开）
/// - `replaceRegex`/`replacement`/`replaceFirst`  `##` 替换
class SourceRule {
  SourceRule(
    String ruleStr, {
    RuleMode? initialMode,
    bool isJson = false,
    bool isRegex = false,
  }) {
    _setupRule(ruleStr, initialMode, isJson: isJson, isRegex: isRegex);
  }

  /// 推导后的执行类型
  RuleMode mode = RuleMode.css;

  /// 规则体（未经过 [makeUpRule] 展开前的原始体）
  String rule = '';

  /// `@put:{json}` 保存的变量映射
  final Map<String, String> putMap = {};

  /// 替换正则（`##` 分隔的第一段）
  String replaceRegex = '';

  /// 替换内容（第二段）
  String replacement = '';

  /// 是否只替换第一个匹配（四段式 `##m##r##k`）
  bool replaceFirst = false;

  /// 参数体列表（`@get:{k}` / `{{js}}` / `$N` 截取）
  final List<String> ruleParam = [];

  /// 参数类型：`>0`=正则引用组，`-1`=JS，`-2`=get 变量，`0`=普通文本
  final List<int> ruleType = [];

  static const int _getRuleType = -2;
  static const int _jsRuleType = -1;
  static const int _defaultRuleType = 0;

  bool get hasReplaceRegex => replaceRegex.isNotEmpty;

  int get paramSize => ruleParam.length;

  bool get isNotEmpty => rule.trim().isNotEmpty;

  /// 对应官方 `SourceRule.isRule`：JS 参数是否应作为规则递归解析。
  static bool _isRule(String s) =>
      s.startsWith('@') || s.startsWith('\$.') || s.startsWith('\$[') || s.startsWith('//');

  /// 初始化，对齐官方构造函数 init 块。
  void _setupRule(String ruleStr, RuleMode? initialMode,
      {required bool isJson, required bool isRegex}) {
    mode = initialMode ?? RuleMode.css;
    rule = ruleStr;

    if (mode == RuleMode.js || mode == RuleMode.regex) {
      // JS / 正则规则体不做前缀识别
    } else if (rule.startsWith('@CSS:')) {
      mode = RuleMode.css;
    } else if (rule.startsWith('@@')) {
      mode = RuleMode.css;
      rule = rule.substring(2);
    } else if (rule.startsWith('@XPath:')) {
      mode = RuleMode.xPath;
      rule = rule.substring(7);
    } else if (rule.startsWith('@Json:')) {
      mode = RuleMode.json;
      rule = rule.substring(6);
    } else if (isJson || rule.startsWith('\$.') || rule.startsWith('\$[')) {
      mode = RuleMode.json;
    } else if (rule.startsWith('/')) {
      // XPath 特征明显，无需识别头
      mode = RuleMode.xPath;
    }

    // 分离 put
    rule = _splitPutRule(rule, putMap);

    // @get:{...} / {{...}} 参数
    var start = 0;
    final evalMatches = kEvalPattern.allMatches(rule).toList();
    for (var i = 0; i < evalMatches.length; i++) {
      final m = evalMatches[i];
      final tmpBefore = rule.substring(start, m.start);
      if (i == 0 &&
          (mode != RuleMode.js && mode != RuleMode.regex) &&
          (m.start == 0 || !tmpBefore.contains('##'))) {
        mode = RuleMode.regex;
      }
      if (m.start > start) {
        _splitRegex(rule.substring(start, m.start));
      }
      final tmp = m.group(0)!;
      if (tmp.startsWith('@get:')) {
        ruleType.add(_getRuleType);
        ruleParam.add(tmp.substring(6, tmp.length - 1));
      } else if (tmp.startsWith('{{')) {
        ruleType.add(_jsRuleType);
        ruleParam.add(tmp.substring(2, tmp.length - 2));
      } else {
        _splitRegex(tmp);
      }
      start = m.end;
    }
    if (rule.length > start) {
      _splitRegex(rule.substring(start));
    }
  }

  /// 分离 `@put:{json}` 并收集到 putMap，与官方 `AnalyzeRule.splitPutRule` 一致。
  String _splitPutRule(String ruleStr, Map<String, String> putMap) {
    var r = ruleStr;
    for (final m in kPutPattern.allMatches(r).toList()) {
      r = r.replaceRange(m.start, m.end, '');
      final jsonText = m.group(1)!;
      try {
        putMap.addAll(_parseJsonMap(jsonText));
      } catch (_) {
        final loose = _parseLooseJsonMap(jsonText);
        putMap.addAll(loose);
      }
    }
    return r.trim();
  }

  /// 拆 `$1` 反向引用，官方 `splitRegex`。
  void _splitRegex(String ruleStr) {
    var start = 0;
    final matches = kBackrefPattern.allMatches(ruleStr).toList();
    for (var i = 0; i < matches.length; i++) {
      final m = matches[i];
      if (i == 0 && mode != RuleMode.js && mode != RuleMode.regex) {
        mode = RuleMode.regex;
      }
      if (m.start > start) {
        ruleType.add(_defaultRuleType);
        ruleParam.add(ruleStr.substring(start, m.start));
      }
      ruleType.add(int.tryParse(m.group(0)!.substring(1)) ?? 0);
      ruleParam.add(m.group(0)!);
      start = m.end;
    }
    if (ruleStr.length > start) {
      ruleType.add(_defaultRuleType);
      ruleParam.add(ruleStr.substring(start));
    }
  }

  /// 展开参数并拆分正则替换，对应官方 `makeUpRule`。
  ///
  /// [result] 为当前解析结果（用于 `$N` 引用 List 元素）。
  /// [resolveVar] 用于 `{{}}` / `@get:` 取变量（未注入 JS 引擎时走 Dart 变量表）。
  /// [evalJs] 可选 JS 求值器。
  /// 返回展开后的规则体。
  String makeUpRule(
    Object? result, {
    required String Function(String key) resolveVar,
    String? Function(String js)? evalJs,
  }) {
    if (ruleParam.isNotEmpty) {
      final parts = <String>[];
      var index = ruleParam.length;
      while (index-- > 0) {
        final regType = ruleType[index];
        if (regType > _defaultRuleType) {
          // $N 引用前一步产物 List 的元素
          final list = result is List ? result : null;
          final item = (list != null && list.length > regType) ? list[regType] : null;
          parts.insert(0, item?.toString() ?? ruleParam[index]);
        } else if (regType == _jsRuleType) {
          final jsBody = ruleParam[index];
          final v = _isRule(jsBody) ? resolveVar(jsBody) : (evalJs?.call(jsBody) ?? '');
          parts.insert(0, v);
        } else if (regType == _getRuleType) {
          parts.insert(0, resolveVar(ruleParam[index]));
        } else {
          parts.insert(0, ruleParam[index]);
        }
      }
      rule = parts.join();
    }

    // 分离正则替换 `##`
    final segs = rule.split('##');
    rule = segs[0].trim();
    if (segs.length > 1) replaceRegex = segs[1];
    if (segs.length > 2) replacement = segs[2];
    if (segs.length > 3) replaceFirst = true;
    return rule;
  }
}

// ---------------------------------------------------------------------------
// JSON 解析辅助（避免在实体层强制依赖 json 格式，宽松兜底）
// ---------------------------------------------------------------------------

Map<String, String> _parseJsonMap(String s) {
  final out = <String, String>{};
  final re = RegExp(r'"([^"]+)"\s*:\s*"((?:[^"\\]|\\.)*)"');
  for (final m in re.allMatches(s)) {
    out[m.group(1)!] = m.group(2)!.replaceAll(r'\"', '"');
  }
  return out;
}

Map<String, String> _parseLooseJsonMap(String s) {
  final out = <String, String>{};
  final re = RegExp(r'([\w.\-]+)\s*[:=]\s*([^,;}\]]+)');
  for (final m in re.allMatches(s)) {
    out[m.group(1)!.trim()] = m.group(2)!.trim();
  }
  return out;
}

/// 节点或字符串的抽象，用于规则求值。
sealed class RuleValue {
  const RuleValue();
}

/// DOM 节点（对应官方 jsoup Element）
class RuleElementValue extends RuleValue {
  const RuleElementValue(this.element);
  final dom.Element element;
}

/// 原始字符串值
class RuleTextValue extends RuleValue {
  const RuleTextValue(this.text);
  final String text;
}

/// JSON 值（Map/List/标量）
class RuleJsonValue extends RuleValue {
  const RuleJsonValue(this.value);
  final Object? value;
}