import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xml/xml.dart';

import '../analyze/analyze_rule.dart';

/// RSS / Atom 订阅源条目。
class RssItem {
  RssItem({
    required this.title,
    required this.link,
    required this.description,
    this.author,
    this.pubDate,
    this.image,
  });

  final String title;
  final String link;
  final String description;
  final String? author;
  final String? pubDate;
  final String? image;
}

/// 一个已订阅的 RSS 源（url + 抓到的标题/条目列表）。
class RssFeed {
  RssFeed({required this.url, this.title = '', this.items = const []});

  final String url;
  String title;
  List<RssItem> items;
}

/// RSS 规则源（对应官方 RssSource）——用自定义解析规则抓取非标准 RSS 页面。
///
/// 字段命名对齐官方。解析经 [AnalyzeRule] 完成（CSS/XPath/JS 等规则语法通用）。
class RssSource {
  RssSource({
    required this.name,
    this.sourceUrl = '',
    this.ruleArticles = '',
    this.ruleTitle = '',
    this.rulePubDate = '',
    this.ruleDescription = '',
    this.ruleImage = '',
    this.ruleLink = '',
    this.ruleNextPage = '',
    this.enabled = true,
  });

  String name;
  String sourceUrl;
  String ruleArticles;
  String ruleTitle;
  String rulePubDate;
  String ruleDescription;
  String ruleImage;
  String ruleLink;
  String ruleNextPage;
  bool enabled;

  factory RssSource.fromJson(Map<String, dynamic> m) => RssSource(
        name: (m['name'] as String?) ?? '',
        sourceUrl: (m['sourceUrl'] as String?) ?? '',
        ruleArticles: (m['ruleArticles'] as String?) ?? '',
        ruleTitle: (m['ruleTitle'] as String?) ?? '',
        rulePubDate: (m['rulePubDate'] as String?) ?? '',
        ruleDescription: (m['ruleDescription'] as String?) ?? '',
        ruleImage: (m['ruleImage'] as String?) ?? '',
        ruleLink: (m['ruleLink'] as String?) ?? '',
        ruleNextPage: (m['ruleNextPage'] as String?) ?? '',
        enabled: (m['enabled'] as bool?) ?? true,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'sourceUrl': sourceUrl,
        'ruleArticles': ruleArticles,
        'ruleTitle': ruleTitle,
        'rulePubDate': rulePubDate,
        'ruleDescription': ruleDescription,
        'ruleImage': ruleImage,
        'ruleLink': ruleLink,
        'ruleNextPage': ruleNextPage,
        'enabled': enabled,
      };
}

/// RSS 服务：订阅源管理（普通 url + 规则源）+ 抓取解析（RSS 2.0 / Atom / 自定义规则）。
class RssService {
  RssService._();

  static final RssService instance = RssService._();

  static const String _prefsKey = 'rss_feeds_v1';
  static const String _sourcesPrefsKey = 'rss_sources_v1';
  static const String _favsPrefsKey = 'rss_favorites_v1';

  final List<String> _urls = [];
  final List<RssSource> _sources = [];
  final Set<String> _favs = {};
  bool initialized = false;

  List<String> get urls => List.unmodifiable(_urls);
  List<RssSource> get sources => List.unmodifiable(_sources);

  /// 收藏的条目标识（`{feedUrl}|{link}`）。
  Set<String> get favorites => Set.unmodifiable(_favs);

  bool isFavorite(String feedUrl, RssItem item) =>
      _favs.contains(_favKey(feedUrl, item));

  void toggleFavorite(String feedUrl, RssItem item) {
    final k = _favKey(feedUrl, item);
    if (!_favs.add(k)) _favs.remove(k);
    save();
  }

  String _favKey(String feedUrl, RssItem item) =>
      '$feedUrl|${item.link.isEmpty ? item.title : item.link}';

  Future<void> init() async {
    if (initialized) return;
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_prefsKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        _urls
          ..clear()
          ..addAll((jsonDecode(raw) as List).cast<String>());
      } catch (_) {
        _urls.clear();
      }
    }
    final srcRaw = p.getString(_sourcesPrefsKey);
    if (srcRaw != null && srcRaw.isNotEmpty) {
      try {
        _sources
          ..clear()
          ..addAll((jsonDecode(srcRaw) as List)
              .map((e) => RssSource.fromJson(e as Map<String, dynamic>)));
      } catch (_) {
        _sources.clear();
      }
    }
    final favRaw = p.getString(_favsPrefsKey);
    if (favRaw != null && favRaw.isNotEmpty) {
      try {
        _favs
          ..clear()
          ..addAll((jsonDecode(favRaw) as List).cast<String>());
      } catch (_) {
        _favs.clear();
      }
    }
    initialized = true;
  }

  void addFeed(String url) {
    if (url.trim().isEmpty || _urls.contains(url)) return;
    _urls.add(url.trim());
    save();
  }

  void removeFeed(String url) {
    _urls.remove(url);
    save();
  }

  void addSource(RssSource src) {
    final idx = _sources.indexWhere((s) => s.name == src.name);
    if (idx >= 0) {
      _sources[idx] = src;
    } else {
      _sources.add(src);
    }
  }

  void updateSource(RssSource src) => addSource(src);

  void removeSource(String name) {
    _sources.removeWhere((s) => s.name == name);
    save();
  }

  RssSource? sourceByName(String name) {
    for (final s in _sources) {
      if (s.name == name) return s;
    }
    return null;
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_prefsKey, jsonEncode(_urls));
    await p.setString(_sourcesPrefsKey, jsonEncode(_sources.map((s) => s.toJson()).toList()));
    await p.setString(_favsPrefsKey, jsonEncode(_favs.toList()));
  }

  /// 抓取并解析一个订阅源 url（普通 RSS/Atom，非规则源）。
  Future<RssFeed> fetch(String url) async {
    final resp = await http.get(Uri.parse(url));
    final parsed = parseFeed(resp.body);
    return RssFeed(
      url: url,
      title: parsed?.title ?? '',
      items: parsed?.items ?? const [],
    );
  }

  /// 抓取并解析一个规则源（自定义规则）。
  Future<RssFeed> fetchByRule(RssSource src) async {
    final resp = await http.get(Uri.parse(src.sourceUrl));
    final items = await parseByRule(resp.body, src);
    return RssFeed(url: src.sourceUrl, title: src.name, items: items);
  }

  /// 用自定义规则解析 RSS 源（对应官方 RssParserByRule）。
  Future<List<RssItem>> parseByRule(String body, RssSource src) async {
    final analyze = AnalyzeRule();
    analyze.setBaseUrl(src.sourceUrl);
    analyze.setContent(body);

    final listRule = src.ruleArticles;
    if (listRule.trim().isEmpty) return const [];

    final elements = await analyze.getElementsAsync(listRule);
    if (elements.isEmpty) return const [];

    final out = <RssItem>[];
    for (final el in elements) {
      final title = _str(await analyze.getStringAsync(src.ruleTitle, mContent: el));
      if (title.isEmpty) continue; // 无标题条目丢弃，对齐官方
      final link = _str(await analyze.getStringAsync(src.ruleLink, mContent: el));
      out.add(RssItem(
        title: title,
        link: link.isEmpty && src.sourceUrl.isNotEmpty
            ? src.sourceUrl
            : link,
        description: _str(await analyze.getStringAsync(src.ruleDescription, mContent: el)),
        pubDate: _strOrNull(await analyze.getStringAsync(src.rulePubDate, mContent: el)),
        image: _strOrNull(await analyze.getStringAsync(src.ruleImage, mContent: el)),
      ));
    }
    return out;
  }

  static String _str(String s) => s.trim();
  static String? _strOrNull(String s) {
    final t = s.trim();
    return t.isEmpty ? null : t;
  }

  /// 解析 RSS 2.0 或 Atom 源。
  static RssFeed? parseFeed(String body) {
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(body);
    } catch (_) {
      return null;
    }
    final root = doc.rootElement;
    final name = root.name.local;
    if (name == 'rss') {
      final channel = root.findElements('channel').isNotEmpty
          ? root.findElements('channel').first
          : null;
      if (channel == null) return null;
      final title = channel.getElement('title')?.innerText.trim() ?? '';
      final items = <RssItem>[
        for (final it in channel.findElements('item'))
          RssItem(
            title: it.getElement('title')?.innerText.trim() ?? '',
            link: it.getElement('link')?.innerText.trim() ?? '',
            description: it.getElement('description')?.innerText.trim() ?? '',
            author: it.getElement('author')?.innerText.trim(),
            pubDate: it.getElement('pubDate')?.innerText.trim(),
          ),
      ];
      return RssFeed(url: '', title: title, items: items);
    }
    if (name == 'feed') {
      final title = root.getElement('title')?.innerText.trim() ?? '';
      final items = <RssItem>[];
      for (final e in root.findElements('entry')) {
        String? link;
        for (final l in e.findElements('link')) {
          final rel = l.getAttribute('rel');
          if (rel == null || rel == 'alternate') {
            link = l.getAttribute('href');
            if (link != null) break;
          }
        }
        items.add(RssItem(
          title: e.getElement('title')?.innerText.trim() ?? '',
          link: link ?? '',
          description:
              (e.getElement('summary')?.innerText ?? e.getElement('content')?.innerText ?? '')
                  .trim(),
          author: e.getElement('author')?.innerText.trim(),
          pubDate: e.getElement('updated')?.innerText.trim(),
        ));
      }
      return RssFeed(url: '', title: title, items: items);
    }
    return null;
  }

  void clear() {
    _urls.clear();
    _sources.clear();
    initialized = false;
  }
}