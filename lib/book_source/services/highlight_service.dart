import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 高亮绘制样式（对齐官方 ChapterHighlight.Style）。
enum HighlightDrawStyle {
  /// 背景高亮（默认）
  highlight,

  /// 下划线
  underline,

  /// 删除线
  strikethrough,
}

HighlightDrawStyle _parseStyle(Object? v) {
  switch (v?.toString().toLowerCase()) {
    case 'underline':
      return HighlightDrawStyle.underline;
    case 'strikethrough':
    case 'line_through':
    case 'lineThrough':
      return HighlightDrawStyle.strikethrough;
    default:
      return HighlightDrawStyle.highlight;
  }
}

/// 一条高亮（划词/规则均可），含颜色、样式、可编辑笔记（对齐官方可编辑高亮）。
///
/// [keyword] 做精确匹配（内部用 [RegExp.escape] 转义，支持高亮全部命中）；
/// [pattern] 为可选的原始正则表达式（优先级高于 [keyword]）。
/// [colorHex] 如 `#FF0000`。[style] 决定绘制方式（背景/下划线/删除线）。
/// [note] 可选笔记，用于「查看/编辑笔记」。
class HighlightRule {
  HighlightRule({
    required this.name,
    this.keyword = '',
    this.pattern = '',
    this.colorHex = '#FFFF00',
    this.style = HighlightDrawStyle.highlight,
    this.note,
    this.enabled = true,
  });

  String name;
  String keyword;
  String pattern;
  String colorHex;
  HighlightDrawStyle style;
  String? note;
  bool enabled;

  factory HighlightRule.fromJson(Map<String, dynamic> m) => HighlightRule(
        name: (m['name'] as String?) ?? '',
        keyword: (m['keyword'] as String?) ?? '',
        pattern: (m['pattern'] as String?) ?? '',
        colorHex: (m['colorHex'] as String?) ?? '#FFFF00',
        style: _parseStyle(m['style']),
        note: (m['note'] as String?)?.trim().isEmpty ?? true
            ? null
            : (m['note'] as String?)?.trim(),
        enabled: (m['enabled'] as bool?) ?? true,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'keyword': keyword,
        'pattern': pattern,
        'colorHex': colorHex,
        'style': style.name,
        'note': note,
        'enabled': enabled,
      };

  /// 把本规则的命中区间应用到 [text] 上，返回按 start 排序的区间。
  List<HighlightMatch> matchAll(String text) {
    final out = <HighlightMatch>[];
    if (text.isEmpty) return out;
    if (pattern.trim().isNotEmpty) {
      final re = _compilePattern();
      if (re != null) {
        for (final m in re.allMatches(text)) {
          out.add(_makeMatch(m.start, m.end));
        }
        out.sort((a, b) => a.start.compareTo(b.start));
        return out;
      }
    }
    // keyword 精确匹配（正则转义）。
    final kw = keyword;
    if (kw.isEmpty) return out;
    final re = RegExp(RegExp.escape(kw));
    for (final m in re.allMatches(text)) {
      out.add(_makeMatch(m.start, m.end));
    }
    out.sort((a, b) => a.start.compareTo(b.start));
    return out;
  }

  HighlightMatch _makeMatch(int start, int end) => HighlightMatch(
        start: start,
        end: end,
        ruleName: name,
        colorHex: colorHex,
        style: style,
        note: note,
      );

  RegExp? _compilePattern() {
    try {
      return RegExp(pattern);
    } catch (_) {
      return null;
    }
  }
}

/// 一个高亮命中区间。
class HighlightMatch {
  HighlightMatch({
    required this.start,
    required this.end,
    required this.ruleName,
    required this.colorHex,
    this.style = HighlightDrawStyle.highlight,
    this.note,
  });

  final int start;
  final int end;
  final String ruleName;
  final String colorHex;
  final HighlightDrawStyle style;
  final String? note;
}

/// 正文高亮服务：管理一组高亮规则并对正文文本应用。
///
/// [apply] 对所有启用规则跑命中的区间，统一按 start 排序返回。
/// 无规则 / 空文本 / 非法正则时返回空列表，不抛异常。
class HighlightService {
  HighlightService._();

  static final HighlightService instance = HighlightService._();

  static const String _prefsKey = 'highlight_rules_v1';

  final List<HighlightRule> _rules = [];
  bool initialized = false;

  List<HighlightRule> get rules => List.unmodifiable(_rules);

  Future<void> init() async {
    if (initialized) return;
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_prefsKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        _rules
          ..clear()
          ..addAll((jsonDecode(raw) as List)
              .map((e) => HighlightRule.fromJson(e as Map<String, dynamic>)));
      } catch (_) {
        _rules.clear();
      }
    }
    initialized = true;
  }

  void addRule(HighlightRule rule) {
    final idx = _rules.indexWhere((r) => r.name == rule.name);
    if (idx >= 0) {
      _rules[idx] = rule;
    } else {
      _rules.add(rule);
    }
    save();
  }

  void updateRule(HighlightRule rule) => addRule(rule);

  void removeRule(String name) {
    _rules.removeWhere((r) => r.name == name);
    save();
  }

  HighlightRule? ruleByName(String name) {
    for (final r in _rules) {
      if (r.name == name) return r;
    }
    return null;
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_prefsKey, jsonEncode(_rules.map((r) => r.toJson()).toList()));
  }

  /// 对 [text] 应用全部启用规则，返回按 start 排序的命中区间。
  List<HighlightMatch> apply(String text) {
    if (text.isEmpty) return const [];
    final matches = <HighlightMatch>[];
    for (final r in _rules) {
      if (!r.enabled) continue;
      matches.addAll(r.matchAll(text));
    }
    matches.sort((a, b) {
      final c = a.start.compareTo(b.start);
      if (c != 0) return c;
      return a.end.compareTo(b.end);
    });
    return matches;
  }

  void clear() {
    _rules.clear();
    initialized = false;
  }
}