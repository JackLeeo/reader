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
      final custom = prefs.getString('custom_sources');
      // 标记已禁用的
      for (final s in _sources) {
        if (disabled.contains(s.id)) {
          s.isEnabled = false;
        }
      }
      // 解析自定义
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
    } catch (e) {
      Log.w('加载自定义书源失败: $e');
    }
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
}

// 引入ChangeNotifier
class ChangeNotifier {
  final List<void Function()> _listeners = [];
  void addListener(void Function() l) => _listeners.add(l);
  void removeListener(void Function() l) => _listeners.remove(l);
  void notifyListeners() {
    for (final l in _listeners.toList()) {
      l();
    }
  }
}
