import 'dart:convert';
import 'dart:math';

import '../analyze/analyze_rule.dart';
import '../models/book_source.dart';
import '../models/books.dart';
import 'book_source_service.dart';
import 'http_service.dart';
import 'search_service.dart';

/// 换源服务（对应官方“换源”核心）。
///
/// 在全部启用的书源中，按“书名（+作者 可选 + 当前书源）”查找同名书籍，
/// 供读者切换阅读源使用。返回 [SearchBook] 列表（含来源标注），
/// 由 UI 呈现供用户选择，选后跳转对应详情/正文。
class SwitchSourceService {
  const SwitchSourceService();

  /// 跨所有启用源搜索同名书籍。
  ///
  /// [book] 提供书名/作者；[excludeOrigin] 为当前书源名（可空）。
  /// 返回按书名相关度排序的候选。
  Future<List<SearchBook>> findSameBook(
    Book book, {
    String? excludeOrigin,
  }) async {
    if (book.name.trim().isEmpty) return const [];

    final sources = BookSourceService.instance.enabledSources
        .where((s) => s.searchUrl != null && s.searchUrl!.isNotEmpty)
        .where((s) => excludeOrigin == null || s.bookSourceName != excludeOrigin)
        .toList();

    final hits = <SearchBook>[];
    for (final src in sources) {
      final results = await _searchOne(src, book.name);
      for (final r in results) {
        if (_isSameBook(r, book)) {
          hits.add(r);
        }
      }
    }
    _sortHits(hits, book);
    return hits;
  }

  /// 随机换源：从全部启用源中随机抽取一个源搜索同名书，
  /// 命中则直接返回（不排序，达到“碰运气换源”效果）。
  ///
  /// [excludeOrigin] 排除当前书源。[shuffle] 为 true 时随机打乱源顺序，
  /// 保证连续点击也得到不同结果。返回命中的 [SearchBook]，失败返回 null。
  Future<SearchBook?> randomSource(
    Book book, {
    String? excludeOrigin,
  }) async {
    if (book.name.trim().isEmpty) return null;

    final sources = BookSourceService.instance.enabledSources
        .where((s) => s.searchUrl != null && s.searchUrl!.isNotEmpty)
        .where((s) => excludeOrigin == null || s.bookSourceName != excludeOrigin)
        .toList();
    if (sources.isEmpty) return null;

    sources.shuffle(Random());
    for (final src in sources) {
      final results = await _searchOne(src, book.name);
      for (final r in results) {
        if (_isSameBook(r, book)) {
          return r;
        }
      }
    }
    return null;
  }

  bool _isSameBook(SearchBook candidate, Book book) {
    if (candidate.name.trim().isEmpty) return false;
    // 书名完全一致最优先；含书名次之（兼容站点少字/多字）
    final cn = candidate.name.trim();
    final b = book.name.trim();
    if (cn == b) return true;
    if (cn.contains(b) || b.contains(cn)) return true;
    // 作者一致可作为强信号（书名模糊匹配时）
    if (book.author != null &&
        book.author!.trim().isNotEmpty &&
        candidate.author != null) {
      final ca = candidate.author!.trim();
      final ba = book.author!.trim();
      if ((ca == ba || ca.contains(ba) || ba.contains(ca)) &&
          (cn.contains(b.substring(0, 1)) || b.contains(cn.substring(0, 1)))) {
        return true;
      }
    }
    return false;
  }

  /// 按匹配强度排序：书名完全一致 >= 作者一致 >= 仅包含。
  void _sortHits(List<SearchBook> hits, Book book) {
    int score(SearchBook s) {
      final cn = s.name.trim();
      final b = book.name.trim();
      var sc = 0;
      if (cn == b) {
        sc += 100;
      } else if (cn.contains(b) || b.contains(cn)) {
        sc += 50;
      }
      if (s.author != null &&
          book.author != null &&
          s.author!.trim() == book.author!.trim()) {
        sc += 20;
      }
      return sc;
    }

    hits.sort((a, c) => score(c).compareTo(score(a)));
  }

  Future<List<SearchBook>> _searchOne(BookSource src, String keyword) async {
    final searchUrl = SearchService.replaceKey((src.searchUrl ?? '').trim(), keyword);
    if (searchUrl.isEmpty) return const [];
    try {
      final resp = await HttpService.instance.get(searchUrl, source: src);
      if (!resp.ok) return const [];

      final analyze = AnalyzeRule(source: src);
      analyze.setBaseUrl(resp.finalUrl?.toString() ?? searchUrl);
      analyze.setContent(_smartContent(resp));

      return await _parseSearch(analyze, src, resp.finalUrl?.toString() ?? searchUrl);
    } catch (_) {
      return const [];
    }
  }

  Future<List<SearchBook>> _parseSearch(AnalyzeRule analyze, BookSource src, String baseUrl) async {
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
        author: _nn(await analyze.getStringAsync(rule?.author ?? '', mContent: el)),
        coverUrl: _nn(await analyze.getStringAsync(rule?.coverUrl ?? '', mContent: el)),
        intro: _nn(await analyze.getStringAsync(rule?.intro ?? '', mContent: el)),
        bookUrl: bookUrl,
        origin: src.bookSourceName,
        type: src.bookSourceType,
      ));
    }
    return out;
  }

  static String? _nn(String s) => s.trim().isEmpty ? null : s.trim();

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
}