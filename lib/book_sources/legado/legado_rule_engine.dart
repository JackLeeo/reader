// 文件说明：Legado 规则引擎，支持 CSS/JSONPath/XPath/JS/正则全类型规则
// 求值。异步 API：JS 段与 {{}} 模板经由 QuickJS 桥求值。
// 技术要点：HTML DOM、JSONPath、XPath、QuickJS。

import 'dart:convert';

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

import '../protocol/book_source_protocol.dart';
import 'legado_js_engine.dart';
import 'legado_jsonpath.dart';
import 'legado_variable_store.dart';
import 'legado_xpath.dart';

class LegadoRuleDocument {
  LegadoRuleDocument._({required this.value, required this.baseUri});

  factory LegadoRuleDocument.parse(String body, Uri baseUri) {
    final trimmed = body.trimLeft();
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      try {
        return LegadoRuleDocument._(value: jsonDecode(body), baseUri: baseUri);
      } on FormatException {
        // Some HTML pages begin with text resembling JSON. Parse them as HTML.
      }
    }
    return LegadoRuleDocument._(
      value: html_parser.parse(body),
      baseUri: baseUri,
    );
  }

  final Object? value;
  final Uri baseUri;
}

class LegadoRuleEngine {
  const LegadoRuleEngine();

  static final LegadoJsonPath _jsonPathEvaluator = const LegadoJsonPath();
  static final LegadoXPath _xpathEvaluator = const LegadoXPath();

  /// 兼容保留：JS/XPath/JSONPath 已由引擎原生支持，不再静态拦截。
  static void ensureSupported(String rule, {required String field}) {}

  Future<List<Object?>> evaluateList(
    LegadoRuleDocument document,
    Object? context,
    String rule, {
    Map<String, Object?> jsVariables = const {},
    String sourceUrl = '',
  }) async {
    final transformed = _splitTransform(rule);
    if (transformed.selector.trimLeft().startsWith(':')) {
      return _evaluateRegexList(document, context, transformed.selector);
    }
    final values = await _evaluateAlternatives(
      document,
      context,
      transformed.selector,
      listMode: true,
      jsVariables: jsVariables,
      sourceUrl: sourceUrl,
    );
    return values.where((value) => value != null).toList(growable: false);
  }

  List<Object?> _evaluateRegexList(
    LegadoRuleDocument document,
    Object? context,
    String selector,
  ) {
    final stages = selector.trimLeft().substring(1).split('&&');
    var inputs = <String>[_rawString(context ?? document.value)];
    List<_RegexRuleContext> matches = const [];
    try {
      for (final stage in stages) {
        final pattern = RegExp(stage, multiLine: true, dotAll: true);
        matches = [
          for (final input in inputs)
            for (final match in pattern.allMatches(input))
              _RegexRuleContext(match),
        ];
        inputs = matches.map((match) => match.fullMatch).toList();
        if (inputs.isEmpty) break;
      }
    } on FormatException {
      throw const BookSourceProtocolException(
        'Legado list rule contains an invalid regular expression.',
      );
    }
    return matches;
  }

  Future<String> evaluateString(
    LegadoRuleDocument document,
    Object? context,
    String rule, {
    bool resolveUrl = false,
    Map<String, Object?> jsVariables = const {},
    String sourceUrl = '',
  }) async {
    final transformed = _splitTransform(rule);
    final selected = transformed.selector.trim().isEmpty
        ? _rawValues(document, context)
        : await _evaluateAlternatives(
            document,
            context,
            transformed.selector,
            listMode: false,
            jsVariables: jsVariables,
            sourceUrl: sourceUrl,
          );
    final values = selected
        .map(_stringValue)
        .where((value) => value.isNotEmpty)
        .toList();
    var result = values.join();
    if (transformed.pattern != null) {
      try {
        final pattern = RegExp(
          transformed.pattern!,
          multiLine: true,
          dotAll: true,
        );
        result =
            transformed.selector.trim().isEmpty &&
                transformed.replacement.isNotEmpty
            ? _extractRegex(result, pattern, transformed.replacement)
            : _replaceRegex(result, pattern, transformed.replacement);
      } on FormatException {
        throw const BookSourceProtocolException(
          'Legado rule contains an invalid regular expression.',
        );
      }
    }
    result = result.trim();
    if (resolveUrl && result.isNotEmpty) {
      final uri = document.baseUri.resolve(result);
      if (uri.scheme != 'http' && uri.scheme != 'https') {
        throw const BookSourceProtocolException(
          'Legado rule produced a non-HTTP URL.',
        );
      }
      return uri.toString();
    }
    return result;
  }

  String applyReplaceRule(String input, String rule) {
    if (rule.trim().isEmpty) return input;
    final transformed = _splitTransform(
      rule.trim().startsWith('##') ? rule : '##$rule',
    );
    if (transformed.pattern == null) return input;
    try {
      return _replaceRegex(
        input,
        RegExp(transformed.pattern!, multiLine: true, dotAll: true),
        transformed.replacement,
      );
    } on FormatException {
      throw const BookSourceProtocolException(
        'Legado replacement contains an invalid regular expression.',
      );
    }
  }

  Future<List<Object?>> _evaluateAlternatives(
    LegadoRuleDocument document,
    Object? context,
    String selector, {
    required bool listMode,
    Map<String, Object?> jsVariables = const {},
    String sourceUrl = '',
  }) async {
    for (final fallback in selector.split('||')) {
      final concatenated = <Object?>[];
      for (final part in fallback.split('&&')) {
        // `%%` 交替合并（Legado OPERATOR_MERGE）：多段结果的元素
        // 交叉拼接，常用于"标题列表 %% 链接列表"这类平行列表源。
        if (part.contains('%%')) {
          final segments = <List<Object?>>[];
          for (final segment in part.split('%%')) {
            segments.add(
              await _evaluateSingle(
                document,
                context,
                segment.trim(),
                listMode: listMode,
                jsVariables: jsVariables,
                sourceUrl: sourceUrl,
              ),
            );
          }
          concatenated.addAll(_interleave(segments));
          continue;
        }
        concatenated.addAll(
          await _evaluateSingle(
            document,
            context,
            part.trim(),
            listMode: listMode,
            jsVariables: jsVariables,
            sourceUrl: sourceUrl,
          ),
        );
      }
      if (concatenated.any((value) => _stringValue(value).isNotEmpty)) {
        if (listMode && concatenated.isNotEmpty) return concatenated;
        return concatenated;
      }
    }
    return const [];
  }

  /// 交叉合并多段结果：各段元素轮流取值，段耗尽即跳过。
  static List<Object?> _interleave(List<List<Object?>> segments) {
    final merged = <Object?>[];
    var index = 0;
    var remaining = segments.any((segment) => segment.length > index);
    while (remaining) {
      for (final segment in segments) {
        if (index < segment.length) merged.add(segment[index]);
      }
      index++;
      remaining = segments.any((segment) => segment.length > index);
    }
    return merged;
  }

  Future<List<Object?>> _evaluateSingle(
    LegadoRuleDocument document,
    Object? context,
    String rule, {
    required bool listMode,
    Map<String, Object?> jsVariables = const {},
    String sourceUrl = '',
  }) async {
    var normalized = rule.trim();
    if (normalized.startsWith('+')) {
      normalized = normalized.substring(1).trimLeft();
    }
    if (normalized.toLowerCase().startsWith('@css:')) {
      normalized = normalized.substring(5).trimLeft();
    }
    if (normalized.toLowerCase().startsWith('@xpath:')) {
      normalized = normalized.substring(7).trimLeft();
    }
    if (normalized.isEmpty) return const [];
    final root = context ?? document.value;

    // 变量池语法：整条规则为 @get:{name} 直接取值。
    if (sourceUrl.isNotEmpty && normalized.startsWith('@get:')) {
      return [
        LegadoVariableStore.instance.get(
              sourceUrl,
              _getVariableName(normalized),
            ) ??
            '',
      ];
    }

    // XPath 规则（// 开头）。
    if (normalized.startsWith('//')) {
      return _evaluateXPath(root, normalized);
    }
    // 整条规则为 JS（@js: 前缀或 <js> 块）。
    if (normalized.toLowerCase().startsWith('@js:') ||
        normalized.startsWith('<js>')) {
      return [
        await _evaluateJsRule(
          normalized,
          document,
          root,
          jsVariables,
          sourceUrl: sourceUrl,
        ),
      ];
    }

    if (root is _RegexRuleContext) {
      return [root.expand(normalized)];
    }
    if (normalized.contains('{{')) {
      return [
        await _interpolate(
          normalized,
          root,
          document,
          jsVariables,
          sourceUrl: sourceUrl,
        ),
      ];
    }
    if ((normalized.startsWith('"') && normalized.endsWith('"')) ||
        (normalized.startsWith("'") && normalized.endsWith("'"))) {
      return [normalized.substring(1, normalized.length - 1)];
    }
    final normalizedRule = normalized.toLowerCase().startsWith('@json:')
        ? normalized.substring(6)
        : normalized;
    if (root is Map || root is List || normalizedRule.startsWith(r'$')) {
      return _jsonPathEvaluator.evaluate(root, normalizedRule);
    }
    final nodes = <Element>[];
    if (root is Document) {
      nodes.add(root.documentElement!);
    } else if (root is Element) {
      nodes.add(root);
    } else {
      return [root];
    }
    return _htmlRule(
      nodes,
      normalized,
      listMode: listMode,
      document: document,
      jsVariables: jsVariables,
      sourceUrl: sourceUrl,
    );
  }

  /// 从 `@get:{name}` 文本中提取变量名；格式非法时返回空串。
  static String _getVariableName(String rule) {
    final match = RegExp(r'@get:\{([^{}]+)\}').firstMatch(rule);
    return match?.group(1)?.trim() ?? '';
  }

  List<Object?> _evaluateXPath(Object? root, String expression) {
    final roots = <Element>[];
    if (root is Document) {
      final element = root.documentElement;
      if (element != null) roots.add(element);
    } else if (root is Element) {
      roots.add(root);
    } else if (root is List) {
      roots.addAll(root.whereType<Element>());
    }
    return _xpathEvaluator.evaluate(roots, expression);
  }

  Future<String> _evaluateJsRule(
    String rule,
    LegadoRuleDocument document,
    Object? root,
    Map<String, Object?> jsVariables, {
    String sourceUrl = '',
  }) async {
    var code = rule;
    if (code.toLowerCase().startsWith('@js:')) {
      code = code.substring(4);
    } else {
      final block = RegExp(r'^<js>([\s\S]*?)</js>').firstMatch(code);
      if (block != null) {
        code = block.group(1)!;
      }
    }
    final engine = LegadoJsEngine.instance;
    if (engine == null) {
      throw const BookSourceProtocolException(
        'This source needs scripting, but the JS engine is unavailable.',
      );
    }
    final prelude = jsVariables['prelude'];
    try {
      return await engine.evaluateScript(
        code,
        {..._baseJsVariables(document, root), ...jsVariables},
        prelude: prelude is String ? prelude : '',
        sourceUrl: sourceUrl,
      );
    } on LegadoJsException catch (error) {
      throw BookSourceProtocolException(error.message);
    }
  }

  Map<String, Object?> _baseJsVariables(
    LegadoRuleDocument document,
    Object? root,
  ) {
    return {
      'result': _rawString(root ?? document.value),
      'src': _rawString(root ?? document.value),
      'baseUrl': document.baseUri.toString(),
      'host': document.baseUri.host,
      'title': '',
    };
  }

  Future<List<Object?>> _htmlRule(
    List<Element> roots,
    String rule, {
    required bool listMode,
    required LegadoRuleDocument document,
    Map<String, Object?> jsVariables = const {},
    String sourceUrl = '',
  }) async {
    final segments = rule.split('@').where((part) => part.isNotEmpty).toList();
    if (segments.isEmpty) return roots;
    var current = roots;
    for (var index = 0; index < segments.length; index++) {
      var segment = segments[index].trim();
      // 变量存段：put:{name:subrule} —— 先求 subrule 存入变量池，
      // 该段不产出内容（Legado 语义：put 的值通过 @get:{name} 使用）。
      if (sourceUrl.isNotEmpty && segment.startsWith('put:{')) {
        final putMatch = RegExp(
          r'^put:\{([^{}:]+):([\s\S]*)\}$',
        ).firstMatch(segment);
        if (putMatch != null) {
          final name = putMatch.group(1)!.trim();
          final subRule = putMatch.group(2)!.trim();
          final stored = await _evaluateSingle(
            document,
            current.length == 1 ? current.first : current.join(),
            subRule,
            listMode: false,
            jsVariables: jsVariables,
            sourceUrl: sourceUrl,
          );
          final value = stored
              .map(_stringValue)
              .where((v) => v.isNotEmpty)
              .join();
          if (value.isNotEmpty) {
            LegadoVariableStore.instance.put(sourceUrl, name, value);
          }
          continue;
        }
      }
      // js:/<js> 段：把前面段的累积文本作为 result 交给脚本。
      if (segment.toLowerCase().startsWith('js:') ||
          segment.startsWith('<js>')) {
        final resultText = current.map(_stringValue).join();
        return [
          await _evaluateJsRule(
            segment,
            document,
            resultText,
            jsVariables,
            sourceUrl: sourceUrl,
          ),
        ];
      }
      final terminal = _terminalValue(current, segment);
      if (terminal != null && index == segments.length - 1) return terminal;
      current = _select(current, segment, includeRoots: index == 0);
      if (current.isEmpty) return const [];
    }
    return listMode ? current : current.map((node) => node.text).toList();
  }

  List<Object?>? _terminalValue(List<Element> nodes, String segment) {
    return switch (segment) {
      'text' => nodes.map((node) => node.text).toList(),
      'ownText' || 'textNodes' => nodes.map(_ownText).toList(),
      'html' => nodes.map((node) => node.innerHtml).toList(),
      _
          when _htmlAttributeNames.contains(segment.toLowerCase()) ||
              nodes.any((node) => node.attributes.containsKey(segment)) =>
        nodes.map((node) => node.attributes[segment] ?? '').toList(),
      _ => null,
    };
  }

  List<Element> _select(
    List<Element> roots,
    String raw, {
    required bool includeRoots,
  }) {
    final parsed = _legacySelector(raw);
    final selected = <Element>[];
    for (final root in roots) {
      if (parsed.text != null) {
        final candidates = <Element>[root, ...root.querySelectorAll('*')];
        final exact = candidates
            .where((element) => element.text.trim() == parsed.text)
            .toList();
        selected.addAll(
          exact.isNotEmpty
              ? exact
              : candidates.where(
                  (element) => element.text.contains(parsed.text!),
                ),
        );
      } else {
        // html 包的 querySelectorAll 不支持属性选择器，而 og:novel meta
        // 提取（[property=og:novel:author]@content）是详情页规则的标配
        // 写法。这里把 [..] 段拆出来，剩余 CSS 交给 html 包，属性谓词
        // 在 Dart 端过滤。
        final clause = _splitAttrSelectors(parsed.css);
        final baseCss = clause.base.isEmpty ? '*' : clause.base;
        try {
          if (includeRoots && _matches(root, baseCss, clause.attrs)) {
            selected.add(root);
          }
          selected.addAll(
            root
                .querySelectorAll(baseCss)
                .where((element) => _matchAttrs(element, clause.attrs)),
          );
        } on FormatException {
          throw BookSourceProtocolException(
            'Unsupported Legado CSS selector: ${parsed.css}.',
          );
        }
      }
    }
    final deduped = selected.toSet().toList();
    if (parsed.exclude != null) {
      final excluded = _normalizedIndex(parsed.exclude!, deduped.length);
      if (excluded >= 0 && excluded < deduped.length) {
        deduped.removeAt(excluded);
      }
    }
    if (parsed.indexes == null) return deduped;
    return parsed.indexes!
        .map((value) => _normalizedIndex(value, deduped.length))
        .where((value) => value >= 0 && value < deduped.length)
        .map((value) => deduped[value])
        .toList();
  }

  _LegacySelector _legacySelector(String input) {
    var selector = input.trim();
    int? exclude;
    final exclusion = RegExp(r'!(-?\d+)$').firstMatch(selector);
    if (exclusion != null) {
      exclude = int.parse(exclusion.group(1)!);
      selector = selector.substring(0, exclusion.start);
    }
    List<int>? indexes;
    final indexMatch = RegExp(r'\.(-?\d+(?::-?\d+)*)$').firstMatch(selector);
    if (indexMatch != null) {
      indexes = indexMatch.group(1)!.split(':').map(int.parse).toList();
      selector = selector.substring(0, indexMatch.start);
    }
    String? text;
    if (selector.startsWith('class.')) {
      selector = '.${selector.substring(6)}';
    } else if (selector.startsWith('id.')) {
      selector = '#${selector.substring(3)}';
    } else if (selector.startsWith('tag.')) {
      selector = selector.substring(4);
    } else if (selector.startsWith('text.')) {
      text = selector.substring(5);
      selector = '*';
    }
    if (selector.isEmpty) selector = '*';
    return _LegacySelector(
      css: selector,
      indexes: indexes,
      exclude: exclude,
      text: text,
    );
  }

  Future<String> _interpolate(
    String template,
    Object? context,
    LegadoRuleDocument doc,
    Map<String, Object?> jsVariables, {
    String sourceUrl = '',
  }) async {
    final matches = RegExp(r'\{\{\s*([^{}]+?)\s*\}\}').allMatches(template);
    var result = template;
    for (final match in matches) {
      final expression = match.group(1)!.trim();
      String replacement = '';
      if ((expression.startsWith('"') && expression.endsWith('"')) ||
          (expression.startsWith("'") && expression.endsWith("'"))) {
        replacement = expression.substring(1, expression.length - 1);
      } else if (_isPlainPathExpression(expression)) {
        // 纯路径（book.title / $.data.list / key）优先 JSONPath。
        replacement = _jsonPathEvaluator
            .evaluate(context, expression)
            .map(_stringValue)
            .join();
        if (replacement.isEmpty) {
          replacement = await _tryJsExpression(
            expression,
            doc,
            context,
            jsVariables,
            sourceUrl: sourceUrl,
          );
        }
      } else {
        // 含函数调用/运算/桥 API 的表达式走 JS。
        replacement = await _tryJsExpression(
          expression,
          doc,
          context,
          jsVariables,
          sourceUrl: sourceUrl,
        );
        if (replacement.isEmpty) {
          replacement = _jsonPathEvaluator
              .evaluate(context, expression)
              .map(_stringValue)
              .join();
        }
      }
      result = result.replaceAll(match.group(0)!, replacement);
    }
    return result;
  }

  /// 形如 `book.title`、`$.data.list`、`key`、`page` 的纯成员访问。
  static final _plainPath = RegExp(
    r'''^[A-Za-z_$][\w$]*(\[['"\w$]+'\])?([.][A-Za-z_$][\w$]*)*$''',
  );

  bool _isPlainPathExpression(String expression) =>
      _plainPath.hasMatch(expression);

  Future<String> _tryJsExpression(
    String expression,
    LegadoRuleDocument doc,
    Object? context,
    Map<String, Object?> jsVariables, {
    String sourceUrl = '',
  }) async {
    final engine = LegadoJsEngine.instance;
    if (engine == null) return '';
    final prelude = jsVariables['prelude'];
    try {
      return await engine.evaluateExpression(
        expression,
        {..._baseJsVariables(doc, context), ...jsVariables},
        prelude: prelude is String ? prelude : '',
        sourceUrl: sourceUrl,
      );
    } catch (_) {
      return '';
    }
  }

  List<Object?> _rawValues(LegadoRuleDocument document, Object? context) {
    final value = context ?? document.value;
    return switch (value) {
      Document document => [document.outerHtml],
      Element element => [element.outerHtml],
      _ => [value],
    };
  }
}

const _htmlAttributeNames = {
  'href',
  'src',
  'content',
  'value',
  'title',
  'alt',
  'data',
  'action',
};

class _RuleTransform {
  const _RuleTransform({
    required this.selector,
    this.pattern,
    this.replacement = '',
  });

  final String selector;
  final String? pattern;
  final String replacement;
}

_RuleTransform _splitTransform(String rule) {
  final parts = rule.split('##');
  if (parts.length == 1) return _RuleTransform(selector: rule);
  return _RuleTransform(
    selector: parts.first,
    pattern: parts.length > 1 ? parts[1] : null,
    replacement: parts.length > 2
        ? parts[2].replaceFirst(RegExp(r'###$'), '')
        : '',
  );
}

class _LegacySelector {
  const _LegacySelector({
    required this.css,
    this.indexes,
    this.exclude,
    this.text,
  });

  final String css;
  final List<int>? indexes;
  final int? exclude;
  final String? text;
}

/// 从 CSS 里拆出的属性谓词：`[name]`、`[name=value]`、`[name~=value]`。
class _AttrPredicate {
  const _AttrPredicate({
    required this.name,
    this.value,
    this.wordMatch = false,
  });

  final String name;
  final String? value;
  final bool wordMatch;
}

class _AttrClause {
  const _AttrClause({required this.base, required this.attrs});

  final String base;
  final List<_AttrPredicate> attrs;
}

/// 把选择器拆成「html 包可解析的基础 CSS」+「属性谓词列表」。
///
/// 支持值中含 `:`、`|` 等字符（如 `[property=og:novel:author]`、
/// `[property~=category|status|update_time]`）与单/双引号包裹的值。
_AttrClause _splitAttrSelectors(String css) {
  final buffer = StringBuffer();
  final predicates = <_AttrPredicate>[];
  for (var i = 0; i < css.length; i++) {
    final char = css[i];
    if (char != '[') {
      buffer.write(char);
      continue;
    }
    final close = css.indexOf(']', i);
    if (close < 0) {
      // 未闭合的 [ 交回 html 包（大概率也解析失败，走可诊断错误）。
      buffer.write(css.substring(i));
      break;
    }
    final body = css.substring(i + 1, close);
    i = close;
    final tilde = body.indexOf('~=');
    final eq = body.indexOf('=');
    if (tilde >= 0 && (eq < 0 || tilde == eq - 1)) {
      predicates.add(
        _AttrPredicate(
          name: _trimQuotes(body.substring(0, tilde).trim()),
          value: _trimQuotes(body.substring(tilde + 2).trim()),
          wordMatch: true,
        ),
      );
    } else if (eq >= 0) {
      predicates.add(
        _AttrPredicate(
          name: _trimQuotes(body.substring(0, eq).trim()),
          value: _trimQuotes(body.substring(eq + 1).trim()),
        ),
      );
    } else {
      predicates.add(_AttrPredicate(name: _trimQuotes(body.trim())));
    }
  }
  return _AttrClause(base: buffer.toString().trim(), attrs: predicates);
}

String _trimQuotes(String value) {
  if (value.length >= 2 &&
      ((value.startsWith('"') && value.endsWith('"')) ||
          (value.startsWith("'") && value.endsWith("'")))) {
    return value.substring(1, value.length - 1);
  }
  return value;
}

bool _matchAttrs(Element element, List<_AttrPredicate> attrs) {
  for (final predicate in attrs) {
    final raw = element.attributes[predicate.name];
    if (raw == null) return false;
    final value = predicate.value;
    if (value == null) continue;
    if (predicate.wordMatch) {
      if (!raw.split(RegExp(r'\s+')).contains(value)) return false;
    } else if (raw.trim() != value) {
      return false;
    }
  }
  return true;
}

int _normalizedIndex(int index, int length) =>
    index < 0 ? length + index : index;

String _ownText(Element element) =>
    element.nodes.whereType<Text>().map((node) => node.data).join().trim();

bool _matches(Element element, String baseCss, List<_AttrPredicate> attrs) {
  final parent = element.parent;
  if (parent != null) {
    return parent
        .querySelectorAll(baseCss)
        .where((candidate) => _matchAttrs(candidate, attrs))
        .contains(element);
  }
  if (baseCss != '*' && baseCss != element.localName) return false;
  return _matchAttrs(element, attrs);
}

String _stringValue(Object? value) => switch (value) {
  null => '',
  String text => text,
  num number => '$number',
  bool boolean => '$boolean',
  Element element => element.text,
  _RegexRuleContext match => match.fullMatch,
  _ => '$value',
};

String _rawString(Object? value) => switch (value) {
  Document document => document.outerHtml,
  Element element => element.outerHtml,
  _RegexRuleContext match => match.fullMatch,
  null => '',
  _ => '$value',
};

class _RegexRuleContext {
  _RegexRuleContext(RegExpMatch match)
    : fullMatch = match.group(0) ?? '',
      groups = List.generate(match.groupCount + 1, match.group);

  final String fullMatch;
  final List<String?> groups;

  String expand(String template) {
    return template.replaceAllMapped(RegExp(r'\$(\d+)'), (capture) {
      final index = int.tryParse(capture.group(1)!);
      if (index == null || index >= groups.length) return capture.group(0)!;
      return groups[index] ?? '';
    });
  }
}

String _replaceRegex(String input, RegExp pattern, String replacement) {
  return input.replaceAllMapped(pattern, (match) {
    return replacement.replaceAllMapped(RegExp(r'\$(\d+)'), (capture) {
      final index = int.tryParse(capture.group(1)!);
      if (index == null || index > match.groupCount) return capture.group(0)!;
      return match.group(index) ?? '';
    });
  });
}

String _extractRegex(String input, RegExp pattern, String replacement) {
  final match = pattern.firstMatch(input);
  if (match == null) return '';
  return replacement.replaceAllMapped(RegExp(r'\$(\d+)'), (capture) {
    final index = int.tryParse(capture.group(1)!);
    if (index == null || index > match.groupCount) return capture.group(0)!;
    return match.group(index) ?? '';
  });
}
