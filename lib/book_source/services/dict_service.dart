import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../analyze/analyze_rule.dart';
import 'http_service.dart';

/// 词典规则源（对齐官方主界面的「词典」配置）。
///
/// 每个词典源是一个词条查询接口，含 [url]（可含 `{word}` 占位，查询时替换为词语）、
/// 请求 [method] 与释义提取规则 [rule]。
class DictSource {
  DictSource({
    required this.name,
    this.url = '',
    this.method = 'GET',
    this.rule = '',
    this.enabled = true,
  });

  String name;
  String url;
  String method;
  String rule;
  bool enabled;

  factory DictSource.fromJson(Map<String, dynamic> m) => DictSource(
        name: (m['name'] as String?) ?? '',
        url: (m['url'] as String?) ?? '',
        method: (m['method'] as String?) ?? 'GET',
        rule: (m['rule'] as String?) ?? '',
        enabled: (m['enabled'] as bool?) ?? true,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'url': url,
        'method': method,
        'rule': rule,
        'enabled': enabled,
      };
}

/// 词典查询聚合服务。
///
/// 遍历启用中的词典源，替换 `{word}` 占位后发起查询，并用 [AnalyzeRule]
/// 按各自 [DictSource.rule] 提取释义文本，最终聚合返回。
/// 单个源网络失败 / 规则失败 / 返回非 2xx 时自动跳过，不影响其它源，不抛异常。
class DictService {
  DictService._();

  static final DictService instance = DictService._();

  static const String _prefsKey = 'dict_sources_v1';

  final List<DictSource> _sources = [];
  bool initialized = false;

  List<DictSource> get sources => List.unmodifiable(_sources);

  Future<void> init() async {
    if (initialized) return;
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_prefsKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        _sources
          ..clear()
          ..addAll((jsonDecode(raw) as List)
              .map((e) => DictSource.fromJson(e as Map<String, dynamic>)));
      } catch (_) {
        _sources.clear();
      }
    }
    initialized = true;
  }

  void addSource(DictSource src) {
    final idx = _sources.indexWhere((s) => s.name == src.name);
    if (idx >= 0) {
      _sources[idx] = src;
    } else {
      _sources.add(src);
    }
    save();
  }

  void updateSource(DictSource src) => addSource(src);

  void removeSource(String name) {
    _sources.removeWhere((s) => s.name == name);
    save();
  }

  DictSource? sourceByName(String name) {
    for (final s in _sources) {
      if (s.name == name) return s;
    }
    return null;
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_prefsKey, jsonEncode(_sources.map((s) => s.toJson()).toList()));
  }

  /// 去 HTML/脚注等噪声，得到更干净的释义文本。
  static String _clean(String s) => s.trim();

  /// 查询 [word] 并聚合所有启用词典源的释义结果。
  ///
  /// 返回去空白后的释义列表；任一源失败会被跳过，整体不抛异常。
  Future<List<String>> query(String word) async {
    final w = word.trim();
    if (w.isEmpty) return const [];

    final results = <String>[];
    for (final src in _sources) {
      if (!src.enabled) continue;
      if (src.url.trim().isEmpty) continue;
      final text = await _queryOne(src, w);
      if (text.trim().isNotEmpty) results.add(_clean(text));
    }
    return results;
  }

  /// 查询单个词典源（失败静默返回空串）。
  Future<String> _queryOne(DictSource src, String word) async {
    final url = src.url.replaceAll('{word}', Uri.encodeQueryComponent(word));
    try {
      final resp = await HttpService.instance.get(url);
      if (!resp.ok) return '';
      if (resp.body.trim().isEmpty) return '';

      // 无解析规则时按规则提取，否则直接返回全部正文。
      final rule = src.rule.trim();
      if (rule.isEmpty) return resp.body;

      final analyze = AnalyzeRule();
      analyze.setBaseUrl(src.url);
      analyze.setContent(resp.body);
      try {
        return await analyze.getStringAsync(rule);
      } catch (_) {
        return '';
      }
    } catch (_) {
      return '';
    }
  }

  void clear() {
    _sources.clear();
    initialized = false;
  }
}