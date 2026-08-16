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
        if (title.isEmpty || url.isEmpty || !seenChapters.add(url)) continue;
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
      try {
        final anchors = await _rules.evaluateList(
          document,
          null,
          '@css:a[href]',
          jsVariables: vars,
          sourceUrl: source.url,
        );
        for (final node in anchors) {
          final maybeText = await _rules.evaluateString(
            document,
            node,
            'text',
            jsVariables: vars,
            sourceUrl: source.url,
          );
          final maybeHref = await _rules.evaluateString(
            document,
            node,
            'href',
            resolveUrl: true,
            jsVariables: vars,
            sourceUrl: source.url,
          );
          if (maybeText.isEmpty || maybeHref.isEmpty) continue;
          fallbackPool.add(
            _FallbackChapterCandidate(
              title: maybeText.trim(),
              url: maybeHref,
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
    if (shouldTryHeadingFallback(
      chapterListHits: chapterListHits,
      validChapters: chapters.length,
    )) {
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
    return resolved.toString();
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
          // 求值失败保持原样，由请求解析器给出可诊断错误。
        }
      }
    } else if (working.contains('<js>')) {
      // 内联 `<js>...</js>` 段：逐段求值并替换为结果。
      final engine = LegadoJsEngine.instance;
      if (engine != null) {
        for (final match in RegExp(
          r'<js>([\s\S]*?)</js>',
        ).allMatches(working).toList()) {
          try {
            final value = await engine.evaluateExpression(
              match.group(1)!,
              jsVariables,
              sourceUrl: sourceUrl,
            );
            if (value.isNotEmpty) {
              working = working.replaceAll(match.group(0)!, value);
            }
          } catch (_) {
            // 单段失败继续处理其余段。
          }
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
    if (engine == null) return expanded;
    for (final match in unresolved) {
      final expression = match.group(1)!.trim();
      try {
        final value = await engine.evaluateExpression(
          expression,
          jsVariables,
          sourceUrl: sourceUrl,
        );
        if (value.isNotEmpty) {
          expanded = expanded.replaceAll(match.group(0)!, value);
        }
      } catch (_) {
        // 未能在本地求值的模板保持原样，由请求解析器给出可诊断错误。
      }
    }
    return expanded;
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
