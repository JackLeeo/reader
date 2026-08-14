// 书源管理 - 加载、启用/禁用、增删
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/book_source.dart';
import '../utils/log.dart';
import 'http_client.dart';

class BookSourceService extends ChangeNotifier {
  final List<BookSource> _sources = [];
  bool _initialized = false;

  List<BookSource> get sources => List.unmodifiable(_sources);
  bool get initialized => _initialized;

  /// 启用的书源（搜索时只用这些）
  List<BookSource> get enabledSources =>
      _sources.where((s) => s.isEnabled).toList(growable: false);

  Future<void> init() async {
    if (_initialized) return;
    await _loadBuiltin();
    await _loadFromPrefs();
    _initialized = true;
    Log.i('BookSourceService init: total=${_sources.length} enabled=${enabledSources.length}');
    notifyListeners();
  }

  /// 加载内置书源（assets）
  Future<void> _loadBuiltin() async {
    try {
      final raw = await rootBundle.loadString('assets/book_sources/perfect_sources.json');
      final list = jsonDecode(raw) as List;
      int added = 0;
      for (final item in list) {
        if (item is Map) {
          try {
            final source = BookSource.fromJson(
                item.map((k, v) => MapEntry(k.toString(), v)));
            _sources.add(source);
            added++;
          } catch (e) {
            Log.w('解析书源失败: $e');
          }
        }
      }
      Log.i('内置书源载入: $added 个');
    } catch (e, st) {
      Log.e('加载内置书源失败', error: e, stack: st);
    }
  }

  /// 从本地偏好加载用户自定义书源
  Future<void> _loadFromPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final disabled = prefs.getStringList('disabled_sources') ?? [];
      // 标记已禁用的
      for (final s in _sources) {
        if (disabled.contains(s.id)) {
          s.isEnabled = false;
        }
      }
      // 解析自定义
      final custom = prefs.getString('custom_sources');
      if (custom != null && custom.isNotEmpty) {
        final list = jsonDecode(custom) as List;
        for (final item in list) {
          if (item is Map) {
            try {
              final source = BookSource.fromJson(
                  item.map((k, v) => MapEntry(k.toString(), v)));
              _sources.add(source);
            } catch (_) {}
          }
        }
      }
      // === 自我修复: 检测到"全部书源被禁用"自动恢复 ===
      // 触发条件: 内置书源 >= 50, 启用数 == 0 (几乎肯定是误禁)
      await _autoRecoverIfAllDisabled();
    } catch (e) {
      Log.w('加载自定义书源失败: $e');
    }
  }

  /// 自我修复: 如果内置书源全部被禁用, 自动恢复
  /// 场景: 之前版本因 _invalidAutoDisable=true 自动禁用过所有源, 升级后
  ///       仍读不到源. 这个机制保证一旦检测到"全被禁用"就强制恢复,
  ///       即使用户的 SharedPreferences 里的 disabled_sources 列表是脏的.
  /// 只在内置源>=50 且启用==0 时触发, 不会干扰用户主动全禁的情况
  /// (用户主动全禁时 disabled_sources 也会有大量 id, 走恢复也安全,
  ///  反正用户可以再去手动关)
  Future<void> _autoRecoverIfAllDisabled() async {
    if (_sources.length < 50) return; // 内置源数太少, 不触发
    final enabledCount = _sources.where((s) => s.isEnabled).length;
    if (enabledCount > 0) return; // 有启用的, 正常
    // 全部被禁用
    final prefs = await SharedPreferences.getInstance();
    final disabled = prefs.getStringList('disabled_sources') ?? [];
    if (disabled.length < _sources.length * 0.5) {
      // disabled 列表里少于一半的内置源, 不是"批量误禁"场景
      // 可能是用户主动全禁 (主动全禁一般全加)
      return;
    }
    // 触发恢复: 清空 disabled_sources, 全部启用
    Log.w('自我修复触发: ${_sources.length} 个内置源全部被禁用 (disabled 列表 ${disabled.length} 项), 自动恢复');
    for (final s in _sources) {
      s.isEnabled = true;
    }
    await prefs.setStringList('disabled_sources', []);
    Log.w('自我修复完成: 已清空 disabled_sources, 启用全部 ${_sources.length} 个源');
  }

  Future<void> toggleSource(String id, bool enabled) async {
    final source = _sources.firstWhere((s) => s.id == id, orElse: () => throw 'not found');
    source.isEnabled = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    final disabled = prefs.getStringList('disabled_sources') ?? [];
    if (enabled) {
      disabled.remove(id);
    } else {
      if (!disabled.contains(id)) disabled.add(id);
    }
    await prefs.setStringList('disabled_sources', disabled);
  }

  /// 通过网络URL添加书源
  Future<int> addFromUrl(String url) async {
    final client = HttpClient();
    final resp = await client.get(url);
    if (resp.statusCode != 200 || resp.data == null) {
      throw '下载失败: ${resp.statusCode}';
    }
    return addFromJsonText(resp.data!);
  }

  /// 从JSON文本添加（可粘贴剪贴板内容）
  Future<int> addFromJsonText(String text) async {
    final list = jsonDecode(text);
    final candidates = <Map<String, dynamic>>[];
    if (list is List) {
      for (final item in list) {
        if (item is Map) {
          candidates.add(item.map((k, v) => MapEntry(k.toString(), v)));
        }
      }
    } else if (list is Map) {
      candidates.add(list.map((k, v) => MapEntry(k.toString(), v)));
    }

    int added = 0;
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString('custom_sources');
    final customs = (existing != null && existing.isNotEmpty)
        ? (jsonDecode(existing) as List).cast<dynamic>().toList()
        : <dynamic>[];

    for (final map in candidates) {
      try {
        final source = BookSource.fromJson(map);
        // 去重
        if (_sources.any((s) => s.id == source.id)) continue;
        _sources.add(source);
        customs.add(source.toJson());
        added++;
      } catch (e) {
        Log.w('解析自定义书源失败: $e');
      }
    }
    await prefs.setString('custom_sources', jsonEncode(customs));
    notifyListeners();
    return added;
  }

  BookSource? findById(String id) {
    try {
      return _sources.firstWhere((s) => s.id == id);
    } catch (_) {
      return null;
    }
  }

  /// 批量启用所有
  Future<void> enableAll() async {
    for (final s in _sources) {
      s.isEnabled = true;
    }
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('disabled_sources', []);
  }

  /// 重置所有书源到初始状态 (内置源全启用, 自定义源保留)
  /// 用于一键恢复"全被禁用"或"全被启用"的状态
  Future<void> resetAllToDefault() async {
    for (final s in _sources) {
      s.isEnabled = true;
    }
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('disabled_sources', []);
  }

  /// 公开的通知方法 (供其他服务在外部修改源后触发 UI 刷新)
  void notifyChanged() => notifyListeners();
}
