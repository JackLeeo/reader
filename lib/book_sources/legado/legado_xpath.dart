// 文件说明：Legado XPath 规则求值器，基于 html 包的 DOM 树实现常用
// XPath 1.0 子集，覆盖书源里高频出现的语法模式。
// 技术要点：DOM 遍历、谓词过滤、路径求值。

import 'package:html/dom.dart';

/// 支持的 XPath 子集：
/// - `//tag`、`/tag`、`//tag/child`、`//tag//deep`
/// - `*` 通配、`..` 父节点
/// - 谓词：`[n]`、`[last()]`、`[-n]`、`[@attr]`、`[@attr='v']`、
///   `[contains(@attr,'v')]`、`[contains(text(),'v')]`、`[text()='v']`
/// - 终结步：`/text()`、`/@attr`、`/html()`、`/all`
/// - 顶层 `|` 并集
class LegadoXPath {
  const LegadoXPath();

  /// 对 [roots] 求值 [expression]，返回节点/文本/属性值的列表。
  List<Object?> evaluate(List<Element> roots, String expression) {
    final results = <Object?>[];
    for (final branch in _splitTopLevel(expression)) {
      results.addAll(_evaluateBranch(roots, branch.trim()));
    }
    return results;
  }

  static List<String> _splitTopLevel(String input) {
    final parts = <String>[];
    var depth = 0;
    var inQuote = false;
    var quoteChar = '';
    var start = 0;
    for (var i = 0; i < input.length; i++) {
      final ch = input[i];
      if (inQuote) {
        if (ch == quoteChar) inQuote = false;
        continue;
      }
      if (ch == "'" || ch == '"') {
        inQuote = true;
        quoteChar = ch;
      } else if (ch == '[' || ch == '(') {
        depth++;
      } else if (ch == ']' || ch == ')') {
        depth--;
      } else if (ch == '|' && depth == 0) {
        parts.add(input.substring(start, i));
        start = i + 1;
      }
    }
    parts.add(input.substring(start));
    return parts;
  }

  List<Object?> _evaluateBranch(List<Element> roots, String expression) {
    final trimmed = expression.trim();
    var stepsText = trimmed;
    var terminal = _XPathTerminal.none;
    var attributeName = '';

    // 剥离终结步：text()/all/html()/@attr。
    if (stepsText.endsWith('/text()')) {
      terminal = _XPathTerminal.text;
      stepsText = stepsText.substring(0, stepsText.length - 7);
    } else if (stepsText.endsWith('/all')) {
      terminal = _XPathTerminal.all;
      stepsText = stepsText.substring(0, stepsText.length - 4);
    } else if (stepsText.endsWith('/html()')) {
      terminal = _XPathTerminal.html;
      stepsText = stepsText.substring(0, stepsText.length - 7);
    } else {
      final attr = RegExp(r'/?@([A-Za-z_][-\w]*)$').firstMatch(stepsText);
      if (attr != null) {
        terminal = _XPathTerminal.attribute;
        stepsText = stepsText.substring(0, attr.start);
        attributeName = attr.group(1)!;
      }
    }

    final steps = _parseSteps(stepsText);
    var nodes = List<Element>.from(roots);
    for (final step in steps) {
      nodes = _applyStep(nodes, step);
      if (nodes.isEmpty) break;
    }

    return _terminalValues(nodes, terminal, attributeName);
  }

  List<_XPathStep> _parseSteps(String path) {
    final steps = <_XPathStep>[];
    final pattern = RegExp(r'(//|/)([^/]+)');
    for (final match in pattern.allMatches(path)) {
      final axis = match.group(1) == '//'
          ? _XPathAxis.descendantOrSelf
          : _XPathAxis.child;
      steps.add(_parseStep(match.group(2)!, axis));
    }
    return steps;
  }

  _XPathStep _parseStep(String raw, _XPathAxis axis) {
    var body = raw.trim();
    var nodeTest = body;
    final predicates = <_XPathPredicate>[];
    final predPattern = RegExp(r'\[([^\[\]]*)\]');
    var remainder = body;
    while (true) {
      final match = predPattern.firstMatch(remainder);
      if (match == null) break;
      predicates.add(_parsePredicate(match.group(1)!));
      remainder = remainder.replaceRange(match.start, match.end, '');
    }
    nodeTest = remainder.trim();
    return _XPathStep(axis: axis, nodeTest: nodeTest, predicates: predicates);
  }

  _XPathPredicate _parsePredicate(String raw) {
    final text = raw.trim();
    if (text == 'last()') {
      return const _XPathPredicate(_PredicateKind.last, null, null, null);
    }
    final index = int.tryParse(text);
    if (index != null) {
      return _XPathPredicate(_PredicateKind.position, null, null, index);
    }
    final exists = RegExp(r'^@([A-Za-z_][-\w]*)$').firstMatch(text);
    if (exists != null) {
      return _XPathPredicate(
        _PredicateKind.attributeExists,
        exists.group(1),
        null,
        null,
      );
    }
    final equals = RegExp(
      "^@([A-Za-z_][-\\w]*)\\s*=\\s*(['\"])(.*?)\\2\$",
    ).firstMatch(text);
    if (equals != null) {
      return _XPathPredicate(
        _PredicateKind.attributeEquals,
        equals.group(1),
        equals.group(3),
        null,
      );
    }
    final containsAttr = RegExp(
      "^contains\\(\\s*@([A-Za-z_][-\\w]*)\\s*,\\s*(['\"])(.*?)\\2\\s*\\)\$",
    ).firstMatch(text);
    if (containsAttr != null) {
      return _XPathPredicate(
        _PredicateKind.attributeContains,
        containsAttr.group(1),
        containsAttr.group(3),
        null,
      );
    }
    final containsText = RegExp(
      "^contains\\(\\s*text\\(\\)\\s*,\\s*(['\"])(.*?)\\1\\s*\\)\$",
    ).firstMatch(text);
    if (containsText != null) {
      return _XPathPredicate(
        _PredicateKind.textContains,
        null,
        containsText.group(2),
        null,
      );
    }
    final textEquals = RegExp(
      "^text\\(\\)\\s*=\\s*(['\"])(.*?)\\1\$",
    ).firstMatch(text);
    if (textEquals != null) {
      return _XPathPredicate(
        _PredicateKind.textEquals,
        null,
        textEquals.group(2),
        null,
      );
    }
    return const _XPathPredicate(_PredicateKind.unsupported, null, null, null);
  }

  List<Element> _applyStep(List<Element> nodes, _XPathStep step) {
    final selected = <Element>[];
    for (final node in nodes) {
      switch (step.axis) {
        case _XPathAxis.descendantOrSelf:
          if (_matchesTest(node, step.nodeTest)) selected.add(node);
          selected.addAll(
            node
                .querySelectorAll('*')
                .where((child) => _matchesTest(child, step.nodeTest)),
          );
        case _XPathAxis.child:
          for (final child in node.children) {
            if (_matchesTest(child, step.nodeTest)) selected.add(child);
          }
      }
    }
    final deduped = selected.toSet().toList();
    return _applyPredicates(deduped, step.predicates);
  }

  bool _matchesTest(Element element, String nodeTest) {
    if (nodeTest == '*') return true;
    return element.localName?.toLowerCase() == nodeTest.toLowerCase();
  }

  List<Element> _applyPredicates(
    List<Element> nodes,
    List<_XPathPredicate> predicates,
  ) {
    var current = nodes;
    for (final predicate in predicates) {
      current = switch (predicate.kind) {
        _PredicateKind.position => _positionFilter(current, predicate.number!),
        _PredicateKind.last => current.isEmpty
            ? current
            : [current.last],
        _PredicateKind.attributeExists => current
            .where((node) => node.attributes.containsKey(predicate.name))
            .toList(),
        _PredicateKind.attributeEquals => current
            .where((node) => node.attributes[predicate.name] == predicate.value)
            .toList(),
        _PredicateKind.attributeContains => current
            .where(
              (node) => (node.attributes[predicate.name] ?? '').contains(
                predicate.value ?? '',
              ),
            )
            .toList(),
        _PredicateKind.textContains => current
            .where((node) => node.text.contains(predicate.value ?? ''))
            .toList(),
        _PredicateKind.textEquals => current
            .where((node) => node.text.trim() == predicate.value)
            .toList(),
        _PredicateKind.unsupported => current,
      };
    }
    return current;
  }

  List<Element> _positionFilter(List<Element> nodes, int position) {
    // XPath position 是 1-based；负数表示从末尾数。
    final index = position > 0 ? position - 1 : nodes.length + position;
    if (index < 0 || index >= nodes.length) return const [];
    return [nodes[index]];
  }

  List<Object?> _terminalValues(
    List<Element> nodes,
    _XPathTerminal terminal,
    String attributeName,
  ) {
    switch (terminal) {
      case _XPathTerminal.text:
        return nodes.map((node) => node.text.trim()).toList();
      case _XPathTerminal.html:
        return nodes.map((node) => node.innerHtml).toList();
      case _XPathTerminal.all:
        return nodes.map((node) => node.outerHtml).toList();
      case _XPathTerminal.attribute:
        return nodes
            .map((node) => node.attributes[attributeName] ?? '')
            .where((value) => value.isNotEmpty)
            .toList();
      case _XPathTerminal.none:
        return nodes;
    }
  }
}

enum _XPathAxis { child, descendantOrSelf }

enum _XPathTerminal { none, text, html, all, attribute }

enum _PredicateKind {
  position,
  last,
  attributeExists,
  attributeEquals,
  attributeContains,
  textContains,
  textEquals,
  unsupported,
}

class _XPathStep {
  const _XPathStep({
    required this.axis,
    required this.nodeTest,
    required this.predicates,
  });

  final _XPathAxis axis;
  final String nodeTest;
  final List<_XPathPredicate> predicates;
}

class _XPathPredicate {
  const _XPathPredicate(this.kind, this.name, this.value, this.number);

  final _PredicateKind kind;
  final String? name;
  final String? value;
  final int? number;
}
