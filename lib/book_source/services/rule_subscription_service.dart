import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/book_source.dart';
import 'book_source_service.dart';
import 'http_service.dart';

/// 规则订阅（对应官方「规则订阅」）。
///
/// 订阅一个返回书源 JSON 的远端地址，拉取后合并进本地书源库，
/// 并记录订阅源与最近拉取时间，支持手动刷新。
class RuleSubscription {
  RuleSubscription({
    required this.url,
    this.name = '',
    this.lastFetchTime = 0,
    this.error = '',
  });

  final String url;
  String name;
  int lastFetchTime;
  String error;

  factory RuleSubscription.fromJson(Map<String, dynamic> m) => RuleSubscription(
        url: (m['url'] ?? '') as String,
        name: (m['name'] ?? '') as String,
        lastFetchTime: (m['lastFetchTime'] ?? 0) as int,
        error: (m['error'] ?? '') as String,
      );

  Map<String, dynamic> toJson() => {
        'url': url,
        'name': name,
        'lastFetchTime': lastFetchTime,
        'error': error,
      };
}

/// 拉取结果。
class RuleSubscriptionResult {
  RuleSubscriptionResult({required this.imported, this.message = ''});

  final int imported;
  final String message;
}

/// 规则订阅服务：订阅管理 + 拉取导入。
class RuleSubscriptionService {
  RuleSubscriptionService._();

  static final RuleSubscriptionService instance = RuleSubscriptionService._();

  static const String _prefsKey = 'rule_subscriptions_v1';

  final List<RuleSubscription> _items = [];
  bool initialized = false;

  List<RuleSubscription> get items => List.unmodifiable(_items);

  Future<void> init() async {
    if (initialized) return;
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_prefsKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        _items
          ..clear()
          ..addAll((jsonDecode(raw) as List)
              .map((e) => RuleSubscription.fromJson(e as Map<String, dynamic>)));
      } catch (_) {
        _items.clear();
      }
    }
    initialized = true;
  }

  /// 新增订阅（重复 URL 幂等更新）。
  void add(RuleSubscription sub) {
    final idx = _items.indexWhere((s) => s.url == sub.url);
    if (idx >= 0) {
      _items[idx] = sub;
    } else {
      _items.add(sub);
    }
    save();
  }

  void remove(String url) {
    _items.removeWhere((s) => s.url == url);
    save();
  }

  /// 清空内存中的订阅（测试用）。
  void clear() {
    _items.clear();
  }

  /// 完全重置（清空内存 + 标记未初始化，测试用）。
  void reset() {
    _items.clear();
    initialized = false;
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(
        _prefsKey, jsonEncode(_items.map((s) => s.toJson()).toList()));
  }

  /// 从订阅 JSON 解析书源列表（兼容数组 / 单对象 / 带 bookSources 包装）。
  static List<BookSource> parseBookSources(dynamic decoded) {
    final list = <BookSource>[];
    void collect(dynamic node) {
      if (node is Map) {
        // 单书源对象，或带 bookSources 的包装。
        if (node.containsKey('bookSources') && node['bookSources'] is List) {
          collect(node['bookSources']);
        } else {
          final s = BookSource.fromJson(Map<String, dynamic>.from(node));
          if (s.bookSourceUrl.isNotEmpty) list.add(s);
        }
      } else if (node is List) {
        for (final e in node) {
          collect(e);
        }
      }
    }

    collect(decoded);
    return list;
  }

  /// 拉取订阅内容并导入书源库。
  ///
  /// 兼容：纯书源数组 / 单书源对象 / 带 `bookSources` 字段的订阅包装。
  /// 返回导入成功数。
  Future<RuleSubscriptionResult> fetch(String url) async {
    final resp =
        await HttpService.instance.get(url, timeout: const Duration(seconds: 20));
    if (!resp.ok) {
      throw Exception('拉取失败：HTTP ${resp.statusCode}');
    }
    final dynamic decoded;
    try {
      decoded = jsonDecode(resp.body);
    } catch (_) {
      throw const FormatException('订阅内容不是合法 JSON');
    }

    final list = parseBookSources(decoded);
    if (list.isEmpty) throw const FormatException('未解析到有效书源');

    final imported = BookSourceService.instance.importAll(list);
    await BookSourceService.instance.save();

    // 更新订阅记录（名称取 URL 主机名）。
    add(RuleSubscription(
      url: url,
      name: Uri.tryParse(url)?.host ?? url,
      lastFetchTime: DateTime.now().millisecondsSinceEpoch,
      error: '',
    ));

    return RuleSubscriptionResult(imported: imported, message: '导入 $imported 个书源');
  }
}
