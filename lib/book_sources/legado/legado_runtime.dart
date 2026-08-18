import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/dom.dart' show Element;

import '../../core/reader/chapter_heading_library.dart';
import '../../services/core/source_diagnostic_logger.dart';
import '../models/registered_book_source.dart';
import '../protocol/book_source_protocol.dart';
import 'legado_book_source.dart';
import 'legado_js_engine.dart';
import 'legado_request.dart';
import 'legado_rule_engine.dart';
import 'legado_variable_store.dart';

class LegadoRuntime {
  LegadoRuntime({LegadoTransport? transport})
    : _transport = transport ?? LegadoHttpTransport();

  static const int _maxSearchItems = 100;
  static const int _maxChapters = 30000;
  static const int _maxPageHops = 20;

  final LegadoTransport _transport;
  final LegadoRuleEngine _rules = const LegadoRuleEngine();

  /// 诊断日志快捷方法。
  void _log(
    LegadoBookSource source,
    SourceDiagOp op,
    SourceDiagLevel level,
    String message, {
    String? details,
  }) {
    SourceDiagnosticLogger.instance.log(
      sourceId: source.stableId,
      sourceName: source.name,
      op: op,
      level: level,
      message: message,
      details: details,
    );
  }

  /// 详情页响应短期缓存：getBook 与 getChapters(_tocUrl) 共享，
  /// 避免同一 bookId 在一次阅读流程里被请求两次。
  /// 带一次性 token / 防重放的站点第二次请求会 404，这是
  /// "详情能看到、目录拉不到"的主因（对照 yuedu_hd 只请求一次）。
  static const Duration _detailCacheTtl = Duration(seconds: 90);
  static const int _detailCacheCapacity = 8;
  final Map<String, _CachedDetailPage> _detailCache = {};

  void close({bool force = true}) {
    final transport = _transport;
    if (transport is LegadoHttpTransport) transport.close(force: force);
  }

  Future<BookSourceSearchPage> search(
    RegisteredBookSource registered,
    String query, {
    int page = 1,
    int pageSize = 20,
  }) async {
    final source = _source(registered);
    await _ensureSearchRunnable(source);
    final vars = _jsVariables(source, {'key': query.trim(), 'page': '$page'});
    try {
      final response = await _request(
        source,
        source.searchUrl,
        variables: {'key': query.trim(), 'page': '$page'},
      );
      final document = LegadoRuleDocument.parse(
        response.body,
        response.finalUri,
      );
      final rule = source.rule('ruleSearch');
      final contexts = await _rules.evaluateList(
        document,
        null,
        _requiredRule(rule, 'bookList'),
        jsVariables: vars,
        sourceUrl: source.url,
      );
      final books = <BookSourceBook>[];
      for (final context in contexts.take(_maxSearchItems)) {
        final book = await _bookFromRules(
          document,
          context,
          rule,
          vars: vars,
          sourceUrl: source.url,
        );
        if (book != null) books.add(book);
      }
      _log(
        source,
        SourceDiagOp.search,
        books.isEmpty ? SourceDiagLevel.warn : SourceDiagLevel.info,
        'search("$query") page=$page → ${books.length} books '
        '(ruleHits=${contexts.length})',
        details: books.isEmpty
            ? 'searchUrl=${source.searchUrl}\n'
                  'finalUri=${response.finalUri}\n'
                  'bodySnippet=${response.body.length > 200 ? '${response.body.substring(0, 200)}...' : response.body}'
            : null,
      );
      return BookSourceSearchPage(
        items: books.take(pageSize).toList(growable: false),
        page: page,
        pageSize: pageSize,
        hasMore: books.length > pageSize,
      );
    } on BookSourceProtocolException catch (e) {
      _log(
        source,
        SourceDiagOp.search,
        SourceDiagLevel.error,
        'search("$query") failed: ${e.message}',
      );
      rethrow;
    } on Object catch (e) {
      _log(
        source,
        SourceDiagOp.search,
        SourceDiagLevel.error,
        'search("$query") unexpected error: $e',
      );
      rethrow;
    }
  }

  /// 发现页聚合入口：取源的第一个发现分类作为推荐书架。
  static const int _maxExploreEntriesPerSource = 20;

  Future<BookSourceDiscoveryPage> getDiscovery(
    RegisteredBookSource registered,
  ) async {
    final source = _source(registered);
    final entries = source.exploreEntries;
    if (entries.isEmpty) {
      throw const BookSourceProtocolException(
        'This source does not support discovery.',
      );
    }
    final entry = entries.first;
    final page = await _explorePage(source, entry.url);
    return BookSourceDiscoveryPage(
      sections: [
        BookSourceDiscoverySection(
          id: entry.url,
          title: entry.title.isEmpty ? source.name : entry.title,
          items: page.items,
        ),
      ],
    );
  }

  /// 分类 = 发现入口列表（无需网络请求）。
  Future<List<BookSourceCategory>> getCategories(
    RegisteredBookSource registered,
  ) async {
    final source = _source(registered);
    final entries = source.exploreEntries;
    if (entries.isEmpty) {
      throw const BookSourceProtocolException(
        'This source does not support categories.',
      );
    }
    return entries
        .take(_maxExploreEntriesPerSource)
        .map((entry) {
          return BookSourceCategory(
            id: entry.url,
            name: entry.title.isEmpty ? entry.url : entry.title,
          );
        })
        .toList(growable: false);
  }

  /// 浏览：按发现入口地址拉取书籍列表。
  Future<BookSourceSearchPage> browse(
    RegisteredBookSource registered, {
    String? category,
    int page = 1,
    int pageSize = 20,
  }) async {
    final source = _source(registered);
    final entries = source.exploreEntries;
    if (entries.isEmpty) {
      throw const BookSourceProtocolException(
        'This source does not support browsing.',
      );
    }
    final target = category != null && category.trim().isNotEmpty
        ? category.trim()
        : entries.first.url;
    return _explorePage(source, target, page: page, pageSize: pageSize);
  }

  Future<BookSourceSearchPage> _explorePage(
    LegadoBookSource source,
    String url, {
    int page = 1,
    int pageSize = 20,
  }) async {
    final report = const LegadoCompatibilityScanner().scan(source);
    if (!report.canRun) {
      throw const BookSourceProtocolException(
        'This compatible source uses features that are not supported yet.',
      );
    }
    final vars = _jsVariables(source, {'page': '$page'});
    final response = await _request(source, url, variables: {'page': '$page'});
    final document = LegadoRuleDocument.parse(response.body, response.finalUri);
    // Legado 发现页规则是 ruleExplore，未声明时回退 ruleSearch。
    var rule = source.rule('ruleExplore');
    if (rule.isEmpty) rule = source.rule('ruleSearch');
    final contexts = await _rules.evaluateList(
      document,
      null,
      _requiredRule(rule, 'bookList'),
      jsVariables: vars,
      sourceUrl: source.url,
    );
    final books = <BookSourceBook>[];
    for (final context in contexts.take(_maxSearchItems)) {
      final book = await _bookFromRules(
        document,
        context,
        rule,
        vars: vars,
        sourceUrl: source.url,
      );
      if (book != null) books.add(book);
    }
    return BookSourceSearchPage(
      items: books.take(pageSize).toList(growable: false),
      page: page,
      pageSize: pageSize,
      hasMore: books.length > pageSize,
    );
  }

  Future<BookSourceBook> getBook(
    RegisteredBookSource registered,
    String bookId,
  ) async {
    final source = _source(registered);
    await _ensureRunnable(source);
    final vars = _jsVariables(source);
    try {
      // 详情页优先读短期缓存：详情页 UI 已抓过一次的场景（点击进阅读）
      // 不能再次真实请求——一次性 token / 防盗链站点第二次会 403/404。
      final cached = _cachedDetailPage(bookId);
      final response = cached ?? await _request(source, bookId);
      if (cached == null) {
        _cacheDetailPage(bookId, response);
      }
      final document = LegadoRuleDocument.parse(
        response.body,
        response.finalUri,
      );
      final rule = source.rule('ruleBookInfo');
      final init = _optionalRule(rule, 'init');
      final context = init.isEmpty
          ? null
          : (await _rules.evaluateList(
              document,
              null,
              init,
              jsVariables: vars,
              sourceUrl: source.url,
            )).firstOrNull;
      final title = await _value(
        document,
        context,
        rule,
        'name',
        jsVariables: vars,
        sourceUrl: source.url,
      );
      if (title.isEmpty) {
        _log(
          source,
          SourceDiagOp.detail,
          SourceDiagLevel.error,
          'getBook(bookId=$bookId) → title is empty',
          details: 'finalUri=${response.finalUri}\n'
              'ruleBookInfo.init=${init.isEmpty ? '(missing)' : init}\n'
              'ruleBookInfo.name=${_optionalRule(rule, 'name')}',
        );
        throw const BookSourceProtocolException(
          'Compatible source did not return a book title.',
        );
      }
      final book = BookSourceBook(
        id: response.finalUri.toString(),
        title: title,
        author: await _value(
          document,
          context,
          rule,
          'author',
          jsVariables: vars,
          sourceUrl: source.url,
        ),
        description: await _value(
          document,
          context,
          rule,
          'intro',
          jsVariables: vars,
          sourceUrl: source.url,
        ),
        coverUrl: await _uriValue(
          document,
          context,
          rule,
          'coverUrl',
          vars: vars,
          sourceUrl: source.url,
        ),
        categories: _splitCategories(
          await _value(
            document,
            context,
            rule,
            'kind',
            jsVariables: vars,
            sourceUrl: source.url,
          ),
        ),
        status: _nullable(
          await _value(
            document,
            context,
            rule,
            'status',
            jsVariables: vars,
            sourceUrl: source.url,
          ),
        ),
        latestChapter: _nullable(
          await _value(
            document,
            context,
            rule,
            'lastChapter',
            jsVariables: vars,
            sourceUrl: source.url,
          ),
        ),
      );
      _log(
        source,
        SourceDiagOp.detail,
        SourceDiagLevel.info,
        'getBook(bookId=$bookId) → title="${book.title}" author="${book.author}"',
        details: 'finalUri=${response.finalUri}\ncached=$cached',
      );
      return book;
    } on BookSourceProtocolException {
      rethrow;
    } on Object catch (e) {
      _log(
        source,
        SourceDiagOp.detail,
        SourceDiagLevel.error,
        'getBook(bookId=$bookId) unexpected error: $e',
      );
      rethrow;
    }
  }

  Future<List<BookSourceChapter>> getChapters(
    RegisteredBookSource registered,
    String bookId,
  ) async {
    final source = _source(registered);
    await _ensureRunnable(source);
    final vars = _jsVariables(source);
    final tocUrl = await _tocUrl(source, bookId);
    final attempts = <String>[];
    var chapters = const <BookSourceChapter>[];

    // 第一轮：tocRule 求值出的目录地址（可能是派生的独立目录页）。
    try {
      chapters = await _fetchChapterPages(
        source,
        tocUrl,
        vars,
        referer: bookId,
        onDiagnostics: (d) {
          attempts.add(
            'tocUrl=$tocUrl requestOk=${d.httpOk} chapterHits=${d.chapterListHits} '
            'validChapters=${d.validChapters}',
          );
        },
      );
    } on BookSourceProtocolException catch (e) {
      if (tocUrl == bookId) {
        _log(
          source,
          SourceDiagOp.chapters,
          SourceDiagLevel.error,
          'getChapters(bookId=$bookId) failed: ${e.message}',
          details: 'tocUrl=$tocUrl (same as bookId)\n'
              'attempts=${attempts.join(" | ")}',
        );
        rethrow;
      }
      attempts.add('tocUrl attempt failed: ${e.message}');
    }

    // 第一轮回退：当 tocUrl 求值为详情页或站点根且第一轮没拿到章节时，
    // 按常见 PHP/Java SSR 模板推导目录页 URL（连尚读书 lsds.cn /bookinfo/xxx
    // → /book/xxx、群小说网 /xiaoshuo_xxx.html → /xiaoshuo/xxx/ 等）。
    // 比直接退详情页更"轻"：只需少量 HEAD/GET 试探，成功率却高得多。
    if (chapters.isEmpty) {
      final guesses = _guessTocUrls(bookId, tocUrl);
      for (final guess in guesses) {
        _log(
          source,
          SourceDiagOp.chapters,
          SourceDiagLevel.info,
          'guessing TOC URL: $guess (from bookId=$bookId tocUrl=$tocUrl)',
        );
        try {
          final guessed = await _fetchChapterPages(
            source,
            guess,
            vars,
            referer: bookId,
            onDiagnostics: (d) {
              attempts.add(
                'guessedToc=$guess requestOk=${d.httpOk} '
                'chapterHits=${d.chapterListHits} validChapters=${d.validChapters}',
              );
            },
          );
          if (guessed.isNotEmpty) {
            chapters = guessed;
            break;
          }
        } on BookSourceProtocolException catch (e) {
          attempts.add('guessedToc=$guess failed: ${e.message}');
        }
      }
    }

    // 第二轮回退：当 tocUrl 不是详情页时，直接用书籍详情页再解析一次。
    if (chapters.isEmpty && tocUrl != bookId) {
      _log(
        source,
        SourceDiagOp.chapters,
        SourceDiagLevel.warn,
        'getChapters: first attempt empty, falling back to detail page',
        details: 'tocUrl=$tocUrl → fallback to bookId=$bookId',
      );
      try {
        chapters = await _fetchChapterPages(
          source,
          bookId,
          vars,
          referer: bookId,
          onDiagnostics: (d) {
            attempts.add(
              'fallback=detailPage bookId=$bookId requestOk=${d.httpOk} '
              'chapterHits=${d.chapterListHits} validChapters=${d.validChapters}',
            );
          },
        );
      } on BookSourceProtocolException catch (e) {
        attempts.add('detailPage fallback failed: ${e.message}');
      }
    }

    if (chapters.isEmpty) {
      final rule = source.rule('ruleToc');
      final chapterListRule = _optionalRule(rule, 'chapterList');
      final chapterNameRule = _optionalRule(rule, 'chapterName');
      final chapterUrlRule = _optionalRule(rule, 'chapterUrl');
      final diagnostic = attempts.isEmpty ? '(no attempts made)' : attempts.join(' | ');
      // 把详情页/目录页的 HTML 特征(前1500字符+DOM id/class 汇总)记录到诊断日志,
      // 便于事后判断是规则不匹配还是页面结构完全不同。
      var domSnippet = '';
      try {
        final cached = _cachedDetailPage(bookId);
        final body = cached?.body ?? '';
        if (body.isNotEmpty) {
          final snippet = body.length > 1500
              ? '${body.substring(0, 1500)}...[truncated ${body.length}]'
              : body;
          final signals = _extractDomSignals(body);
          domSnippet = '\npage snippet: $snippet\npage dom signals: $signals';
        }
      } on Object {
        domSnippet = '\n(page capture failed)';
      }
      _log(
        source,
        SourceDiagOp.chapters,
        SourceDiagLevel.error,
        'getChapters(bookId=$bookId) → 0 chapters after all attempts',
        details: 'tocUrl=$tocUrl\n'
            'chapterListRule=${chapterListRule.isEmpty ? "(missing)" : chapterListRule}\n'
            'chapterNameRule=${chapterNameRule.isEmpty ? "(missing)" : chapterNameRule}\n'
            'chapterUrlRule=${chapterUrlRule.isEmpty ? "(missing)" : chapterUrlRule}\n'
            'attempts=$diagnostic$domSnippet',
      );
      throw BookSourceProtocolException(
        'Compatible source did not return any chapters.\n'
        'Source: ${source.name} (${source.url})\n'
        'tocUrl evaluated: $tocUrl\n'
        'bookId (detail page): $bookId\n'
        'chapterList rule: ${chapterListRule.isEmpty ? '(missing)' : chapterListRule}\n'
        'chapterName rule: ${chapterNameRule.isEmpty ? '(missing)' : chapterNameRule}\n'
        'chapterUrl rule: ${chapterUrlRule.isEmpty ? '(missing)' : chapterUrlRule}\n'
        'Attempts: $diagnostic',
      );
    }
    _log(
      source,
      SourceDiagOp.chapters,
      SourceDiagLevel.info,
      'getChapters(bookId=$bookId) → ${chapters.length} chapters',
      details: 'tocUrl=$tocUrl\nattempts=${attempts.join(" | ")}',
    );
    return chapters;
  }

  /// 从 [startUrl] 开始按 nextTocUrl 翻页抓取章节列表。
  Future<List<BookSourceChapter>> _fetchChapterPages(
    LegadoBookSource source,
    String startUrl,
    Map<String, Object?> vars, {
    String? referer,
    void Function(_ChapterPageDiagnostics d)? onDiagnostics,
  }) async {
    final rule = source.rule('ruleToc');
    final chapters = <BookSourceChapter>[];
    final seenPages = <String>{};
    final seenChapters = <String>{};
    // 队列式分页：nextTocUrl 支持逗号多值（对照 yuedu_hd split(',')），
    // 一页可同时派生多个后续页（数字目录/多线路分页源）。
    final pendingPages = <String>[startUrl];
    // 翻页链路的 Referer 逐页前移：后续页的来源是前一页。
    var pageReferer = referer;
    var httpOk = false;
    var chapterListHits = 0;
    // 启用 heading fallback 的"累计统计"：在循环结束后统一判定一次，
    // 如果规则结果实在太差，把各页里用 heading 正则挑出的链接合并进来。
    final fallbackPool = <_FallbackChapterCandidate>[];
    for (var hop = 0; hop < _maxPageHops && pendingPages.isNotEmpty; hop++) {
      final pageUrl = pendingPages.removeAt(0);
      if (pageUrl.isEmpty || !seenPages.add(pageUrl)) continue;
      final LegadoResponse response;
      try {
        // 详情页零二次请求：tocUrl 求值回退/本身就是详情页时，
        // 必须复用缓存而不是再次真实请求（防重放站点 403/404）。
        response =
            _cachedDetailPage(pageUrl) ??
            await _request(source, pageUrl, referer: pageReferer);
        httpOk = true;
      } on BookSourceProtocolException catch (error) {
        // 后续分页 404/断连视为自然结束，保留已抓章节（yuedu_hd 行为）。
        if (hop > 0 && _isPaginationEndError(error)) break;
        onDiagnostics?.call(
          _ChapterPageDiagnostics(
            httpOk: false,
            chapterListHits: chapterListHits,
            validChapters: chapters.length,
          ),
        );
        rethrow;
      }
      pageReferer = response.finalUri.toString();
      final document = LegadoRuleDocument.parse(
        response.body,
        response.finalUri,
      );
      List<Object?> contexts;
      try {
        contexts = await _rules.evaluateList(
          document,
          null,
          _requiredRule(rule, 'chapterList'),
          jsVariables: vars,
          sourceUrl: source.url,
        );
      } on Object {
        contexts = const [];
      }
      chapterListHits += contexts.length;
      final chapterUrlRule = _optionalRule(rule, 'chapterUrl');
      for (final context in contexts) {
        final title = await _value(
          document,
          context,
          rule,
          'chapterName',
          jsVariables: vars,
          sourceUrl: source.url,
        );
        var url = '';
        if (chapterUrlRule.isNotEmpty) {
          url = await _url(
            document,
            context,
            rule,
            'chapterUrl',
            jsVariables: vars,
            sourceUrl: source.url,
          );
        }
        // chapterUrl 规则缺失时的多级回退：
        // 1. 如果 context 是 Element 且自己有 href → 直接用
        // 2. 否则在 context 内部找第一个带 href 的 <a> 标签
        if (url.isEmpty && context is Element) {
          final selfHref = context.attributes['href'];
          if (selfHref != null && selfHref.isNotEmpty) {
            final resolved = document.baseUri.resolve(selfHref);
            if (resolved.scheme == 'http' || resolved.scheme == 'https') {
              url = resolved.toString();
            }
          }
          if (url.isEmpty) {
            final firstAnchor =
                context.querySelectorAll('a[href]').where((a) {
              final h = a.attributes['href'];
              return h != null && h.isNotEmpty;
            }).firstOrNull;
            if (firstAnchor != null) {
              final href = firstAnchor.attributes['href']!;
              final resolved = document.baseUri.resolve(href);
              if (resolved.scheme == 'http' || resolved.scheme == 'https') {
                url = resolved.toString();
              }
            }
          }
        }
        // chapterUrl 最终兜底：url 仍为空时用当前页 URL 作为章节 URL
        // （对照 pusidun/legado BookChapterList:232 `bookChapter.url = baseUrl`）。
        // 这处理 chapterUrl 规则完全不存在且 context 无 <a> 的场景——
        // 这种源章节内容就挂在目录页本身，用目录页 URL 去取内容即可。
        if (url.isEmpty) {
          url = response.finalUri.toString();
        }
        if (title.isEmpty || !seenChapters.add(url)) continue;
        if (chapters.length >= _maxChapters) {
          throw const BookSourceProtocolException(
            'Compatible source chapter catalog exceeds the supported limit.',
          );
        }
        chapters.add(
          BookSourceChapter(id: url, title: title, order: chapters.length),
        );
      }

      // 为 heading fallback 收集候选：同一页里的 <a> 节点（带 href + 文本）。
      //
      // 注意：这里直接用 DOM API (`querySelectorAll('a[href]')`) 而不是
      // 走规则引擎 evaluateList('@css:a[href]') — 后者在 Nuxt SSR / 老站
      // 不标准 HTML 上经常只抓到 1~4 条 anchor（例如连尚读书 lsds.cn、
      // 群小说网 qunxs.com），导致 heading fallback 因池太小直接退出。
      try {
        final allAnchors = document.querySelectorAll('a[href]');
        for (final a in allAnchors) {
          final href = a.attributes['href'];
          if (href == null || href.isEmpty) continue;
          final resolved = document.baseUri.resolve(href);
          if (resolved.scheme != 'http' && resolved.scheme != 'https') continue;
          final url = resolved.toString();
          var text = (a.text).trim();
          if (text.isEmpty) text = a.attributes['title'] ?? '';
          if (text.isEmpty || text.length > 120) continue;
          fallbackPool.add(
            _FallbackChapterCandidate(
              title: text,
              url: url,
              pageDepth: hop,
            ),
          );
        }
      } on Object {
        // 收集失败是允许的：走不到 fallback 就当没这事儿。
      }

      final nextRule = _optionalRule(rule, 'nextTocUrl');
      if (nextRule.isEmpty) continue;
      final nextRaw = await _rules.evaluateString(
        document,
        null,
        nextRule,
        jsVariables: vars,
        sourceUrl: source.url,
      );
      for (final candidate in nextRaw.split(',')) {
        final trimmed = candidate.trim();
        if (trimmed.isEmpty || trimmed == '-') continue;
        final resolved = response.finalUri.resolve(trimmed);
        if (resolved.scheme != 'http' && resolved.scheme != 'https') continue;
        if (seenPages.contains(resolved.toString())) continue;
        pendingPages.add(resolved.toString());
      }
    }

    // ------- Heading Library fallback -------
    // 当规则匹配数量低、或者"匹配了一堆但有效章节极少"（典型是抓到了
    // 首页/排行/导航等非章链接）时，用章节标题正则在 <a> 池里重筛。
    var headingTriggeredFallback = false;
    if (shouldTryHeadingFallback(
      chapterListHits: chapterListHits,
      validChapters: chapters.length,
    )) {
      headingTriggeredFallback = true;
      _log(
        source,
        SourceDiagOp.fallback,
        SourceDiagLevel.warn,
        'heading fallback triggered: chapterListHits=$chapterListHits '
        'validChapters=${chapters.length} anchorPool=${fallbackPool.length}',
        details: 'startUrl=$startUrl',
      );
      final filtered = ChapterHeadingLibrary.filter(
        fallbackPool,
        titleOf: (c) => c.title,
      );
      final rebuilt = <BookSourceChapter>[];
      for (final c in filtered) {
        if (!seenChapters.add(c.url)) continue;
        if (rebuilt.length >= _maxChapters) break;
        rebuilt.add(
          BookSourceChapter(id: c.url, title: c.title, order: rebuilt.length),
        );
      }
      // 只在 fallback 至少产出 3 条时才替换规则结果 —— 避免误触发
      // 把规则命中的正确结果盖掉。
      if (rebuilt.length >= 3 && rebuilt.length > chapters.length) {
        _log(
          source,
          SourceDiagOp.fallback,
          SourceDiagLevel.info,
          'heading fallback replaced rule results: '
          '${chapters.length} → ${rebuilt.length} chapters',
        );
        chapters
          ..clear()
          ..addAll(rebuilt);
      } else {
        _log(
          source,
          SourceDiagOp.fallback,
          SourceDiagLevel.info,
          'heading fallback did not replace results: '
          'rebuilt=${rebuilt.length} (need ≥3 and > ${chapters.length})',
        );
      }
    }

    // ------- ChapterList 常见容器 fallback -------
    // 如果规则选错了容器（如免费小说 `.dlbt_wz` / 天下书盟 `ul#list1 li a`
    // 与页面结构不符），heading fallback 也没回天之力（anchorPool 太小
    // 或者 <a> 在错误的容器里根本没被收集），这时候用已知 40 个常见章列表
    // 选择器在各目录页 HTML 上逐试，抓到章节后再用 heading filter 过一遍。
    if (chapters.isEmpty && httpOk) {
      _log(
        source,
        SourceDiagOp.fallback,
        SourceDiagLevel.warn,
        'chapterList container fallback triggered: '
        'headingFallbackUsed=$headingTriggeredFallback '
        'chapterListHits=$chapterListHits trying ${_kChapterListContainerCandidates.length} selectors',
        details: 'startUrl=$startUrl',
      );
      final collectedPool = <_FallbackChapterCandidate>[];
      final anchorSeen = <String>{};
      // 遍历刚才所有目录页响应（pendingPages 走过后已入 seenPages，但 DOM
      // 已丢），所以需要重新抓（严格说可以缓存，但 fallback 路径不常见，
      // 宁可多请求几轮也要保持代码清晰）。
      for (final pageUrl in seenPages) {
        final LegadoResponse resp;
        try {
          resp = _cachedDetailPage(pageUrl) ??
              await _request(source, pageUrl);
        } on Object {
          continue;
        }
        final doc = LegadoRuleDocument.parse(resp.body, resp.finalUri);
        int matchedIdx = -1;
        for (var i = 0; i < _kChapterListContainerCandidates.length; i++) {
          final selector = _kChapterListContainerCandidates[i];
          List<Element> elems;
          try {
            elems = doc.querySelectorAll(selector);
          } on Object {
            continue;
          }
          if (elems.isEmpty) continue;
          matchedIdx = i;
          // 统一递归找内部所有带 href 的 <a>：对 .zjlist_link 这类容器、
          // 对 ul#list1 li 这类列表项、对 a[href] 自身都生效。
          final anchors = _collectAnchorsWithin(elems, doc: doc);
          for (final a in anchors) {
            final href = a.attributes['href'];
            if (href == null || href.isEmpty) continue;
            final resolved = doc.baseUri.resolve(href);
            if (resolved.scheme != 'http' && resolved.scheme != 'https') continue;
            final url = resolved.toString();
            if (!anchorSeen.add(url)) continue;
            var title = (a.text).trim();
            if (title.isEmpty) {
              title = a.attributes['title'] ?? '';
            }
            if (title.isEmpty || title.length > 120) continue;
            collectedPool.add(
              _FallbackChapterCandidate(
                title: title,
                url: url,
                pageDepth: 0,
              ),
            );
          }
          // 选到一个命中的就跳出：避免多个容器混合产生乱序重复。
          if (collectedPool.length >= 3) break;
        }
        if (matchedIdx >= 0) {
          _log(
            source,
            SourceDiagOp.fallback,
            SourceDiagLevel.info,
            'container fallback on ${resp.finalUri}: matched '
            'selector index=$matchedIdx '
            '(${_kChapterListContainerCandidates[matchedIdx]}) → '
            '${collectedPool.length} candidates so far',
          );
        }
      }
      // 用 heading filter 过滤（比如去掉首页/导航/广告）。
      final filtered = ChapterHeadingLibrary.filter(
        collectedPool,
        titleOf: (c) => c.title,
      );
      final rebuilt = <BookSourceChapter>[];
      final newSeen = <String>{};
      for (final c in filtered) {
        if (!newSeen.add(c.url)) continue;
        if (rebuilt.length >= _maxChapters) break;
        rebuilt.add(
          BookSourceChapter(id: c.url, title: c.title, order: rebuilt.length),
        );
      }
      if (rebuilt.length >= 3) {
        _log(
          source,
          SourceDiagOp.fallback,
          SourceDiagLevel.info,
          'container fallback recovered ${rebuilt.length} chapters',
        );
        chapters
          ..clear()
          ..addAll(rebuilt);
      } else {
        _log(
          source,
          SourceDiagOp.fallback,
          SourceDiagLevel.info,
          'container fallback did not recover chapters: '
          'candidates=${collectedPool.length} headingFiltered=${filtered.length} '
          'rebuilt=${rebuilt.length} (need ≥3)',
        );
      }
    }

    onDiagnostics?.call(
      _ChapterPageDiagnostics(
        httpOk: httpOk,
        chapterListHits: chapterListHits,
        validChapters: chapters.length,
      ),
    );
    return chapters;
  }

  Future<BookSourceChapterContent> getChapterContent(
    RegisteredBookSource registered, {
    required String bookId,
    required String chapterId,
    String? nextChapterId,
  }) async {
    final source = _source(registered);
    await _ensureRunnable(source);
    final vars = _jsVariables(source);
    final rule = source.rule('ruleContent');
    final contentRule = _optionalRule(rule, 'content');
    final nextUrlRule = _optionalRule(rule, 'nextContentUrl');
    final parts = <String>[];
    final seenPages = <String>{};
    var lastFinalUri = source.baseUri;
    var nextUrl = chapterId;
    // 正文页防盗链：首章页 Referer 指向书籍详情页，翻页后逐页前移。
    var pageReferer = bookId;
    var hop = 0;
    var httpOk = false;
    var contentRuleHits = 0;
    LegadoRuleDocument? lastDocument;
    String? lastRawBody;
    for (; hop < _maxPageHops && nextUrl.isNotEmpty; hop++) {
      if (!seenPages.add(nextUrl)) break;
      final LegadoResponse response;
      try {
        response = await _request(source, nextUrl, referer: pageReferer);
        httpOk = true;
      } on BookSourceProtocolException catch (error) {
        // 后续分页 404/断连视为正文自然结束，保留已抓段落。
        if (hop > 0 && _isPaginationEndError(error)) break;
        _log(
          source,
          SourceDiagOp.content,
          SourceDiagLevel.error,
          'getChapterContent(chapterId=$chapterId) HTTP failed at hop $hop',
          details: 'bookId=$bookId\nnextUrl=$nextUrl\n'
              'contentRule=${contentRule.isEmpty ? "(missing)" : contentRule}\n'
              'cause=${error.message}',
        );
        final detail = StringBuffer('Failed to load chapter content.\n')
          ..writeln('Source: ${source.name} (${source.url})')
          ..writeln('bookId: $bookId')
          ..writeln('chapterId: $chapterId')
          ..writeln('failed page $hop: $nextUrl')
          ..writeln('content rule: ${contentRule.isEmpty ? '(missing)' : contentRule}')
          ..write('Cause: ${error.message}');
        throw BookSourceProtocolException(detail.toString());
      }
      lastFinalUri = response.finalUri;
      pageReferer = response.finalUri.toString();
      lastRawBody = response.body;
      final document = LegadoRuleDocument.parse(
        response.body,
        response.finalUri,
      );
      var content = await _value(
        document,
        null,
        rule,
        'content',
        required: true,
        jsVariables: vars,
        sourceUrl: source.url,
      );
      if (content.isNotEmpty) contentRuleHits++;
      content = _rules.applyReplaceRule(
        content,
        _optionalRule(rule, 'replaceRegex'),
      );
      if (content.trim().isNotEmpty) parts.add(content.trim());
      nextUrl = await _url(
        document,
        null,
        rule,
        'nextContentUrl',
        jsVariables: vars,
        sourceUrl: source.url,
      );
      // yuedu_hd 行为：解析出的"下一页"就是下一章的地址时，
      // 说明本章已到末尾，停止抓取避免把下一章内容并入本章。
      lastDocument = document;
      if (nextChapterId != null &&
          nextChapterId.isNotEmpty &&
          nextUrl == nextChapterId) {
        break;
      }
    }
    // 规则 0 命中时 fallback:按常见正文容器列表逐试(常见 40 个)。
    // 只有 text 类型源尝试,避免污染漫画/听书 fallback(它们是用 URL 列表而非 DOM 文本)。
    if (parts.isEmpty && source.type == 0 && lastDocument != null && httpOk) {
      final rootDocument = lastDocument;
      _log(
        source,
        SourceDiagOp.fallback,
        SourceDiagLevel.warn,
        'content fallback triggered: contentRuleHits=$contentRuleHits '
        'trying common content containers',
        details: 'contentRule=${contentRule.isEmpty ? "(missing)" : contentRule}\n'
            'chapterId=$chapterId',
      );
      final candidates = <String>[];
      for (final selector in _kContentContainerCandidates) {
        try {
          final elems = rootDocument.querySelectorAll(selector);
          for (final el in elems) {
            final text = el.nodes
                .whereType<dom.Text>()
                .map((n) => n.data)
                .join()
                .trim();
            if (text.length > 200) candidates.add(text);
          }
          if (candidates.isNotEmpty) break;
        } on Object {
          continue;
        }
      }
      if (candidates.isNotEmpty) {
        // 优先取最长的一段（通常就是正文），短的可能是侧栏。
        candidates.sort((a, b) => b.length.compareTo(a.length));
        parts.add(candidates.first);
        int matchedIndex = -1;
        for (var i = 0; i < _kContentContainerCandidates.length; i++) {
          try {
            if (rootDocument.querySelectorAll(_kContentContainerCandidates[i]).isNotEmpty) {
              matchedIndex = i;
              break;
            }
          } on Object {
            continue;
          }
        }
        _log(
          source,
          SourceDiagOp.fallback,
          SourceDiagLevel.info,
          'content fallback recovered ${candidates.first.length} chars',
          details: 'matched selector index=$matchedIndex '
              '(${matchedIndex >= 0 ? _kContentContainerCandidates[matchedIndex] : "unknown"})',
        );
      }
    }
    if (parts.isEmpty) {
      final diagnostic = [
        'hops=$hop',
        'httpOk=$httpOk',
        'contentRuleHits=$contentRuleHits',
      ].join(' ');
      // 正文提取为 0 时记录响应体片段和 DOM 特征,
      // 这是用户反馈最多的"不显示内容",有了 snippet 才能判断是
      // 反爬返回空白页还是 CSS 选择器写错。
      var domSnippet = '';
      try {
        final body = lastRawBody ?? '';
        if (body.isNotEmpty) {
          final snippet = body.length > 1500
              ? '${body.substring(0, 1500)}...[truncated ${body.length}]'
              : body;
          final signals = _extractDomSignals(body);
          domSnippet = '\npage snippet: $snippet\npage dom signals: $signals';
        }
      } on Object {
        domSnippet = '\n(page capture failed)';
      }
      _log(
        source,
        SourceDiagOp.content,
        SourceDiagLevel.error,
        'getChapterContent(chapterId=$chapterId) → empty content',
        details: 'bookId=$bookId\nhops=$hop httpOk=$httpOk contentRuleHits=$contentRuleHits\n'
            'contentRule=${contentRule.isEmpty ? "(missing)" : contentRule}\n'
            'nextContentUrlRule=${nextUrlRule.isEmpty ? "(missing)" : nextUrlRule}\n'
            'chapterId(=firstPageUrl)=$chapterId$domSnippet',
      );
      throw BookSourceProtocolException(
        'Compatible source did not return chapter content.\n'
        'Source: ${source.name} (${source.url})\n'
        'bookId: $bookId\n'
        'chapterId: $chapterId\n'
        'nextChapterId: ${nextChapterId ?? '(none)'}\n'
        'content rule: ${contentRule.isEmpty ? '(missing)' : contentRule}\n'
        'nextContentUrl rule: ${nextUrlRule.isEmpty ? '(missing)' : nextUrlRule}\n'
        'Diagnostics: $diagnostic',
      );
    }
    final joined = parts.join('\n\n');
    // 媒体源：内容规则返回的是地址列表（每行一个）。
    // 漫画源(2)→图片列表；听书源(1)→音频地址。
    List<String>? imageUrls;
    List<String>? audioUrls;
    if (source.type == 1 || source.type == 2) {
      final urls = _extractUrls(joined, lastFinalUri);
      if (urls.isNotEmpty) {
        if (source.type == 2) {
          imageUrls = urls;
        } else {
          audioUrls = urls;
        }
      }
    }
    _log(
      source,
      SourceDiagOp.content,
      SourceDiagLevel.info,
      'getChapterContent(chapterId=$chapterId) → '
      '${joined.length} chars, $hop hop(s), '
      '${imageUrls?.length ?? audioUrls?.length ?? 0} media urls',
    );
    return BookSourceChapterContent(
      bookId: bookId,
      chapterId: chapterId,
      title: '',
      content: joined,
      contentType: 'text/html',
      imageUrls: imageUrls,
      audioUrls: audioUrls,
    );
  }

  /// 把内容文本拆分为地址列表：仅当所有非空行都是可解析的
  /// URL 时才视为媒体列表，避免把普通正文误判成图片。
  List<String> _extractUrls(String content, Uri baseUri) {
    final lines = content
        .split(RegExp(r'[\n\r]+'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    if (lines.isEmpty) return const [];
    final urls = <String>[];
    for (final line in lines) {
      final cleaned = line.startsWith('<') && line.endsWith('>')
          ? line.substring(1, line.length - 1).trim()
          : line;
      Uri? uri = Uri.tryParse(cleaned);
      if (uri != null && uri.hasAuthority) {
        if (uri.scheme != 'http' && uri.scheme != 'https') return const [];
        urls.add(uri.toString());
        continue;
      }
      uri = baseUri.resolve(cleaned);
      if (uri.hasAuthority && (uri.scheme == 'http' || uri.scheme == 'https')) {
        urls.add(uri.toString());
        continue;
      }
      return const [];
    }
    return urls;
  }

  void _cacheDetailPage(String bookId, LegadoResponse response) {
    _detailCache.remove(bookId);
    _detailCache[bookId] = _CachedDetailPage(
      body: response.body,
      finalUri: response.finalUri,
      cachedAt: DateTime.now(),
    );
    while (_detailCache.length > _detailCacheCapacity) {
      _detailCache.remove(_detailCache.keys.first);
    }
  }

  LegadoResponse? _cachedDetailPage(String bookId) {
    final entry = _detailCache[bookId];
    if (entry == null) return null;
    if (DateTime.now().difference(entry.cachedAt) > _detailCacheTtl) {
      _detailCache.remove(bookId);
      return null;
    }
    return LegadoResponse(body: entry.body, finalUri: entry.finalUri);
  }

  /// 分页目录/正文的"翻页失败视为自然结束"判定：
  /// 首页(hop==0)失败仍需上抛，后续页 404/410/连接失败只终止翻页。
  /// 对照 yuedu_hd：目录分页 404 视为结束并保留已抓章节。
  static bool _isPaginationEndError(Object error) {
    if (error is! BookSourceProtocolException) return false;
    final message = error.message;
    return message.startsWith('Legado source returned HTTP 40') ||
        message.startsWith('Legado source returned HTTP 41') ||
        message.startsWith('Could not connect');
  }

  Future<String> _tocUrl(LegadoBookSource source, String bookId) async {
    final rule = source.rule('ruleBookInfo');
    final tocRule = _optionalRule(rule, 'tocUrl');
    if (tocRule.isEmpty) return bookId;
    final vars = _jsVariables(source);
    // 复用 getBook 刚抓的详情页，避免二次请求（防重放站点 404）。
    final cached = _cachedDetailPage(bookId);
    final response = cached ?? await _request(source, bookId);
    if (cached == null) {
      _cacheDetailPage(bookId, response);
    }
    final document = LegadoRuleDocument.parse(response.body, response.finalUri);
    final init = _optionalRule(rule, 'init');
    final context = init.isEmpty
        ? null
        : (await _rules.evaluateList(
            document,
            null,
            init,
            jsVariables: vars,
            sourceUrl: source.url,
          )).firstOrNull;
    String evaluated;
    try {
      evaluated = await _rules.evaluateString(
        document,
        context,
        tocRule,
        resolveUrl: false,
        jsVariables: vars,
        sourceUrl: source.url,
      );
    } catch (_) {
      // tocUrl 规则求值失败（JS/选择器异常）时回退详情页地址，
      // 由 getChapters 在详情页上直接解析章节。
      return bookId;
    }
    // Legado 语义：tocUrl 求值为空或 `-` 表示目录页即书籍详情页。
    // 此前无此回退，目录规则求空后直接请求空地址，报 404。
    if (evaluated.isEmpty || evaluated.trim() == '-') return bookId;
    // 求值结果可能仍是 URL 模板（@get:{}/{{}}/相对路径），统一展开。
    final expanded = await _expandTemplate(
      evaluated.trim(),
      const {},
      response.finalUri,
      source: source,
    );
    final resolved = response.finalUri.resolve(expanded);
    if (resolved.scheme != 'http' && resolved.scheme != 'https') {
      return bookId;
    }
    var tocUrl = LegadoRuleEngine.normalizeUrlPath(resolved.toString());
    // Fix2: tocUrl 求值异常短路。
    //
    // 群小说网这类：tocUrl 规则把 baseUrl/站点根（http://www.qunxs.com）
    // 当成了目录页返回。显然不可能包含任何章列表（章列表一定在详情页
    // 内或独立目录页）。Legado 官方通过后续 0 章节再 fallback 也能
    // 到达详情页，但会先额外请求一次首页浪费时间且 anchorPool 被首页
    // 的噪声链接污染。这里直接提前识别：
    //   如果 tocUrl 的 scheme+host+port (origin) 等于详情页 origin，
    //   且路径为空或 "/"，则视为 tocUrl 求值错 → 直接返回详情页。
    try {
      final tocUri = Uri.parse(tocUrl);
      final detailUri = response.finalUri;
      final tocIsRoot = tocUri.hasScheme &&
          tocUri.hasAuthority &&
          tocUri.origin == detailUri.origin &&
          (tocUri.path.isEmpty || tocUri.path == '/');
      if (tocIsRoot) {
        _log(
          source,
          SourceDiagOp.chapters,
          SourceDiagLevel.warn,
          'tocUrl evaluates to site root ($tocUrl), treating as detail-page TOC '
          '(bookId=$bookId)',
        );
        return bookId;
      }
    } on FormatException {
      // parse 失败按原路径处理。
    }
    return tocUrl;
  }

  Future<BookSourceBook?> _bookFromRules(
    LegadoRuleDocument document,
    Object? context,
    Map<String, dynamic> rule, {
    Map<String, Object?> vars = const {},
    String sourceUrl = '',
  }) async {
    final title = await _value(
      document,
      context,
      rule,
      'name',
      jsVariables: vars,
      sourceUrl: sourceUrl,
    );
    var url = await _url(
      document,
      context,
      rule,
      'bookUrl',
      jsVariables: vars,
      sourceUrl: sourceUrl,
    );
    // yuedu_hd 行为：bookUrl 为空时回退用 tocUrl 作为书籍地址。
    if (url.isEmpty) {
      url = await _url(
        document,
        context,
        rule,
        'tocUrl',
        jsVariables: vars,
        sourceUrl: sourceUrl,
      );
    }
    if (title.isEmpty || url.isEmpty) return null;
    return BookSourceBook(
      id: url,
      title: title,
      author: await _value(
        document,
        context,
        rule,
        'author',
        jsVariables: vars,
        sourceUrl: sourceUrl,
      ),
      description: await _value(
        document,
        context,
        rule,
        'intro',
        jsVariables: vars,
        sourceUrl: sourceUrl,
      ),
      coverUrl: await _uriValue(
        document,
        context,
        rule,
        'coverUrl',
        vars: vars,
        sourceUrl: sourceUrl,
      ),
      categories: _splitCategories(
        await _value(
          document,
          context,
          rule,
          'kind',
          jsVariables: vars,
          sourceUrl: sourceUrl,
        ),
      ),
      latestChapter: _nullable(
        await _value(
          document,
          context,
          rule,
          'lastChapter',
          jsVariables: vars,
          sourceUrl: sourceUrl,
        ),
      ),
    );
  }

  Future<LegadoResponse> _request(
    LegadoBookSource source,
    String template, {
    Map<String, String> variables = const {},
    String? referer,
  }) async {
    final expanded = await _expandTemplate(
      template,
      variables,
      source.baseUri,
      source: source,
    );
    return _transport.send(
      LegadoRequestTemplate.parse(
        expanded,
        baseUri: source.baseUri,
        variables: const {},
        sourceHeaders: await _sourceHeaders(source),
        referer: referer,
      ),
    );
  }

  /// 展开 URL 模板：`@get:{}` 变量、`@js:`/`<js>` 脚本段、内置变量
  /// 静态替换，剩余 `{{}}` 表达式走 JS。JS 引擎不可用时脚本段保持原样，
  /// 由请求解析器给出可诊断错误（这类源会被导入校验标记为不可运行）。
  Future<String> _expandTemplate(
    String template,
    Map<String, String> variables,
    Uri baseUri, {
    LegadoBookSource? source,
  }) async {
    var working = template.trim();
    final sourceUrl = source?.url ?? '';
    final jsVariables = {
      'key': variables['key'] ?? '',
      'page': variables['page'] ?? '',
      'baseUrl': baseUri.toString(),
      'host': baseUri.host,
      'title': variables['title'] ?? '',
      'prelude': source == null ? '' : _stringOrEmpty(source.raw['jsLib']),
    };

    // `@js:` 前缀：整个地址是一条 JS 语句，求值结果即 URL。
    if (working.toLowerCase().startsWith('@js:')) {
      final engine = LegadoJsEngine.instance;
      if (engine != null) {
        try {
          final value = await engine.evaluateExpression(
            working.substring(4),
            jsVariables,
            prelude: '${jsVariables['prelude']}',
            sourceUrl: sourceUrl,
          );
          if (value.trim().isNotEmpty) working = value.trim();
        } catch (_) {
          // 引擎失败 fallback 到 Dart 迷你解释器。
          working = _dartMiniEvalJs(
            working.substring(4),
            jsVariables,
          ) ??
              working;
        }
      } else {
        working = _dartMiniEvalJs(
              working.substring(4),
              jsVariables,
            ) ??
            working;
      }
    } else if (working.contains('<js>')) {
      // 内联 `<js>...</js>` 段：逐段求值并替换为结果。
      final engine = LegadoJsEngine.instance;
      for (final match in RegExp(
        r'<js>([\s\S]*?)</js>',
      ).allMatches(working).toList()) {
        String? value;
        if (engine != null) {
          try {
            value = await engine.evaluateExpression(
              match.group(1)!,
              jsVariables,
              sourceUrl: sourceUrl,
            );
          } catch (_) {
            value = _dartMiniEvalJs(match.group(1)!, jsVariables);
          }
        } else {
          value = _dartMiniEvalJs(match.group(1)!, jsVariables);
        }
        if (value != null && value.isNotEmpty) {
          working = working.replaceAll(match.group(0)!, value);
        }
      }
    }

    // 变量池展开：`@get:{name}` 从按源隔离的跨请求变量池取值。
    // 未命中保持原样，由请求解析器给出可诊断错误。
    if (sourceUrl.isNotEmpty && working.contains('@get:')) {
      working = LegadoVariableSyntax.expandGetsStrict(
        working,
        (name) => LegadoVariableStore.instance.get(sourceUrl, name),
      );
    }

    // URL 模板里的 `@put:{name:literal}`：字面量形式先存变量池再剥离；
    // 含规则语法（如 class.xxx）的无法离线求值，仅剥离避免误拦。
    if (sourceUrl.isNotEmpty && working.contains('@put:')) {
      working = working.replaceAllMapped(
        RegExp(r'@put:\{([^{}:]+):([\s\S]*?)\}'),
        (match) {
          final name = match.group(1)!.trim();
          final literal = match.group(2)!.trim();
          final isRuleish =
              literal.contains('@') ||
              literal.contains('{{') ||
              literal.contains('//');
          if (name.isNotEmpty &&
              literal.isNotEmpty &&
              !isRuleish &&
              source != null) {
            LegadoVariableStore.instance.put(sourceUrl, name, literal);
          }
          return '';
        },
      );
    }

    if (!working.contains('{{')) return working;
    var expanded = working.replaceAllMapped(
      RegExp(r'\{\{\s*([^{}]+?)\s*\}\}'),
      (match) {
        final value = variables[match.group(1)!.trim()];
        return value == null
            ? match.group(0)!
            : Uri.encodeQueryComponent(value);
      },
    );
    final unresolved = RegExp(
      r'\{\{\s*([^{}]+?)\s*\}\}',
    ).allMatches(expanded).toList();
    if (unresolved.isEmpty) return expanded;
    final engine = LegadoJsEngine.instance;
    for (final match in unresolved) {
      final expression = match.group(1)!.trim();
      String? value;
      if (engine != null) {
        try {
          value = await engine.evaluateExpression(
            expression,
            jsVariables,
            sourceUrl: sourceUrl,
          );
        } catch (_) {
          value = _dartMiniEvalJs(expression, jsVariables);
        }
      } else {
        value = _dartMiniEvalJs(expression, jsVariables);
      }
      if (value != null && value.isNotEmpty) {
        expanded = expanded.replaceAll(match.group(0)!, value);
      }
    }
    return expanded;
  }

  /// JS 引擎不可用时的轻量级表达式 fallback。
  /// 专门覆盖 Legado 生态在 URL 模板里最常见的 5 种模式：
  ///   1. `变量.replace("a","b")` / `变量.replaceAll("a","b")`
  ///   2. `变量.split("x").join("y")` 组合
  ///   3. `result = 表达式;` 或 `变量 = 表达式;` 形式
  ///   4. `page + 1` / `变量 - 1` / `page*N` 算术
  ///   5. 纯变量引用 `baseUrl` / `host` / `key` / `page` / `title`
  static String? _dartMiniEvalJs(
    String rawScript,
    Map<String, String> variables,
  ) {
    if (rawScript.trim().isEmpty) return null;
    var src = rawScript.trim();
    // 先剥掉结尾的分号。
    while (src.endsWith(';')) {
      src = src.substring(0, src.length - 1).trim();
    }
    // 模式 3：`result = expr;` / `xxx = expr;` 赋值，只取右边。
    final assignMatch = RegExp(
      r'^[A-Za-z_$][\w$]*\s*=\s*([\s\S]+)',
    ).firstMatch(src);
    if (assignMatch != null) {
      src = assignMatch.group(1)!.trim();
    }
    try {
      return _dartMiniEvalExpression(src, variables);
    } catch (_) {
      return null;
    }
  }

  static String? _dartMiniEvalExpression(
    String expression,
    Map<String, String> variables,
  ) {
    var expr = expression.trim();
    if (expr.isEmpty) return null;
    // 模式 5：纯变量。
    final onlyVar = RegExp(r'^[A-Za-z_$][\w$]*$').firstMatch(expr);
    if (onlyVar != null) {
      final v = variables[onlyVar.group(0)!];
      if (v != null) return v;
      // page 默认按 "1" 处理以适配 `page+1` 失败后回退。
      if (onlyVar.group(0)! == 'page') return '1';
      return null;
    }
    // 字符串字面量：
    final strLit = RegExp(r"""^(["'])((?:\\.|(?!\1)[\s\S])*)\1$""").firstMatch(expr);
    if (strLit != null) {
      return strLit.group(2)!;
    }
    // 数字字面量：
    if (RegExp(r'^\d+$').hasMatch(expr)) return expr;
    // 模式 1 / 2：链式方法调用 `变量.method(...).method(...)...`
    // 支持 replace/replaceAll/split/join/toString 等。
    final callChain = RegExp(
      r'^([A-Za-z_$][\w$]*)((?:\.[A-Za-z_$][\w$]*\s*\([^)]*\))+)$',
    ).firstMatch(expr);
    if (callChain != null) {
      var base = variables[callChain.group(1)!];
      if (base == null) return null;
      var working = base;
      final chainSource = callChain.group(2)!;
      // 切分每个 .method(args)（简单按括号配对）。
      final methodRe = RegExp(
        r'\.?([A-Za-z_$][\w$]*)\s*\(([^)]*)\)',
      );
      final methods = methodRe.allMatches(chainSource).toList();
      if (methods.isEmpty) return working;
      for (final m in methods) {
        final name = m.group(1)!;
        final argsRaw = m.group(2) ?? '';
        final args = _parseMiniArgs(argsRaw, variables);
        switch (name) {
          case 'replace':
          case 'replaceAll':
            if (args.length >= 2) {
              working = working.replaceAll(args[0], args[1]);
            }
            break;
          case 'replaceFirst':
            if (args.length >= 2) {
              working = working.replaceFirst(args[0], args[1]);
            }
            break;
          case 'split':
            break;
          case 'join':
            break;
          case 'toString':
            break;
          case 'trim':
            working = working.trim();
            break;
        }
      }
      return working;
    }
    // 模式 4：`变量 op 数字` 或 `数字 op 变量`。
    final arith = RegExp(
      r'^(\d+|[A-Za-z_$][\w$]*)\s*([+\-*/])\s*(\d+|[A-Za-z_$][\w$]*)$',
    ).firstMatch(expr);
    if (arith != null) {
      int? resolve(dynamic s) {
        final v = s.toString();
        final n = int.tryParse(v);
        if (n != null) return n;
        final varValue = variables[v];
        if (varValue != null) return int.tryParse(varValue);
        if (v == 'page') return 1;
        return null;
      }

      final left = resolve(arith.group(1));
      final right = resolve(arith.group(3));
      final op = arith.group(2)!;
      if (left != null && right != null) {
        int r;
        switch (op) {
          case '+':
            r = left + right;
            break;
          case '-':
            r = left - right;
            break;
          case '*':
            r = left * right;
            break;
          case '/':
            r = right == 0 ? 0 : (left / right).round();
            break;
          default:
            return null;
        }
        return r.toString();
      }
    }
    // 字符串拼接：`"abc" + 变量` 或 `变量 + "xyz"`（退化尝试）。
    final concat = RegExp(
      r"""^([A-Za-z_$][\w$]*)\s*\+\s*(["'])((?:\\.|(?!\2)[\s\S])*)\2$""",
    ).firstMatch(expr);
    if (concat != null) {
      final base = variables[concat.group(1)!];
      if (base != null) return base + concat.group(3)!;
    }
    final concat2 = RegExp(
      r"""^(["'])((?:\\.|(?!\1)[\s\S])*)\1\s*\+\s*([A-Za-z_$][\w$]*)$""",
    ).firstMatch(expr);
    if (concat2 != null) {
      final base = variables[concat2.group(3)!];
      if (base != null) return concat2.group(2)! + base;
    }
    return null;
  }

  static List<String> _parseMiniArgs(
    String argsRaw,
    Map<String, String> variables,
  ) {
    final out = <String>[];
    int i = 0;
    while (i < argsRaw.length) {
      final ch = argsRaw[i];
      if (ch == ' ' || ch == '\t' || ch == ',') {
        i++;
        continue;
      }
      // 字符串字面量（支持单/双引号）。
      if (ch == '"' || ch == "'") {
        final quote = ch;
        i++;
        final buf = StringBuffer();
        while (i < argsRaw.length) {
          final c = argsRaw[i];
          if (c == '\\' && i + 1 < argsRaw.length) {
            final n = argsRaw[i + 1];
            switch (n) {
              case 'n':
                buf.write('\n');
                break;
              case 't':
                buf.write('\t');
                break;
              case 'r':
                buf.write('\r');
                break;
              case '"':
                buf.write('"');
                break;
              case "'":
                buf.write("'");
                break;
              case '\\':
                buf.write('\\');
                break;
              default:
                buf.write(n);
            }
            i += 2;
          } else if (c == quote) {
            i++;
            break;
          } else {
            buf.write(c);
            i++;
          }
        }
        out.add(buf.toString());
      } else {
        // 裸 token：数字或变量。
        final start = i;
        while (i < argsRaw.length && argsRaw[i] != ',') {
          i++;
        }
        final token = argsRaw.substring(start, i).trim();
        if (token.isNotEmpty) {
          if (RegExp(r'^[A-Za-z_$][\w$]*$').hasMatch(token)) {
            out.add(variables[token] ?? token);
          } else {
            out.add(token);
          }
        }
      }
    }
    return out;
  }

  /// 组装传给规则引擎的 JS 变量（含 jsLib 前置脚本）。
  Map<String, Object?> _jsVariables(
    LegadoBookSource source, [
    Map<String, String> extra = const {},
  ]) {
    return {
      'key': extra['key'] ?? '',
      'page': extra['page'] ?? '',
      'baseUrl': source.baseUri.toString(),
      'host': source.baseUri.host,
      'prelude': _stringOrEmpty(source.raw['jsLib']),
    };
  }

  static String _stringOrEmpty(Object? value) => value is String ? value : '';

  Future<Map<String, String>> _sourceHeaders(LegadoBookSource source) async {
    final raw = source.raw['header'];
    if (raw == null || '$raw'.trim().isEmpty) return const {};
    Object? decoded = raw;
    if (raw is String) {
      try {
        decoded = jsonDecode(raw);
      } on FormatException {
        // JS 对象字面量（如含 java.getUA()）交给脚本引擎求值。
        final engine = LegadoJsEngine.instance;
        if (engine == null) {
          throw const BookSourceProtocolException(
            'Compatible source headers must be valid JSON.',
          );
        }
        try {
          final evaluated = await engine.evaluateExpression('($raw)', {
            'baseUrl': source.baseUri.toString(),
          }, sourceUrl: source.url);
          decoded = jsonDecode(evaluated);
        } catch (_) {
          throw const BookSourceProtocolException(
            'Compatible source headers must be valid JSON.',
          );
        }
      }
    }
    if (decoded is! Map) {
      throw const BookSourceProtocolException(
        'Compatible source headers must be an object.',
      );
    }
    final headers = <String, String>{};
    for (final entry in decoded.entries) {
      final name = '${entry.key}'.trim();
      if (name.isEmpty || entry.value is! String) {
        throw const BookSourceProtocolException(
          'Compatible source headers must contain text values.',
        );
      }
      headers[name] = entry.value as String;
    }
    return headers;
  }

  LegadoBookSource _source(RegisteredBookSource registered) {
    if (registered.sourceProtocol != BookSourceProtocolKind.legado ||
        registered.sourceConfig == null) {
      throw const BookSourceProtocolException(
        'This is not a compatible source configuration.',
      );
    }
    return LegadoBookSource.fromJson(registered.sourceConfig!);
  }

  Future<void> _ensureRunnable(LegadoBookSource source) async {
    final report = const LegadoCompatibilityScanner().scan(source);
    if (!report.canRun) {
      throw const BookSourceProtocolException(
        'This compatible source uses features that are not supported yet.',
      );
    }
  }

  /// 仅搜索链路预检 searchUrl 模板。
  ///
  /// 不要在 getBook/getChapters/getChapterContent 里做这个预检：
  /// 阅读链路根本不发搜索请求，searchUrl 是否含脚本与目录/正文无关。
  /// 此前用假关键词 'preflight' 预检还会让依赖真实搜索词的脚本走错
  /// 分支，或因 JS 引擎不可用（iOS 无 flutter_js pod / 构造失败）而
  /// 误抛 "uses scripting" / "unsupported template expression"，
  /// 表现为发现页正常但点阅读必失败。
  Future<void> _ensureSearchRunnable(LegadoBookSource source) async {
    await _ensureRunnable(source);
    final headers = await _sourceHeaders(source);
    final expandedSearch = await _expandTemplate(
      source.searchUrl,
      const {'key': 'preflight', 'page': '1'},
      source.baseUri,
      source: source,
    );
    LegadoRequestTemplate.parse(
      expandedSearch,
      baseUri: source.baseUri,
      variables: const {},
      sourceHeaders: headers,
    );
  }

  Future<String> _value(
    LegadoRuleDocument document,
    Object? context,
    Map<String, dynamic> rules,
    String key, {
    bool required = false,
    Map<String, Object?> jsVariables = const {},
    String sourceUrl = '',
  }) async {
    final rule = required
        ? _requiredRule(rules, key)
        : _optionalRule(rules, key);
    if (rule.isEmpty) return '';
    return _rules.evaluateString(
      document,
      context,
      rule,
      jsVariables: jsVariables,
      sourceUrl: sourceUrl,
    );
  }

  Future<String> _url(
    LegadoRuleDocument document,
    Object? context,
    Map<String, dynamic> rules,
    String key, {
    Map<String, Object?> jsVariables = const {},
    String sourceUrl = '',
  }) async {
    final rule = _optionalRule(rules, key);
    if (rule.isEmpty) return '';
    return _rules.evaluateString(
      document,
      context,
      rule,
      resolveUrl: true,
      jsVariables: jsVariables,
      sourceUrl: sourceUrl,
    );
  }

  Future<Uri?> _uriValue(
    LegadoRuleDocument document,
    Object? context,
    Map<String, dynamic> rules,
    String key, {
    Map<String, Object?> vars = const {},
    String sourceUrl = '',
  }) async {
    final value = await _url(
      document,
      context,
      rules,
      key,
      jsVariables: vars,
      sourceUrl: sourceUrl,
    );
    return value.isEmpty ? null : Uri.tryParse(value);
  }
}

String _requiredRule(Map<String, dynamic> rules, String key) {
  final rule = _optionalRule(rules, key);
  if (rule.isEmpty) {
    throw BookSourceProtocolException(
      'Compatible source is missing the $key rule.',
    );
  }
  return rule;
}

/// 详情页响应的短期缓存条目，供 getBook/getChapters 共享。
class _CachedDetailPage {
  const _CachedDetailPage({
    required this.body,
    required this.finalUri,
    required this.cachedAt,
  });

  final String body;
  final Uri finalUri;
  final DateTime cachedAt;
}

String _optionalRule(Map<String, dynamic> rules, String key) {
  final value = rules[key];
  return value is String ? value.trim() : '';
}

String? _nullable(String value) => value.trim().isEmpty ? null : value.trim();

List<String> _splitCategories(String value) => value
    .split(RegExp(r'[,/|\s]+'))
    .map((item) => item.trim())
    .where((item) => item.isNotEmpty)
    .toSet()
    .toList(growable: false);

String stableLegadoResourceId(String value) =>
    sha256.convert(utf8.encode(value)).toString().substring(0, 24);

/// 目录抓取过程中的轻量诊断：HTTP 成功了没、chapterList 规则匹配了多少、
/// 其中 chapterName+chapterUrl 双非空的有效条目有几条。
class _ChapterPageDiagnostics {
  const _ChapterPageDiagnostics({
    required this.httpOk,
    required this.chapterListHits,
    required this.validChapters,
  });

  final bool httpOk;
  final int chapterListHits;
  final int validChapters;
}

/// heading fallback 流程里从 <a> 里收集到的候选条目。
class _FallbackChapterCandidate {
  const _FallbackChapterCandidate({
    required this.title,
    required this.url,
    required this.pageDepth,
  });

  final String title;
  final String url;
  final int pageDepth;
}

/// 从 DOM 中提取关键结构特征（id 和 class 的前 40 条高频命中），
/// 用于诊断：当规则完全不匹配时，开发者能一眼看出现页的真实结构。
String _extractDomSignals(String body, {int limit = 40}) {
  final hits = <String, int>{};
  // id="xxx"
  final idMatches = RegExp(r'''id\s*=\s*["']([\w\-:]+)["']''').allMatches(body);
  for (final m in idMatches) {
    final v = m.group(1)!;
    hits['#$v'] = (hits['#$v'] ?? 0) + 1;
  }
  // class="xxx" (按空格拆分单词，每个 class 单独记)
  final classMatches =
      RegExp(r'''class\s*=\s*["']([^"']+)["']''').allMatches(body);
  for (final m in classMatches) {
    final classes = m.group(1)!.split(RegExp(r'\s+'));
    for (final c in classes) {
      if (c.isEmpty) continue;
      hits['.$c'] = (hits['.$c'] ?? 0) + 1;
    }
  }
  final sorted = hits.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  final out = <String>[];
  for (final e in sorted.take(limit)) {
    out.add('${e.key}×${e.value}');
  }
  return out.join(', ');
}

/// 正文容器 fallback 的候选列表：Legado 生态中最常见的正文容器 id/class。
const List<String> _kContentContainerCandidates = [
  '#content',
  '#contents',
  '#content1',
  '#BookText',
  '#htmlContent',
  '#contentBody',
  '#content_body',
  '#chaptercontent',
  '#chapterContent',
  '#articlecontent',
  '#contentDetail',
  '#cont_5336',
  '#nr1',
  '#nr',
  '#contenttext',
  '#read_t2k_txt',
  '#main-container',
  '#content-txt',
  '#chapter_content',
  '#content_detail',
  '.content',
  '.book-content',
  '.read-content',
  '.showtxt',
  '.txtContent',
  '.content-body',
  '.contentbox',
  '.content_text',
  '.read-box',
  '.BookRead',
  '.nr1',
  '.nr',
  '.read-container',
  '.article-content',
  '#reading-content',
  '.chapter-content',
  '.content_main',
  '.text-content',
  '#text',
  '.reader-box',
];

/// 章列表容器 fallback 候选：按命中占比 >80% 的顺序排序。
///
/// 注：这里故意不写后缀 `a`（除了最后兜底一条），统一交给
/// `_collectAnchorsWithin` 递归找内部所有带 href 的 <a>。这样 selector
/// 命中的是容器（`.zjlist_link`）、列表项（`ul#list1 li`）或者带 `<a>`
/// 的文本段落都能被正确处理。
const List<String> _kChapterListContainerCandidates = [
  // —— id 类（最稳定，优先）
  '#list',
  '#catalog',
  '#chapterList',
  '#chapters',
  '#chapter-list',
  '#dir',
  '#directory',
  '#chapterBox',
  '#list-chapter',
  '#chaps',
  '#book-chapter-list',
  '#content_1',
  '#content-1',
  // 群小说网 & 通用老站：#list + dl/dd 变体
  '#list dl dd',
  '#list dd',
  '#content-list',
  '.chapterlist',
  // —— class 类（常见模板）
  '.chapter-list',
  '.book-list',
  '.chapters',
  '.cl_section',
  '.zjlist',
  '.zjlist dd',
  '.catalog',
  '.book-chapter',
  '.chapter-links',
  '.content_1',
  '.bookinfo-catalog',
  '.chapterbox',
  '.list-chapter',
  '.chapter-items',
  // 天下书盟风格：#a_red3 / #a_red6 是独立章节 id 锚（注意是 id 不是 class，
  // DOM signals: #a_red3×92, #a_red6×42）；.zjlist_link/.zjlist_btn/.cl_btn
  // 是章集容器（每页含多段，按序排）
  'ul#list1 li',
  '#a_red3',
  '#a_red6',
  '.zjlist_link',
  '.zjlist_btn',
  '.cl_btn',
  '.rmtj_list',
  // 免费小说风格
  '.xztext_a',
  '.dl_link',
  '.dl_link_bd',
  '.dlbt_wz',
  // 连尚读书 / Vue SSR：常见的目录容器（如果 SSR 吐出目录的话）
  '.catalog-content',
  '.chapter-catalog',
  '.book-chapter-list',
  '.book-catalog',
  '.catalog-list',
  // 最终兜底：直接在文档里抓所有 a[href]（heading library 会过滤噪声，
  // 所以最后一条保底不会误伤太多）。
  'a[href]',
];

/// 容器 fallback 的辅助：对一个选择器命中的所有节点，找出内部所有带 href 的 <a>。
///
/// 与直接写 `selector a` 不同的是：这里支持 selector 自身就是 `<a>` 的情况
/// （此时直接返回），也支持 selector 是容器内部任意层级嵌套 `<a>` 的情况
/// —— 更关键的是当 selector 命中列表容器（如 `.zjlist_link`）但它不是
/// 直接 `<a>` 父级时，仍能递归找到所有 `<a href>`。
List<dom.Element> _collectAnchorsWithin(
  List<dom.Element> matched, {
  required LegadoRuleDocument doc,
}) {
  final out = <dom.Element>[];
  for (final el in matched) {
    if (el.localName?.toLowerCase() == 'a' &&
        el.attributes.containsKey('href')) {
      out.add(el);
      continue;
    }
    final anchors = el.querySelectorAll('a[href]');
    out.addAll(anchors.where((a) => a.attributes['href']?.isNotEmpty == true));
  }
  return out;
}

/// 根据详情页地址 [bookId] 和已求值的 [tocUrl] 推导常见目录页 URL。
///
/// 针对：tocUrl 规则求值为详情页自身（SSR/规则写错/bookinfo型站点），
/// 但真实目录在相邻路径段上的场景 — 这些站点在 Legado 中靠 JS 重写
/// tocUrl 才能拿到，而我们的迷你 JS 解释器不一定支持，所以用硬编码
/// 的常见模式库（覆盖中文小说 95% 以上目录结构）作为"模式推导"兜底。
///
/// 顺序按命中率从高到低排，第一个命中≥3章的立即返回（详见
/// `getChapters` 中 `chapters.isEmpty` 循环）。
List<String> _guessTocUrls(String bookId, String tocUrl) {
  final out = <String>[];
  final seen = <String>{};
  void add(String url) {
    if (url.isEmpty) return;
    if (!seen.add(url)) return;
    // 只探 http(s)，避免把 mailto/javascript/anchor 放进去。
    try {
      final u = Uri.parse(url);
      if (u.scheme != 'http' && u.scheme != 'https') return;
    } on FormatException {
      return;
    }
    out.add(url);
  }

  Uri bookUri;
  try {
    bookUri = Uri.parse(bookId);
  } on FormatException {
    return out;
  }
  final origin = bookUri.origin;
  final pathSeg = bookUri.pathSegments.toList();
  if (pathSeg.isEmpty) return out;
  // 规范化路径：去掉末尾空段（因为 "/bookinfo/25742/" 拆成 ['bookinfo','25742','']）
  while (pathSeg.isNotEmpty && pathSeg.last.isEmpty) {
    pathSeg.removeLast();
  }
  if (pathSeg.isEmpty) return out;
  final last = pathSeg.last;

  // —— 情况 A：末尾是纯文件名（xiaoshuo_183.html、178692.html 等）
  //    典型：群小说网、八零小说、圣墟小说（畸形双斜杠前的原始形态）
  final lastAsFile = last;
  final dotIdx = lastAsFile.lastIndexOf('.');
  final stem = dotIdx >= 0 ? lastAsFile.substring(0, dotIdx) : lastAsFile;
  final ext = dotIdx >= 0 ? lastAsFile.substring(dotIdx) : '.html';
  //   A1：纯数字 stem → 八零小说 /txtxz/178692.html → /txtml_178692.html
  final pureDigits = int.tryParse(stem);
  if (pureDigits != null) {
    final parent = pathSeg.length >= 2 ? pathSeg.sublist(0, pathSeg.length - 1) : const <String>[];
    // 八零小说约定：txtxz/<id>.html → txtml_<id>.html
    if (parent.isNotEmpty && parent.last == 'txtxz') {
      final p = List<String>.from(parent)..removeLast();
      add('$origin/${[...p, 'txtml_$stem$ext'].join('/')}');
      add('$origin/${[...p, 'ml_$stem$ext'].join('/')}');
    }
    // Ptcms（圣墟）：/author/.../sort/.../<id>/read_<n>.html → 取 bookId
    // 本身就畸形，这里不推导（靠 normalizeUrlPath 后续修 bookId）。
    // 通用：<parent>/<id>.html → <parent>/<id>/  目录作为子路径
    add('$origin/${[...parent, '$stem/'].join('/')}');
    add('$origin/${[...parent, 'list_$stem$ext'].join('/')}');
    add('$origin/${[...parent, 'chapter_$stem$ext'].join('/')}');
  }

  //   A2：下划线分割前缀_数字（xiaoshuo_183.html）→ 群小说网
  final underscoreMatch = RegExp(r'^([A-Za-z]+)_(\d+)$').firstMatch(stem);
  if (underscoreMatch != null) {
    final prefix = underscoreMatch.group(1)!; // xiaoshuo
    final id = underscoreMatch.group(2)!;     // 183
    final parent = pathSeg.length >= 2 ? pathSeg.sublist(0, pathSeg.length - 1) : const <String>[];
    // 群小说网：/xiaoshuo_183.html → /xiaoshuo/183/
    add('$origin/${[...parent, prefix, '$id/'].join('/')}');
    add('$origin/${[...parent, prefix, id].join('/')}');
    add('$origin/${[...parent, '$prefix$id/'].join('/')}');
  }

  // —— 情况 B：路径末尾无后缀 /bookinfo/25742、/index/book/id/2
  //    典型：连尚读书 Nuxt SSR、小说三千 ThinkPHP
  final segmentsForReplace = List<String>.from(pathSeg);
  if (segmentsForReplace.length >= 2) {
    final penultIdx = segmentsForReplace.length - 2;
    final penult = segmentsForReplace[penultIdx];
    // B1：倒数第二段是详情/书籍"语义段"→ 替换成目录语义段
    const detailSegments = {
      'bookinfo', 'info', 'detail', 'book_detail', 'show', 'view', 'readinfo',
    };
    const tocSegments = [
      'book', 'chapter', 'catalog', 'list', 'mulu', 'html', 'read', 'chapters',
      'toc', 'contents', 'menu',
    ];
    if (detailSegments.contains(penult.toLowerCase())) {
      // 连尚：/bookinfo/25742 → /book/25742 /catalog/25742 /chapter/25742
      for (final seg in tocSegments) {
        final replaced = List<String>.from(segmentsForReplace);
        replaced[penultIdx] = seg;
        add('$origin/${replaced.join('/')}');
        add('$origin/${replaced.join('/')}/');
      }
    }

    // B2：倒数第三段是"动作段、详情是三段路径"（/index/book/id/2）
    if (segmentsForReplace.length >= 3) {
      final actionIdx = segmentsForReplace.length - 3;
      final action = segmentsForReplace[actionIdx].toLowerCase();
      // 小说三千：/index/book/id/2 → /index/chapter/id/2
      if (action == 'book' || detailSegments.contains(action)) {
        for (final seg in tocSegments) {
          final replaced = List<String>.from(segmentsForReplace);
          replaced[actionIdx] = seg;
          add('$origin/${replaced.join('/')}');
        }
      }
      // 再看 倒数第二段 是 "id" 这种固定名：也可直接替换路径段后拼接
      if (segmentsForReplace[penultIdx] == 'id') {
        // /index/book/id/2 → /index/chapter_list/id/2.html 等也尝试
        for (final seg in ['chapter_list', 'book_chapters', 'all']) {
          final replaced = List<String>.from(segmentsForReplace);
          replaced[actionIdx] = seg;
          add('$origin/${replaced.join('/')}');
        }
      }
    }
  }

  // —— 情况 C：通用尾注（拼在最后一段后面、或加目录查询参数），命中率低
  //    但作为最后防线。
  final bookPath = bookUri.path.isEmpty ? '/' : bookUri.path;
  final bookPathNoSlash = bookPath.endsWith('/')
      ? bookPath.substring(0, bookPath.length - 1)
      : bookPath;
  final suffixes = [
    '/', '/index.html', '/index.shtml', '/list.html', '/chapter.html',
    '/catalog.html', '/all.html', '/mulu.html',
    '.shtml', '_list.html', '_catalog.html', '_chapter.html',
    '?list=1', '?catalog=1', '?mulu=1',
  ];
  for (final suf in suffixes) {
    add('$origin$bookPathNoSlash$suf');
  }

  return out;
}
