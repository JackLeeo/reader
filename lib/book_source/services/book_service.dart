import 'dart:convert';

import '../analyze/analyze_rule.dart';
import '../models/book_source.dart';
import '../models/books.dart';
import 'book_source_service.dart';
import 'http_service.dart';

/// 书籍详情 / 目录 / 正文服务（对应官方 `WebBook`）。
///
/// 阅读闭环的核心网络 + 解析层：
/// - [getBook]      由搜索书条目解析出 [Book]
/// - [getToc]       拉取目录页，解析出 [BookChapter]
/// - [getContent]   拉取章节正文，解析出 [BookContent]
class BookService {
  final Map<String, Resp> _detailCache = {};

  /// 解析书籍详情。
  Future<Book?> getBook(
    SearchBook flow, {
    BookSource? source,
    Object? initContentFrom,
  }) async {
    final src = source ?? _findSource(flow.origin);
    if (src == null) return null;
    final rule = src.ruleBookInfo;
    final detailUrl = flow.bookUrl.isEmpty ? src.searchUrl ?? '' : flow.bookUrl;

    Object? content;
    String baseUrl;
    Resp? resp;
    if (initContentFrom != null) {
      content = initContentFrom;
      baseUrl = detailUrl;
    } else {
      resp = await _fetchDetail(src, detailUrl);
      if (resp == null || !resp.ok) return null;
      content = _smartContent(resp);
      baseUrl = resp.finalUrl?.toString() ?? detailUrl;
    }

    final analyze = AnalyzeRule(source: src);
    analyze.setBaseUrl(baseUrl);
    analyze.setContent(content);

    return Book(
      name: await _firstAsync(analyze, rule?.name ?? '', flow.name),
      author: await _toStringOrNullAsync(analyze, rule?.author ?? '', flow.author),
      coverUrl: await _toStringOrNullAsync(analyze, rule?.coverUrl ?? '', flow.coverUrl),
      intro: await _toStringOrNullAsync(analyze, rule?.intro ?? '', flow.intro),
      tocUrl: await _toStringOrNullAsync(analyze, rule?.tocUrl ?? '', flow.bookUrl),
      bookUrl: flow.bookUrl,
      origin: src.bookSourceName,
      sourceTag: src.bookSourceUrl,
      type: src.bookSourceType,
    );
  }

  /// 拉取目录。失败返回空列表。
  Future<List<BookChapter>> getToc(
    Book book, {
    BookSource? source,
    Object? tocContent,
  }) async {
    final src = source ?? _findSource(book.origin);
    if (src == null) return const [];
    final rule = src.ruleToc;

    final tocUrl =
        (book.tocUrl == null || book.tocUrl!.isEmpty) ? book.bookUrl : book.tocUrl!;

    Object? content;
    String baseUrl;
    if (tocContent != null) {
      content = tocContent;
      baseUrl = book.bookUrl;
    } else {
      final resp = await HttpService.instance.get(tocUrl, source: src);
      if (!resp.ok) return const [];
      content = _smartContent(resp);
      baseUrl = resp.finalUrl?.toString() ?? tocUrl;
    }

    final analyze = AnalyzeRule(source: src);
    analyze.setBaseUrl(baseUrl);
    analyze.setContent(content);

    final elements = await analyze.getElementsAsync(rule?.chapterList ?? '');
    if (elements.isEmpty) return const [];

    final chapters = <BookChapter>[];
    for (final el in elements) {
      final title = await analyze.getStringAsync(rule?.chapterName ?? '', mContent: el);
      if (title.isEmpty) continue;
      final url =
          await analyze.getStringAsync(rule?.chapterUrl ?? '', mContent: el, isUrl: true);
      if (url.isEmpty) continue;
      // 消费官方 TocRule 的辅助字段：卷标记/会员/付费（元素级布尔规则）。
      chapters.add(BookChapter(
        title: title,
        url: url,
        isVolume: await _evalTruthyAsync(analyze, rule?.isVolume ?? '', el),
        isVip: await _evalTruthyAsync(analyze, rule?.isVip ?? '', el),
        isPay: await _evalTruthyAsync(analyze, rule?.isPay ?? '', el),
      ));
    }
    return chapters;
  }

  /// 元素级布尔规则求值：`true/1/yes` 视为真，空规则视为假（对齐官方 TruthyUtil）。
  Future<bool> _evalTruthyAsync(AnalyzeRule analyze, String rule, Object? el) async {
    if (rule.trim().isEmpty) return false;
    final v = (await analyze.getStringAsync(rule, mContent: el)).trim().toLowerCase();
    if (v.isEmpty) return false;
    return !(v == 'false' || v == '0' || v == 'no' || v == 'null');
  }

  /// 正文级替换规则：把 `replaceRegex` 按行 + `##` 拆成 `原##新` 对并全局替换。
  ///
  /// `原` 优先当正则；编译失败退回字面替换。分隔支持换行或分号。
  String _applyContentReplace(String body, String replaceRegex) {
    if (body.isEmpty) return body;
    var out = body;
    final segments = replaceRegex
        .toString()
        .split(RegExp(r'[\n;]'))
        .map((s) => s.trim())
        .where((s) => s.contains('##'))
        .toList();
    for (final seg in segments) {
      final i = seg.indexOf('##');
      final a = seg.substring(0, i);
      final b = seg.substring(i + 2);
      if (a.isEmpty) continue;
      try {
        out = out.replaceAll(RegExp(a), b);
      } catch (_) {
        out = out.replaceAll(a, b);
      }
    }
    return out;
  }

  /// 拉取章节正文。
  Future<BookContent> getContent(
    BookChapter chapter,
    Book book, {
    BookSource? source,
  }) async {
    final src = source ?? _findSource(book.origin);
    if (src == null) {
      return BookContent(
        succeed: false,
        msg: '未找到书源：${book.origin}',
        sourceUrl: book.sourceTag,
      );
    }
    final rule = src.ruleContent;
    final contentRule = rule?.content ?? '';
    if (contentRule.isEmpty) {
      return BookContent(
        succeed: false,
        msg: '书源未配置正文规则',
        sourceUrl: book.sourceTag,
      );
    }

    final resp = await HttpService.instance.get(chapter.url, source: src);
    final analyze = AnalyzeRule(source: src);
    analyze.setBaseUrl(resp.finalUrl?.toString() ?? chapter.url);
    analyze.setContent(_smartContent(resp));

    var body = await analyze.getStringAsync(contentRule);
    if (body.trim().isEmpty) {
      body = await _fallbackContentAsync(analyze);
    }
    // 副文规则：拼接在正文后面（对齐官方 ContentRule.subContent）。
    final subRule = rule?.subContent?.trim() ?? '';
    if (subRule.isNotEmpty) {
      final sub = await analyze.getStringAsync(subRule);
      if (sub.trim().isNotEmpty) {
        body = body.trim().isEmpty ? sub : '$body\n\n$sub';
      }
    }
    // 正文级替换（对齐官方 ContentRule.replaceRegex：按行/分号拆成 A##B 对）。
    final contentReplace = rule?.replaceRegex?.trim() ?? '';
    if (contentReplace.isNotEmpty) body = _applyContentReplace(body, contentReplace);

    final title = await analyze.getStringAsync(rule?.title ?? '');
    final nextUrl = await analyze.getStringAsync(rule?.nextContentUrl ?? '', isUrl: true);

    return BookContent(
      body: body.trim(),
      title: title.isEmpty ? chapter.title : title,
      sourceUrl: chapter.url,
      nextUrl: nextUrl.isEmpty ? null : nextUrl,
      succeed: body.trim().isNotEmpty,
      msg: body.trim().isEmpty ? '正文解析为空' : '',
    );
  }

  /// 拉取媒体源（图片/漫画/听书）章节内容，返回素材 URL 列表。
  ///
  /// 图片源返回章节内全部图片（`ruleContent.content` 用 `getStringList` 提取
  /// 并归一化为绝对 URL）；听书源返回音频流地址。非媒体/未配置正文规则返回空。
  Future<List<String>> getContentList(
    BookChapter chapter,
    Book book, {
    BookSource? source,
  }) async {
    final src = source ?? _findSource(book.origin);
    if (src == null) return const [];
    // 仅为媒体源走此路径（文本正文由 getContent 处理）。
    if (src.isTextSource) return const [];
    final contentRule = src.ruleContent?.content ?? '';
    if (contentRule.trim().isEmpty) return const [];

    final resp = await HttpService.instance.get(chapter.url, source: src);
    final analyze = AnalyzeRule(source: src);
    analyze.setBaseUrl(resp.finalUrl?.toString() ?? chapter.url);
    analyze.setContent(_smartContent(resp));

    final urls = await analyze.getStringListAsync(contentRule, isUrl: true);
    if (urls == null || urls.isEmpty) return const [];
    // 去重并剔除空项。
    final seen = <String>{};
    return [
      for (final u in urls)
        if (u.trim().isNotEmpty && seen.add(u.trim())) u.trim(),
    ];
  }

  // ------------------------------------------------------------------
  // 私有辅助
  // ------------------------------------------------------------------

  BookSource? _findSource(String origin) {
    for (final s in BookSourceService.instance.sources) {
      if (s.bookSourceName == origin || s.bookSourceUrl == origin) return s;
    }
    return null;
  }

  Future<Resp?> _fetchDetail(BookSource src, String url) {
    final hit = _detailCache[url];
    if (hit != null) return Future.value(hit);
    return HttpService.instance
        .get(url, source: src)
        .then<Resp?>((r) {
          if (r.ok) _detailCache[url] = r;
          return r;
        })
        .catchError((Object _) => null);
  }

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

  /// 正文命空时的常见正文容器 fallback。
  Future<String> _fallbackContentAsync(AnalyzeRule analyze) async {
    const containers = [
      '#content', '#chaptercontent', '.read-content', '#content1',
      '.content', '.chapter-content', '#chapterContent', '.txt',
      '.book-body', '#book_text', '.content-box', '.text',
      '.article-content',
    ];
    String best = '';
    for (final c in containers) {
      try {
        final s = await analyze.getStringAsync(c, unescape: true);
        if (s.length > 200 && s.length > best.length) best = s.trim();
      } catch (_) {
        continue;
      }
    }
    return best;
  }

  Future<String> _firstAsync(AnalyzeRule analyze, String rule, String fallback) async {
    final s = await analyze.getStringAsync(rule);
    return s.trim().isEmpty ? fallback : s.trim();
  }

  Future<String?> _toStringOrNullAsync(AnalyzeRule a, String rule, Object? fallback) async {
    final s = await a.getStringAsync(rule);
    if (s.trim().isEmpty) {
      if (fallback == null) return null;
      return fallback.toString().trim();
    }
    return s.trim();
  }
}