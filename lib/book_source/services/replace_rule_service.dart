import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 替换规则（对应官方 `ReplaceRule` 的简化实体）。
///
/// 作用于阅读正文/标题的净化：把匹配 [pattern] 的片段替换为 [replacement]。
/// 支持正则开关、按书源 URL 限定、全局/仅正文/仅标题范围。
class ReplaceRule {
  ReplaceRule({
    this.name = '',
    this.pattern = '',
    this.replacement = '',
    this.isRegex = true,
    this.enabled = true,
    this.scopeTitle = true,
    this.scopeContent = true,
    this.sourceUrl = '',
    this.sortOrder = 0,
  });

  String name;
  String pattern;
  String replacement;
  bool isRegex;
  bool enabled;
  bool scopeTitle;
  bool scopeContent;

  /// 限定书源（空 = 全局）。
  String sourceUrl;
  int sortOrder;

  factory ReplaceRule.fromJson(Map<String, dynamic> m) => ReplaceRule(
        name: (m['name'] ?? '') as String,
        pattern: (m['pattern'] ?? '') as String,
        replacement: (m['replacement'] ?? '') as String,
        isRegex: (m['isRegex'] ?? true) as bool,
        enabled: (m['enabled'] ?? true) as bool,
        scopeTitle: (m['scopeTitle'] ?? true) as bool,
        scopeContent: (m['scopeContent'] ?? true) as bool,
        sourceUrl: (m['sourceUrl'] ?? '') as String,
        sortOrder: (m['sortOrder'] ?? 0) as int,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'pattern': pattern,
        'replacement': replacement,
        'isRegex': isRegex,
        'enabled': enabled,
        'scopeTitle': scopeTitle,
        'scopeContent': scopeContent,
        'sourceUrl': sourceUrl,
        'sortOrder': sortOrder,
      };

  /// 对 [text] 执行一次替换（未启用 / 正则非法则原样返回）。
  String apply(String text) {
    if (!enabled || pattern.isEmpty) return text;
    try {
      if (isRegex) {
        return text.replaceAll(RegExp(pattern), replacement);
      }
      return text.replaceAll(pattern, replacement);
    } catch (_) {
      return text;
    }
  }
}

/// 替换规则服务：持久化 + 按书源/作用域筛选。
class ReplaceRuleService {
  ReplaceRuleService._();

  static final ReplaceRuleService instance = ReplaceRuleService._();

  static const String _prefsKey = 'replace_rules_v1';

  final List<ReplaceRule> _rules = [];
  bool initialized = false;

  List<ReplaceRule> get rules => List.unmodifiable(_rules);

  Future<void> init() async {
    if (initialized) return;
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_prefsKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        _rules
          ..clear()
          ..addAll((jsonDecode(raw) as List)
              .map((e) => ReplaceRule.fromJson(e as Map<String, dynamic>)));
      } catch (_) {
        _rules.clear();
      }
    }
    initialized = true;
  }

  /// 生效规则（启用且作用域匹配），按 sortOrder 排序。
  List<ReplaceRule> activeFor({String? sourceUrl, required bool forTitle}) {
    final list = _rules.where((r) {
      if (!r.enabled) return false;
      if (sourceUrl != null && sourceUrl.isNotEmpty && r.sourceUrl.isNotEmpty &&
          r.sourceUrl != sourceUrl) {
        return false;
      }
      return forTitle ? r.scopeTitle : r.scopeContent;
    }).toList()
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    return list;
  }

  void upsert(ReplaceRule rule) {
    final idx = _rules.indexWhere((r) => r.name == rule.name);
    if (idx >= 0) {
      _rules[idx] = rule;
    } else {
      _rules.add(rule);
    }
    save();
  }

  void remove(String name) {
    _rules.removeWhere((r) => r.name == name);
    save();
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(
        _prefsKey, jsonEncode(_rules.map((r) => r.toJson()).toList()));
  }

  void clear() {
    _rules.clear();
  }
}