// 书源数据模型（Legado格式）
import 'dart:convert';

import 'package:crypto/crypto.dart';

/// 探索分类项
class ExploreCategory {
  final String title;
  final String url;
  ExploreCategory({required this.title, required this.url});

  factory ExploreCategory.fromJson(Map<String, dynamic> json) {
    return ExploreCategory(
      title: (json['title'] ?? '').toString(),
      url: (json['url'] ?? '').toString(),
    );
  }
}

/// 书源模型
class BookSource {
  final String bookSourceName;
  final String bookSourceUrl;
  final String bookSourceGroup;
  final String bookSourceComment;
  final int bookSourceType;
  final String bookUrlPattern;
  final String searchUrl;
  final String exploreUrl;
  final Map<String, dynamic> ruleSearch;
  final Map<String, dynamic> ruleBookInfo;
  final Map<String, dynamic> ruleToc;
  final Map<String, dynamic> ruleContent;
  final Map<String, dynamic> ruleExplore;
  final Map<String, String> header;
  final bool enabled;
  final int customOrder;
  final int weight;

  // 内部状态
  bool _enabled;

  BookSource({
    required this.bookSourceName,
    required this.bookSourceUrl,
    this.bookSourceGroup = '',
    this.bookSourceComment = '',
    this.bookSourceType = 0,
    this.bookUrlPattern = '',
    this.searchUrl = '',
    this.exploreUrl = '',
    this.ruleSearch = const {},
    this.ruleBookInfo = const {},
    this.ruleToc = const {},
    this.ruleContent = const {},
    this.ruleExplore = const {},
    this.header = const {},
    this.enabled = true,
    this.customOrder = 0,
    this.weight = 0,
  }) : _enabled = enabled;

  bool get isEnabled => _enabled;
  set isEnabled(bool value) => _enabled = value;

  /// 稳定ID（基于URL的SHA1）
  String get id {
    return 'bs_${sha1.convert(utf8.encode(bookSourceUrl)).toString().substring(0, 16)}';
  }

  String get baseUrl {
    final uri = Uri.tryParse(bookSourceUrl);
    if (uri == null) return bookSourceUrl;
    return '${uri.scheme}://${uri.host}';
  }

  /// 解析exploreUrl字符串为分类列表
  /// exploreUrl可能是JSON数组格式或"标题::URL\n"格式
  List<ExploreCategory> get exploreCategories {
    if (exploreUrl.trim().isEmpty) return const [];
    final text = exploreUrl.trim();

    // 尝试JSON格式
    if (text.startsWith('[')) {
      try {
        final list = jsonDecode(text) as List;
        return list
            .whereType<Map>()
            .map((e) => ExploreCategory.fromJson(
                e.map((k, v) => MapEntry(k.toString(), v))))
            .where((e) => e.title.isNotEmpty && e.url.isNotEmpty)
            .toList();
      } catch (_) {
        // 忽略，尝试下一格式
      }
    }

    // "标题::URL" 格式
    final categories = <ExploreCategory>[];
    for (final line in text.split('\n')) {
      final parts = line.split('::');
      if (parts.length >= 2) {
        final title = parts[0].trim();
        final url = parts.sublist(1).join('::').trim();
        if (title.isNotEmpty && url.isNotEmpty) {
          categories.add(ExploreCategory(title: title, url: url));
        }
      }
    }
    return categories;
  }

  factory BookSource.fromJson(Map<String, dynamic> json) {
    Map<String, dynamic> ruleMap(String key) {
      final v = json[key];
      if (v is Map) {
        return v.map((k, val) => MapEntry(k.toString(), val));
      }
      if (v is String && v.trim().startsWith('{')) {
        try {
          final decoded = jsonDecode(v);
          if (decoded is Map) {
            return decoded.map((k, val) => MapEntry(k.toString(), val));
          }
        } catch (_) {}
      }
      return {};
    }

    Map<String, String> headerMap = const {};
    final h = json['header'];
    if (h is String && h.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(h);
        if (decoded is Map) {
          headerMap = decoded.map((k, v) => MapEntry(k.toString(), v?.toString() ?? ''));
        }
      } catch (_) {}
    } else if (h is Map) {
      headerMap = h.map((k, v) => MapEntry(k.toString(), v?.toString() ?? ''));
    }

    return BookSource(
      bookSourceName: (json['bookSourceName'] ?? '').toString(),
      bookSourceUrl: (json['bookSourceUrl'] ?? '').toString(),
      bookSourceGroup: (json['bookSourceGroup'] ?? '').toString(),
      bookSourceComment: (json['bookSourceComment'] ?? '').toString(),
      bookSourceType: (json['bookSourceType'] ?? 0) is int
          ? json['bookSourceType'] as int
          : int.tryParse(json['bookSourceType']?.toString() ?? '0') ?? 0,
      bookUrlPattern: (json['bookUrlPattern'] ?? '').toString(),
      searchUrl: (json['searchUrl'] ?? '').toString(),
      exploreUrl: (json['exploreUrl'] ?? '').toString(),
      ruleSearch: ruleMap('ruleSearch'),
      ruleBookInfo: ruleMap('ruleBookInfo'),
      ruleToc: ruleMap('ruleToc'),
      ruleContent: ruleMap('ruleContent'),
      ruleExplore: ruleMap('ruleExplore'),
      header: headerMap,
      enabled: json['enabled'] != false,
      customOrder: (json['customOrder'] ?? 0) is int
          ? json['customOrder'] as int
          : int.tryParse(json['customOrder']?.toString() ?? '0') ?? 0,
      weight: (json['weight'] ?? 0) is int
          ? json['weight'] as int
          : int.tryParse(json['weight']?.toString() ?? '0') ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'bookSourceName': bookSourceName,
        'bookSourceUrl': bookSourceUrl,
        'bookSourceGroup': bookSourceGroup,
        'bookSourceComment': bookSourceComment,
        'bookSourceType': bookSourceType,
        'bookUrlPattern': bookUrlPattern,
        'searchUrl': searchUrl,
        'exploreUrl': exploreUrl,
        'ruleSearch': ruleSearch,
        'ruleBookInfo': ruleBookInfo,
        'ruleToc': ruleToc,
        'ruleContent': ruleContent,
        'ruleExplore': ruleExplore,
        'header': header,
        'enabled': _enabled,
        'customOrder': customOrder,
        'weight': weight,
      };

  BookSource copyWith({
    bool? enabled,
  }) {
    final newSource = BookSource(
      bookSourceName: bookSourceName,
      bookSourceUrl: bookSourceUrl,
      bookSourceGroup: bookSourceGroup,
      bookSourceComment: bookSourceComment,
      bookSourceType: bookSourceType,
      bookUrlPattern: bookUrlPattern,
      searchUrl: searchUrl,
      exploreUrl: exploreUrl,
      ruleSearch: ruleSearch,
      ruleBookInfo: ruleBookInfo,
      ruleToc: ruleToc,
      ruleContent: ruleContent,
      ruleExplore: ruleExplore,
      header: header,
      enabled: enabled ?? _enabled,
      customOrder: customOrder,
      weight: weight,
    );
    return newSource;
  }
}
