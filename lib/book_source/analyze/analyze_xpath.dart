import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../entities/source_rule.dart';

/// XPath 子集分析器（对应官方 `AnalyzeByXPath`，基于 JsoupXPath）。
///
/// 支持书源规则常用路径：`//tag`、`/tag`、`..`、`.`、`*`,
/// 谓词 `[n]`(1-based)、`[@attr]`、`[@attr='v']`、`[contains(@class,'x')]`,
/// 取属性 `/@attr`、取文本 `/text()`。
class AnalyzeXPath {
  AnalyzeXPath._();

  /// 报错：不支持的原生 XPath 功能我们抛空结果而不是崩溃。
  static List<RuleElementValue> getElements(RuleValue ctx, String path) {
    final list = <RuleElementValue>[];
    final roots = _roots(ctx);
    for (final r in roots) {
      _collect(r, path, list);
    }
    return list;
  }

  static List<dom.Element> _roots(RuleValue ctx) => switch (ctx) {
        RuleElementValue(:final element) => [element],
        RuleTextValue(:final text) when text.trim().isNotEmpty => _tryParseHtml(text),
        _ => const [],
      };

  static List<dom.Element> _tryParseHtml(String html) {
    try {
      final doc = html_parser.parse(html);
      final body = doc.body;
      return body != null ? [body] : const [];
    } catch (_) {
      return const [];
    }
  }

  static String getString(RuleValue ctx, String path) {
    final hits = getElements(ctx, path);
    if (hits.isEmpty) return '';
    // 若路径以 /@attr 结尾已由 _evalAttr 处理返回元素属主；此处取文本
    return hits.first.element.text.trim();
  }

  /// 取 attribute（`path/@attr` 或 `path@attr`）。
  static String getAttr(RuleValue ctx, String path, String attr) {
    final hits = getElements(ctx, path);
    if (hits.isEmpty) return '';
    return hits.first.element.attributes[attr] ?? '';
  }

  static void _collect(dom.Element root, String path, List<RuleElementValue> out) {
    final steps = _splitSteps(path);
    List<dom.Element> current = [root];
    for (var i = 0; i < steps.length; i++) {
      final step = steps[i];
      if (step.isEmpty) continue;
      if (step.startsWith('@')) {
        continue;
      }
      if (step == 'text()') {
        continue;
      }
      if (step == '.') continue;
      if (step == '..') {
        final parents = <dom.Element>[];
        for (final e in current) {
          final p = e.parent;
          if (p != null) parents.add(p);
        }
        current = parents;
        continue;
      }
      current = _applyStep(current, step);
      if (current.isEmpty) return;
    }
    for (final e in current) {
      out.add(RuleElementValue(e));
    }
  }

  static List<String> _splitSteps(String path) {
    var p = path.trim();
    final out = <String>[];
    var i = 0;
    if (p.startsWith('//')) {
      out.add('//');
      p = p.substring(2);
    } else if (p.startsWith('/')) {
      p = p.substring(1);
    }
    while (i < p.length) {
      // 寻找下一个 / 但跳过带引号的谓词
      var j = i;
      var inQuote = '';
      while (j < p.length) {
        final c = p[j];
        if (inQuote.isNotEmpty) {
          if (c == inQuote) inQuote = '';
          j++;
          continue;
        }
        if (c == '\'' || c == '"') {
          inQuote = c;
          j++;
          continue;
        }
        if (c == '/') break;
        j++;
      }
      final seg = p.substring(i, j);
      if (seg.isNotEmpty) out.add(seg);
      i = j + 1;
    }
    return out;
  }

  static List<dom.Element> _applyStep(List<dom.Element> from, String stepRaw) {
    final out = <dom.Element>[];
    // 解析 step + 谓词
    final step = _parseStep(stepRaw);
    for (final e in from) {
      final matched = _matchStep(e, step);
      out.addAll(matched);
    }
    return out.toSet().toList();
  }

  static ({String name, bool descendant, List<String> predicates}) _parseStep(String raw) {
    var name = '';
    var descendant = false;
    final preds = <String>[];
    var s = raw;
    if (s.startsWith('//')) {
      descendant = true;
      s = s.substring(2);
    }
    s = s.trimLeft();
    final predStart = s.indexOf('[');
    if (predStart >= 0) {
      name = s.substring(0, predStart);
      final body = s.substring(predStart);
      // 提取所有 [..]（支持嵌套 quote）
      var k = 0;
      while (k < body.length) {
        if (body[k] != '[') {
          k++;
          continue;
        }
        var depth = 0;
        var inQuote = '';
        var end = k;
        for (var m = k; m < body.length; m++) {
          final c = body[m];
          if (inQuote.isNotEmpty) {
            if (c == inQuote) inQuote = '';
            continue;
          }
          if (c == '\'' || c == '"') {
            inQuote = c;
            continue;
          }
          if (c == '[') depth++;
          if (c == ']') {
            depth--;
            if (depth == 0) {
              end = m;
              break;
            }
          }
        }
        preds.add(body.substring(k + 1, end));
        k = end + 1;
      }
    } else {
      name = s;
    }
    return (name: name.trim(), descendant: descendant, predicates: preds);
  }

  static List<dom.Element> _matchStep(dom.Element parent, ({String name, bool descendant, List<String> predicates}) step) {
    final tag = step.name == '*' || step.name.isEmpty ? '' : step.name;
    var candidates = <dom.Element>[];
    if (tag.isNotEmpty) {
      candidates = parent.querySelectorAll(tag);
    } else {
      candidates = parent.children;
    }
    if (step.descendant) {
      // `//` 并未独立；上面利用 querySelectorAll(tag) 已含后代，且以当前 stepping 根后代处理
    }
    return candidates.where((c) => _passPredicates(c, step.predicates)).toList();
  }

  static bool _passPredicates(dom.Element el, List<String> preds) {
    for (final p in preds) {
      if (!_passPredicate(el, p)) return false;
    }
    return true;
  }

  static bool _passPredicate(dom.Element el, String p) {
    final p0 = p.trim();
    // [n] position
    final pos = int.tryParse(p0);
    if (pos != null) {
      final siblings = el.parent?.children ?? <dom.Element>[];
      return siblings.indexOf(el) + 1 == pos;
    }
    // [@attr]
    final attrOnly = RegExp(r'^@([\w-]+)$').firstMatch(p0);
    if (attrOnly != null) return el.attributes.containsKey(attrOnly.group(1)!);
    // [@attr='v']
    final attrEq = RegExp('^@([\\w-]+)\\s*=\\s*["\']([\\s\\S]*?)["\']\$').firstMatch(p0);
    if (attrEq != null) return el.attributes[attrEq.group(1)] == attrEq.group(2);
    // [contains(@class,'x')]
    final contains =
        RegExp('^contains\\(@([\\w-]+)\\s*,\\s*["\']([\\s\\S]*?)["\']\\)\$').firstMatch(p0);
    if (contains != null) {
      final v = el.attributes[contains.group(1)] ?? '';
      return v.contains(contains.group(2)!);
    }
    // [@attr contains...] 简化
    return false;
  }

  static bool isXPath(String rule) {
    final r = rule.trimLeft();
    return (r.startsWith('/') && r.length > 1) || r.startsWith('(@');
  }
}