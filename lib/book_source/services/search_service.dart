import 'dart:convert';

import '../analyze/analyze_rule.dart';
import '../models/book_source.dart';
import '../models/books.dart';
import 'book_source_service.dart';
import 'http_service.dart';

/// 每个源完成后的结果回调（origin 源名、books 该书源结果、done/total 进度）。
typedef OnSearchResult = void Function(
    String origin, List<SearchBook> books, int done, int total);

/// “发现”页某书源的子分类（官方 ruleKinds / ruleScreens 解析产物）。
class ExploreKind {
  ExploreKind({required this.title, required this.url});
  final String title;
  final String url;
}

/// “发现”页首次加载的产物：要么是子分类列表，要么是书籍列表。
class ExploreOutcome {
  ExploreOutcome.books(this.books) : kinds = const [], baseUrl = null;
  ExploreOutcome.kinds(this.kinds, {this.baseUrl}) : books = const [];

  final List<SearchBook> books;
  final List<ExploreKind> kinds;
  final String? baseUrl;

  bool get hasKinds => kinds.isNotEmpty;
}

/// 聚合搜索服务（对应官方 `WebBook.searchBook` + `SearchViewModel` 的核心）。
///
/// 对每个启用的文本书源：
/// 1. 用关键字替换 `searchUrl` 占位（`{key}` / `{searchKey}`）
/// 2. GET 拉取页面
/// 3. 用 [AnalyzeRule] 按 `ruleSearch` 解析 `bookList` 元素，逐条提取字段
/// 4. 产出 [SearchBook]
class SearchService {
  SearchService._();

  static final SearchService instance = SearchService._();

  /// 结果回调（流式返回：每个源完成即回调）。
  Future<void> searchAll(
    String keyword, {
    OnSearchResult? onResult,
  }) async {
    final sources = BookSourceService.instance.enabledSources
        .where((s) => (s.searchUrl ?? '').trim().isNotEmpty)
        .toList();
    final total = sources.length;
    var done = 0;
    for (final src in sources) {
      final books = await _searchOne(src, keyword);
      done++;
      onResult?.call(src.bookSourceName, books, done, total);
    }
  }

  /// 浏览单一书源的“发现”页（对应官方 `WebBook.exploreBook`）。
  ///
  /// 取书源 `exploreUrl` 首个非空行作为发现入口地址，再按 [BookSource.ruleExplore]
  /// 解析。若书源配置了 `ruleKinds`（子分类），当入口页命中子分类规则时返回
  /// 分类列表（点击进入对应子分类）；否则直接返回 [bookList] 书籍列表。
  Future<ExploreOutcome> explore(BookSource src) async {
    final url = _firstExploreUrl(src);
    if (url == null) return ExploreOutcome.books(const []);

    final resp = await _safeGet(src, url);
    if (resp == null) return ExploreOutcome.books(const []);
    final analyze = AnalyzeRule(source: src);
    analyze.setBaseUrl(resp.finalUrl?.toString() ?? url);
    analyze.setContent(_smartContent(resp));

    // 子分类：ruleExplore.kinds / ruleKinds {kindTitle, kindUrl}
    final kinds = await _parseKinds(src, analyze);
    if (kinds.isNotEmpty) {
      return ExploreOutcome.kinds(kinds, baseUrl: resp.finalUrl?.toString() ?? url);
    }
    return ExploreOutcome.books(await _parseExploreBooks(analyze, src, resp.finalUrl?.toString() ?? url));
  }

  /// 加载发现页某个子分类（kind/screen）下的书籍列表。
  Future<List<SearchBook>> exploreAt(BookSource src, String url) async {
    final resp = await _safeGet(src, url);
    if (resp == null) return const [];
    final analyze = AnalyzeRule(source: src);
    analyze.setBaseUrl(resp.finalUrl?.toString() ?? url);
    analyze.setContent(_smartContent(resp));
    return _parseExploreBooks(analyze, src, resp.finalUrl?.toString() ?? url);
  }

  /// 解析 ruleKinds 子分类：从入口页按 kindUrl 取元素，kindTitle/kindUrl 提取名称与地址。
  Future<List<ExploreKind>> _parseKinds(BookSource src, AnalyzeRule analyze) async {
    final re = src.ruleExplore;
    if (re == null) return const [];
    final kindRule = re['kinds'] ?? re['ruleKinds'];
    if (kindRule == null) return const [];
    final titleRule = _mapGet(kindRule, 'kindTitle');
    final urlRule = _mapGet(kindRule, 'kindUrl');
    if (urlRule.trim().isEmpty) return const [];

    final out = <ExploreKind>[];
    try {
      final elements = await analyze.getElementsAsync(urlRule);
      if (elements.isEmpty) return const [];
      for (final el in elements) {
        final rawUrl = await analyze.getStringAsync(urlRule, mContent: el, isUrl: true);
        if (rawUrl.isEmpty) continue;
        var title = titleRule.trim().isNotEmpty
            ? await analyze.getStringAsync(titleRule, mContent: el)
            : '';
        if (title.isEmpty) {
          title = await analyze.getStringAsync(r'text', mContent: el);
        }
        if (title.isEmpty) continue;
        if (!out.any((k) => k.url == rawUrl)) {
          out.add(ExploreKind(title: title, url: rawUrl));
        }
      }
    } catch (_) {
      return const [];
    }
    return out;
  }

  static String _mapGet(Object? o, String key) {
    if (o is Map) {
      final v = o[key];
      return v?.toString() ?? '';
    }
    return '';
  }

  String? _firstExploreUrl(BookSource src) {
    for (final line in (src.exploreUrl ?? '').split('\n')) {
      final clean = line.trim();
      if (clean.isEmpty) continue;
      final hash = clean.indexOf('#');
      return hash > 0 ? clean.substring(0, hash).trim() : clean;
    }
    return null;
  }

  Future<List<SearchBook>> _parseExploreBooks(
    AnalyzeRule analyze,
    BookSource src,
    String baseUrl,
  ) async {
    final firstExplore =
        (src.ruleExplore != null && (src.ruleExplore ?? {}).isNotEmpty)
            ? src.ruleExplore
            : null;
    String ruleOf(String? mine, String? fallback) =>
        (mine != null && mine.trim().isNotEmpty) ? mine : (fallback ?? '');

    String listRule(String? fallback) {
      if (firstExplore == null) return fallback ?? '';
      final bl = firstExplore['bookList']?.toString();
      return (bl != null && bl.isNotEmpty) ? bl : (fallback ?? '');
    }

    final bookList = listRule(src.ruleSearch?.bookList);
    if (bookList.trim().isEmpty) return const [];
    final elements = await analyze.getElementsAsync(bookList);
    if (elements.isEmpty) return const [];

    final nameRule =
        ruleOf(firstExplore?['nameKey']?.toString(), src.ruleSearch?.name);
    final urlRule =
        ruleOf(firstExplore?['bookUrl']?.toString(), src.ruleSearch?.bookUrl);
    final authorRule =
        ruleOf(firstExplore?['authorKey']?.toString(), src.ruleSearch?.author);
    final coverRule =
        ruleOf(firstExplore?['coverUrl']?.toString(), src.ruleSearch?.coverUrl);
    final introRule =
        ruleOf(firstExplore?['descKey']?.toString(), src.ruleSearch?.intro);

    final out = <SearchBook>[];
    for (final el in elements) {
      final name = await analyze.getStringAsync(nameRule, mContent: el);
      if (name.isEmpty) continue;
      final bookUrl = await analyze.getStringAsync(urlRule, mContent: el, isUrl: true);
      if (bookUrl.isEmpty) continue;
      out.add(SearchBook(
        name: name,
        author: _nullIfEmpty(await analyze.getStringAsync(authorRule, mContent: el)),
        intro: _nullIfEmpty(await analyze.getStringAsync(introRule, mContent: el)),
        coverUrl: _nullIfEmpty(await analyze.getStringAsync(coverRule, mContent: el)),
        bookUrl: bookUrl,
        origin: src.bookSourceName,
        type: src.bookSourceType,
      ));
    }
    return out;
  }

  Future<Resp?> _safeGet(BookSource src, String url) async {
    try {
      final resp = await HttpService.instance.get(url, source: src);
      if (!resp.ok) return null;
      return resp;
    } catch (_) {
      return null;
    }
  }

  /// 公开的单源搜索（供书源校验器等复用）。
  Future<List<SearchBook>> searchSource(BookSource src, String keyword) =>
      _searchOne(src, keyword);

  /// 单个源搜索。
  Future<List<SearchBook>> _searchOne(BookSource src, String keyword) async {
    final raw = (src.searchUrl ?? '').trim();
    if (raw.isEmpty) return const [];

    final meta = _urlMeta(raw);
    final actionUrl = _stripMetaUrl(raw);
    // 相对路径基于书源根地址解析；绝对地址不受影响。
    final baseUri = Uri.tryParse(src.bookSourceUrl);
    final url = SearchService.replaceKey(actionUrl, keyword);
    if (url.isEmpty || baseUri == null) return const [];

    Resp? resp;
    try {
      if (meta != null &&
          (meta['method']?.toString().toUpperCase() ?? 'get') == 'POST') {
        final body = SearchService.replaceKey(meta['body']?.toString() ?? '', keyword);
        // 请求体已是百分号编码表单串（ASCII 安全），用默认 utf-8 编码发送即可，
        // 不能把 gbk 塞进请求头（Dart http 包对未知 charset 会直接抛错）。
        resp = await HttpService.instance.post(
          url,
          source: src,
          base: baseUri,
          bodyRaw: body,
          headers: {
            'Content-Type': 'application/x-www-form-urlencoded',
          },
        );
      } else {
        resp = await HttpService.instance.get(url, source: src, base: baseUri);
      }
      if (!resp.ok) return const [];
    } catch (_) {
      return const [];
    }

    try {
      final analyze = AnalyzeRule(source: src);
      analyze.setBaseUrl(resp.finalUrl?.toString() ?? url);
      analyze.setContent(_smartContent(resp));
      return await _parseSearch(analyze, src, keyword, resp.finalUrl?.toString() ?? url);
    } catch (_) {
      return const [];
    }
  }

  /// 取 searchUrl 尾部追加的 JSON 元信息（官方格式 `url,{...}` 或 `url\n{...}`）。
  ///
  /// 命中 `,{...}` / `\n{...}` 时解析其 method/body/charset；无则返回 null。
  static Map<String, dynamic>? _urlMeta(String raw) {
    final m = RegExp(r'[,\n]\s*(\{[\s\S]*\})\s*$').firstMatch(raw);
    if (m == null) return null;
    try {
      final v = jsonDecode(m.group(1)!);
      return v is Map ? Map<String, dynamic>.from(v) : null;
    } catch (_) {
      return null;
    }
  }

  /// 去掉尾部 `,{...}` / `\n{...}` 元信息，返回纯请求地址；无元信息则原样返回。
  static String _stripMetaUrl(String raw) {
    final m = RegExp(r'^(.*)[,\n]\{[\s\S]*\}\s*$').firstMatch(raw);
    return m?.group(1)?.trim() ?? raw.trim();
  }

  /// 解析搜索结果。
  Future<List<SearchBook>> _parseSearch(
    AnalyzeRule analyze,
    BookSource src,
    String keyword,
    String baseUrl,
  ) async {
    final rule = src.ruleSearch;
    final bookListRule = rule?.bookList;
    if (bookListRule == null || bookListRule.trim().isEmpty) return const [];

    final elements = await analyze.getElementsAsync(bookListRule);
    if (elements.isEmpty) return const [];

    final out = <SearchBook>[];
    for (final el in elements) {
      final name = await analyze.getStringAsync(rule?.name ?? '', mContent: el);
      if (name.isEmpty) continue;

      final bookUrl = await analyze.getStringAsync(rule?.bookUrl ?? '', mContent: el, isUrl: true);
      if (bookUrl.isEmpty) continue;

      out.add(SearchBook(
        name: name,
        author: _nullIfEmpty(await analyze.getStringAsync(rule?.author ?? '', mContent: el)),
        intro: _nullIfEmpty(await analyze.getStringAsync(rule?.intro ?? '', mContent: el)),
        coverUrl: _nullIfEmpty(await analyze.getStringAsync(rule?.coverUrl ?? '', mContent: el)),
        bookUrl: bookUrl,
        origin: src.bookSourceName,
        type: src.bookSourceType,
      ));
    }
    return out;
  }

  /// 把关键字替换进搜索 URL / POST body（官方占位：`{{key}}`、`{{searchKey}}`、`{key}`、`{searchKey}`）。
  static String replaceKey(String url, String keyword) {
    final enc = Uri.encodeComponent(keyword);
    return url
        .replaceAll('{{searchKey}}', enc)
        .replaceAll('{{key}}', enc)
        .replaceAll('{searchKey}', enc)
        .replaceAll('{key}', enc)
        .replaceAll(RegExp(r'\{key\|\{\{\w+\}\}\}'), '{{$keyword}}');
  }

  /// 内容适配：JSON 字符串转 Map，HTML 原样。
  Object? _smartContent(Resp resp) {
    final body = resp.body;
    final t = body.trim();
    if (t.startsWith('{') || t.startsWith('[')) {
      try {
        return jsonDecode(t);
      } catch (_) {
        return body;
      }
    }
    return body;
  }

  static String? _nullIfEmpty(String s) => s.trim().isEmpty ? null : s.trim();

  // ---------------------------------------------------------------------------
  // 结果聚合：跨源去重 + 按相关度排序（对齐官方 SearchViewModel）
  // ---------------------------------------------------------------------------

  /// 去重键：书名 + 作者（同名同作者视为同一本书）。
  static String dedupKey(SearchBook b) {
    final n = b.name.trim().toLowerCase();
    final a = (b.author ?? '').trim().toLowerCase();
    return '$n|$a';
  }

  /// 相关度打分（四档）：完全一致 > 前缀一致 > 含于书名 > 其它。
  static int relevance(SearchBook b, String keyword) {
    final n = b.name.trim();
    final kw = keyword.trim();
    if (n.isEmpty) return 0;
    if (n.toLowerCase() == kw.toLowerCase()) return 400;
    if (n.toLowerCase().startsWith(kw.toLowerCase())) return 300;
    if (n.toLowerCase().contains(kw.toLowerCase())) return 200;
    final a = (b.author ?? '').trim();
    if (a.isNotEmpty &&
        (a.toLowerCase().contains(kw.toLowerCase()) ||
            kw.toLowerCase().contains(a.toLowerCase()))) {
      return 150;
    }
    return 100;
  }

  /// 合并新一批结果：去重（同名同作者保留先到者）+ 按相关度降序重排。
  /// 先到源即高权重书源（已按 weight 排序），故去重时保留先者。
  static List<SearchBook> mergeResults(
    List<SearchBook> accumulator,
    List<SearchBook> incoming,
    String keyword,
  ) {
    final combined = [...accumulator, ...incoming];
    final seen = <String>{};
    final deduped = <SearchBook>[];
    for (final b in combined) {
      final k = dedupKey(b);
      if (k.isEmpty || seen.add(k)) deduped.add(b);
    }
    deduped.sort((a, b) {
      final d = relevance(b, keyword).compareTo(relevance(a, keyword));
      if (d != 0) return d;
      return a.name.compareTo(b.name);
    });
    return deduped;
  }
}