// Legado规则引擎 - 解析书源规则
// 支持语法: class.name@tag.attr@index, ##regex##replacement, || (或), && (与)
// 提取: @text, @textNodes, @html, @src, @href, @ownText, @all
// 位置: :first, :last, :nth(n), :skip(n)
// 替换: ##pattern##replacement
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import 'json_selector.dart';

class RuleEngine {
  final Uri baseUri;

  RuleEngine(this.baseUri);

  /// 解析HTML文档
  static dom.Document parseHtml(String body) {
    return html_parser.parse(body);
  }

  /// 解析JSON值（用于JSON书源）
  static Object? parseJson(String body) {
    final trimmed = body.trim();
    if (trimmed.isEmpty) return null;
    return JsonSelector.decode(trimmed);
  }

  /// 列表提取：返回元素列表
  /// rule示例: "class.list@tag.li" 或 "class.grid@tag.tr!0" (!0表示排除第0个)
  List<dom.Element> selectList(dom.Document document, String rule) {
    if (rule.trim().isEmpty) return [];

    final cleaned = _stripReplace(rule);
    final parts = _splitAlternatives(cleaned);
    final results = <dom.Element>[];

    for (final part in parts) {
      final all = <dom.Element>[];
      for (final step in part.split('&&')) {
        final stepTrim = step.trim();
        if (stepTrim.isEmpty) continue;
        final elements = _applyStep(document.body!, stepTrim);
        if (elements.isEmpty) {
          all.clear();
          break;
        }
        all.addAll(elements);
      }
      if (all.isNotEmpty) {
        results.addAll(all);
        break; // 第一个非空替代胜出
      }
    }
    return results;
  }

  /// 在已选择元素集合上应用子规则
  /// 用于解析单本书的多字段
  List<dom.Element> selectSubList(List<dom.Element> elements, String rule) {
    if (rule.trim().isEmpty || elements.isEmpty) return elements;
    final cleaned = _stripReplace(rule);
    final parts = _splitAlternatives(cleaned);
    for (final part in parts) {
      var current = elements;
      var success = true;
      for (final step in part.split('&&')) {
        final stepTrim = step.trim();
        if (stepTrim.isEmpty) continue;
        final next = <dom.Element>[];
        for (final el in current) {
          next.addAll(_applyStep(el, stepTrim));
        }
        if (next.isEmpty) {
          success = false;
          break;
        }
        current = next;
      }
      if (success && current.isNotEmpty) return current;
    }
    return const [];
  }

  /// 单值提取：返回字符串
  /// type: text/textNodes/html/src/href/ownText
  String selectString(
    dynamic document,
    dynamic context, // dom.Element 或 List<dom.Element>
    String rule, {
    bool resolveUrl = false,
  }) {
    if (rule.trim().isEmpty) {
      // 空规则返回原始文本
      if (context is dom.Element) {
        return context.text.trim();
      }
      if (context is List && context.isNotEmpty && context.first is dom.Element) {
        return (context.first as dom.Element).text.trim();
      }
      return '';
    }

    // 拆分规则和替换
    var (rawRule, replace) = _splitReplace(rule);
    rawRule = _splitAlternatives(rawRule).first;
    final parts = rawRule.split('&&');
    var current = <dom.Element>[];
    if (context is dom.Element) {
      current = [context];
    } else if (context is List && context.isNotEmpty) {
      current = context.whereType<dom.Element>().toList();
    } else {
      current = [];
    }

    for (final step in parts) {
      final stepTrim = step.trim();
      if (stepTrim.isEmpty) continue;
      final next = <dom.Element>[];
      for (final el in current) {
        next.addAll(_applyStep(el, stepTrim));
      }
      current = next;
      if (current.isEmpty) break;
    }

    String result = '';
    if (current.isNotEmpty) {
      // 提取类型
      final type = _extractType(rawRule);
      result = _extractValue(current.first, type);
    }

    // 应用替换
    if (replace != null) {
      result = _applyReplace(result, replace);
    }

    if (resolveUrl && result.isNotEmpty) {
      try {
        final resolved = baseUri.resolve(result);
        if (resolved.scheme == 'http' || resolved.scheme == 'https') {
          result = resolved.toString();
        }
      } catch (_) {}
    }
    return result;
  }

  /// 提取元素列表的所有文本（用于章节列表）
  List<String> extractAllText(List<dom.Element> elements) {
    return elements.map((e) => e.text.trim()).toList();
  }

  // ===== 内部实现 =====

  /// 应用单步规则
  /// 支持格式:
  ///   - "class.foo" / ".foo" / "id.foo" / "#foo" - CSS-like
  ///   - "tag.li" - 标签
  ///   - "@text" / "@href" 等 - 提取
  ///   - ":first" / ":last" / ":nth(n)" / ":skip(n)" - 位置
  ///   - "!n" - 排除第n个
  List<dom.Element> _applyStep(dom.Element root, String step) {
    // 处理位置限定
    String position = '';
    var s = step;
    final posMatch = RegExp(r'^(.+?)(:(first|last|nth\(\d+\)|skip\(\d+\)))$')
        .firstMatch(step.trim());
    if (posMatch != null) {
      s = posMatch.group(1)!.trim();
      position = posMatch.group(2)!;
    }

    // 处理提取类型后缀
    if (s.startsWith('@')) {
      // 提取步骤：在root上应用之前的累积
      return [root];
    }

    // 排除索引
    int? skipIndex;
    final exclMatch = RegExp(r'!(\d+)$').firstMatch(s);
    if (exclMatch != null) {
      skipIndex = int.tryParse(exclMatch.group(1)!);
      s = s.substring(0, exclMatch.start);
    }

    // CSS选择
    final selected = _cssSelect(root, s);
    var list = selected.toList();

    if (skipIndex != null && skipIndex < list.length) {
      list.removeAt(skipIndex);
    }

    // 应用位置
    if (position.isNotEmpty) {
      list = _applyPosition(list, position);
    }

    return list;
  }

  /// CSS选择器（简化版实现）
  Iterable<dom.Element> _cssSelect(dom.Element root, String selector) sync* {
    selector = selector.trim();
    if (selector.isEmpty) {
      yield root;
      return;
    }

    // tag选择: "tag.li", "tag.div.0"
    if (selector.startsWith('tag.')) {
      final rest = selector.substring(4);
      final tagName = rest.split(RegExp(r'[.#]')).first;
      final list = root.querySelectorAll(tagName);
      final filtered = _filterByClassOrId(list, rest);
      yield* filtered;
      return;
    }

    // class选择: "class.foo" 或 ".foo"
    if (selector.startsWith('class.')) {
      final rest = selector.substring(6);
      final list = root.querySelectorAll('*[class]');
      yield* _filterByClassOrId(list, rest);
      return;
    }
    if (selector.startsWith('.')) {
      final rest = selector.substring(1);
      final list = root.querySelectorAll('*[class]');
      yield* _filterByClassOrId(list, rest);
      return;
    }

    // id选择
    if (selector.startsWith('id.')) {
      final rest = selector.substring(3);
      final list = root.querySelectorAll('*[id]');
      yield* _filterByClassOrId(list, rest);
      return;
    }
    if (selector.startsWith('#')) {
      final rest = selector.substring(1);
      final list = root.querySelectorAll('*[id]');
      yield* _filterByClassOrId(list, rest);
      return;
    }

    // 直接标签
    final list = root.querySelectorAll(selector);
    yield* list;
  }

  Iterable<dom.Element> _filterByClassOrId(
    List<dom.Element> list,
    String pattern,
  ) sync* {
    // pattern: "foo" / "foo.0" / "foo.bar" / "foo#bar"
    final parts = pattern.split(RegExp(r'[.#]'));
    final className = parts.first;
    int? index;
    if (parts.length > 1) {
      index = int.tryParse(parts[1]);
    }

    final matched = <dom.Element>[];
    for (final el in list) {
      final classes = el.className.split(RegExp(r'\s+'));
      if (classes.contains(className)) {
        matched.add(el);
      }
    }
    if (index != null) {
      if (index < matched.length) {
        yield matched[index];
      }
    } else {
      yield* matched;
    }
  }

  List<dom.Element> _applyPosition(List<dom.Element> list, String position) {
    if (list.isEmpty) return list;
    if (position == ':first') return [list.first];
    if (position == ':last') return [list.last];
    final nthMatch = RegExp(r':nth\((\d+)\)').firstMatch(position);
    if (nthMatch != null) {
      final n = int.parse(nthMatch.group(1)!);
      if (n < list.length) return [list[n]];
      return [];
    }
    final skipMatch = RegExp(r':skip\((\d+)\)').firstMatch(position);
    if (skipMatch != null) {
      final n = int.parse(skipMatch.group(1)!);
      if (n >= list.length) return [];
      return list.sublist(n);
    }
    return list;
  }

  /// 提取值
  String _extractValue(dom.Element element, String? type) {
    if (element is dom.Text) {
      return element.text.trim();
    }
    final el = element;
    switch (type) {
      case '@text':
        return el.text.trim();
      case '@textNodes':
        return el.nodes
            .whereType<dom.Text>()
            .map((t) => t.text)
            .join()
            .trim();
      case '@html':
        return el.innerHtml;
      case '@outerHtml':
        return el.outerHtml;
      case '@src':
        return el.attributes['src'] ?? el.attributes['data-src'] ?? '';
      case '@href':
        return el.attributes['href'] ?? '';
      case '@ownText':
        return el.nodes
            .whereType<dom.Text>()
            .map((t) => t.text)
            .join()
            .trim();
      case '@all':
        return el.text.trim();
      default:
        // 默认是@text
        if (type != null && type.startsWith('@')) {
          // 自定义属性
          final attr = type.substring(1);
          return el.attributes[attr] ?? '';
        }
        return el.text.trim();
    }
  }

  /// 提取类型（取最后一步的@xxx）
  String? _extractType(String rule) {
    final parts = rule.split('&&');
    for (final p in parts.reversed) {
      final t = p.trim();
      if (t.startsWith('@')) {
        return t;
      }
    }
    return null;
  }

  /// 拆分替换
  /// 格式: rule##pattern##replacement 或 rule##pattern
  (String, _ReplaceRule?) _splitReplace(String rule) {
    final idx = rule.indexOf('##');
    if (idx < 0) return (rule, null);
    final main = rule.substring(0, idx);
    final rest = rule.substring(idx + 2);
    // 格式1: pattern##replacement
    // 格式2: pattern（仅删除匹配）
    final sepIdx = rest.indexOf('##');
    if (sepIdx < 0) {
      // 仅pattern
      return (main, _ReplaceRule(pattern: rest, replacement: ''));
    } else {
      final pattern = rest.substring(0, sepIdx);
      final replacement = rest.substring(sepIdx + 2);
      return (main, _ReplaceRule(pattern: pattern, replacement: replacement));
    }
  }

  /// 剥离替换规则（仅保留选择部分）
  String _stripReplace(String rule) {
    final idx = rule.indexOf('##');
    return idx < 0 ? rule : rule.substring(0, idx);
  }

  /// 拆分||（或）
  List<String> _splitAlternatives(String rule) {
    return rule.split('||').map((s) => s.trim()).toList();
  }

  /// 应用替换
  String _applyReplace(String input, _ReplaceRule rule) {
    try {
      final pattern = RegExp(rule.pattern, multiLine: true, dotAll: true);
      return input.replaceAll(pattern, rule.replacement);
    } catch (_) {
      return input;
    }
  }
}

class _ReplaceRule {
  final String pattern;
  final String replacement;
  _ReplaceRule({required this.pattern, required this.replacement});
}
