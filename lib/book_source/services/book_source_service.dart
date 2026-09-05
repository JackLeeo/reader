import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/book_source.dart';

/// 书源导入对比项：导入源与库内同名源（按 URL 匹配）的差异。
class SourceImportDiff {
  const SourceImportDiff({required this.incoming, this.existing});

  final BookSource incoming;

  /// 库内已存在的同名源；null 表示全新书源。
  final BookSource? existing;

  bool get isNew => existing == null;

  /// 与已有源完全一致（无需更新）。
  bool get identical =>
      existing != null &&
      jsonEncode(existing!.toJson()) == jsonEncode(incoming.toJson());
}

/// 书源管理服务（对应官方 `BookSourceDao` + `Config` 组合）。
///
/// 职责：
/// - 持久化书源（shared_preferences 存 JSON，key = URL 去重）
/// - 增删改查：导入 / 启用禁用 / 分组管理 / 导出 / 权重排序
/// - 读取所有可用（enabled）书源供聚合搜索用
class BookSourceService {
  BookSourceService._();

  static final BookSourceService instance = BookSourceService._();

  static const String _prefsKey = 'book_sources_cache_v1';

  /// 当前已加载的全部书源（按 customOrder/weight 排序）。
  final List<BookSource> _sources = [];

  /// 是否已初始化。
  bool initialized = false;

  /// 分组 -> 该组内的源（计算缓存，标签分组）。
  late Map<String, List<BookSource>> _groupsMap = {};

  /// 全部唯一分组名（含“未分组”）。
  List<String> get groups => _groupsMap.keys.toList();

  /// 全部源。
  List<BookSource> get sources => List.unmodifiable(_sources);

  /// 启用的源（聚合搜索用）。
  List<BookSource> get enabledSources =>
      _sources.where((s) => s.enabled).toList();

  /// 按分组名取源。
  List<BookSource> sourcesInGroup(String group) =>
      _groupsMap[group] ?? const [];

  Future<void> init() async {
    if (initialized) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = jsonDecode(raw) as List;
        _sources
          ..clear()
          ..addAll(list.map((e) => BookSource.fromJson(e as Map<String, dynamic>)));
      } catch (_) {
        _sources.clear();
      }
    }
    _rebuildGroups();
    initialized = true;
  }

  /// 清空内存中的书源（测试用）。
  void clear() {
    _sources.clear();
    _groupsMap.clear();
  }

  /// 全量替换书源（导入备份时用），返回导入成功数。
  int importAll(List<BookSource> newSources) {
    final byUrl = <String, BookSource>{};
    for (final s in _sources) {
      byUrl[s.bookSourceUrl] = s;
    }
    for (final s in newSources) {
      if (s.bookSourceUrl.isEmpty) continue;
      byUrl[s.bookSourceUrl] = s;
    }
    _sources
      ..clear()
      ..addAll(byUrl.values);
    _sortAndRebuild();
    return byUrl.length;
  }

  /// 添加单个书源（已有则覆盖）。
  void putSource(BookSource source) {
    if (source.bookSourceUrl.isEmpty) return;
    final idx = _sources.indexWhere((s) => s.bookSourceUrl == source.bookSourceUrl);
    if (idx >= 0) {
      _sources[idx] = source;
    } else {
      _sources.add(source);
    }
    _sortAndRebuild();
  }

  /// 移除书源。
  void removeSource(String url) {
    _sources.removeWhere((s) => s.bookSourceUrl == url);
    _rebuildGroups();
  }

  /// 启用 / 禁用单个书源。
  void setEnabled(String url, bool enabled) {
    final idx = _sources.indexWhere((s) => s.bookSourceUrl == url);
    if (idx >= 0) {
      _sources[idx] = _sources[idx].copyWith(enabled: enabled);
    }
  }

  /// 启用 / 禁用单个书源的「发现」能力。
  void setExploreEnabled(String url, bool enabled) {
    final idx = _sources.indexWhere((s) => s.bookSourceUrl == url);
    if (idx >= 0) {
      _sources[idx] =
          _sources[idx].copyWith(enabledExplore: enabled);
    }
  }

  /// 全部启用 / 禁用。
  void setAllEnabled(bool enabled) {
    for (var i = 0; i < _sources.length; i++) {
      _sources[i] = _sources[i].copyWith(enabled: enabled);
    }
  }

  /// 按自定义顺序重排（官方拖动排序）。[orderedUrls] 缺省时保持 `_sources` 顺序并重写 customOrder。
  void reorder(List<String> orderedUrls) {
    if (orderedUrls.isEmpty) return;
    _sources.sort((a, b) {
      final ia = orderedUrls.indexOf(a.bookSourceUrl);
      final ib = orderedUrls.indexOf(b.bookSourceUrl);
      if (ia < 0) return 1;
      if (ib < 0) return -1;
      return ia.compareTo(ib);
    });
    _rebuildGroups();
  }

  /// 从 JSON 字符串导入书源（支持数组或单对象），返回新增数。
  int importFromJson(String jsonStr) {
    final dynamic decoded;
    try {
      decoded = jsonDecode(jsonStr);
    } catch (_) {
      return 0;
    }
    final list = <BookSource>[];
    if (decoded is List) {
      for (final e in decoded) {
        if (e is Map) {
          list.add(BookSource.fromJson(Map<String, dynamic>.from(e)));
        }
      }
    } else if (decoded is Map) {
      list.add(BookSource.fromJson(Map<String, dynamic>.from(decoded)));
    }
    return importAll(list);
  }

  /// 导出全部书源为 JSON 字符串数组。
  String exportAll() =>
      jsonEncode(_sources.map((s) => s.toJson()).toList());

  /// 对比导入：把 [incoming] 与库内按 URL 匹配，返回每条的差异（新增/更新/一致）。
  List<SourceImportDiff> diffImport(List<BookSource> incoming) {
    final existingByUrl = {
      for (final s in _sources) s.bookSourceUrl: s,
    };
    return [
      for (final s in incoming)
        SourceImportDiff(incoming: s, existing: existingByUrl[s.bookSourceUrl])
    ];
  }

  /// 应用对比结果：把 [diffs] 中选中的条目全部写入库（新增或覆盖），返回写入数。
  int applyImportDiffs(List<SourceImportDiff> diffs) {
    var n = 0;
    for (final d in diffs) {
      if (d.incoming.bookSourceUrl.isEmpty) continue;
      putSource(d.incoming);
      n++;
    }
    return n;
  }

  /// 导出指定分组。
  String exportGroup(String group) =>
      jsonEncode(sourcesInGroup(group).map((s) => s.toJson()).toList());

  void _sortAndRebuild() {
    _sources.sort((a, b) {
      final c = b.customOrder.compareTo(a.customOrder);
      if (c != 0) return c;
      return b.lastUpdateTime.compareTo(a.lastUpdateTime);
    });
    _rebuildGroups();
  }

  void _rebuildGroups() {
    final m = <String, List<BookSource>>{};
    for (final s in _sources) {
      if (s.groups.isEmpty) {
        m.putIfAbsent('未分组', () => []).add(s);
      } else {
        for (final g in s.groups) {
          m.putIfAbsent(g, () => []).add(s);
        }
      }
    }
    _groupsMap = m;
  }

  /// 立即持久化（fire-and-forget 内部 await）。
  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, exportAll());
  }
}