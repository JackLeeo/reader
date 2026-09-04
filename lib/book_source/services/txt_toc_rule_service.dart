import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// TXT 目录规则（对齐官方「TXT目录规则」）。
///
/// 每条规则含名称与分章正则 [patternField]（匹配章节标题的一行）。
/// 解析本地书时使用 [enabled] 的规则；无可用规则时回退内置默认分章。
class TxtTocRule {
  TxtTocRule({
    required this.name,
    this.patternField = '',
    this.enabled = true,
    this.defaultRule = false,
  });

  String name;
  String patternField;
  bool enabled;
  bool defaultRule;

  factory TxtTocRule.fromJson(Map<String, dynamic> m) => TxtTocRule(
        name: (m['name'] ?? '') as String,
        patternField: (m['pattern'] ?? '') as String,
        enabled: (m['enabled'] ?? true) as bool,
        defaultRule: (m['defaultRule'] ?? false) as bool,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'pattern': patternField,
        'enabled': enabled,
        'defaultRule': defaultRule,
      };
}

/// 默认内部分章正则（与解析器内置一致，作为起步规则）。
const String kDefaultTxtTocPattern = r'^第\s*[零一二三四五六七八九十百千0-9]+\s*[章节卷集话部回]';

/// TXT 目录规则管理服务（持久化到本地）。
class TxtTocRuleService {
  TxtTocRuleService._();

  static final TxtTocRuleService instance = TxtTocRuleService._();

  static const String _prefsKey = 'txt_toc_rules_v1';

  final List<TxtTocRule> _rules = [];
  bool initialized = false;

  List<TxtTocRule> get rules => List.unmodifiable(_rules);

  Future<void> init() async {
    if (initialized) return;
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_prefsKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = jsonDecode(raw) as List;
        _rules
          ..clear()
          ..addAll(
              list.map((e) => TxtTocRule.fromJson(e as Map<String, dynamic>)));
      } catch (_) {
        _rules.clear();
      }
    }
    if (_rules.isEmpty) {
      _rules.add(TxtTocRule(
        name: '默认',
        patternField: kDefaultTxtTocPattern,
        defaultRule: true,
      ));
    }
    initialized = true;
  }

  /// 当前生效的分章正则（首个启用规则；无则 null 表示用内置）。
  String? get activePattern {
    for (final r in _rules) {
      if (r.enabled && r.patternField.trim().isNotEmpty) {
        return r.patternField.trim();
      }
    }
    return null;
  }

  void upsert(TxtTocRule rule) {
    final idx = _rules.indexWhere((r) => r.name == rule.name);
    if (idx >= 0) {
      _rules[idx] = rule;
    } else {
      _rules.add(rule);
    }
    save();
  }

  void remove(String name) {
    final idx = _rules.indexWhere((r) => r.name == name);
    if (idx < 0) return;
    if (_rules[idx].defaultRule) return; // 默认规则不可删
    _rules.removeAt(idx);
    save();
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_prefsKey, jsonEncode(_rules.map((r) => r.toJson()).toList()));
  }

  void clear() {
    _rules.clear();
    initialized = false;
  }
}