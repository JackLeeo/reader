import 'dart:convert';

import 'package:crypto/crypto.dart';

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
    final response = await _request(
      source,
      source.searchUrl,
      variables: {'key': query.trim(), 'page': '$page'},
    );
    final document = LegadoRuleDocument.parse(response.body, response.finalUri);
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
    return BookSourceSearchPage(
      items: books.take(pageSize).toList(growable: false),
      page: page,
      pageSize: pageSize,
      hasMore: books.length > pageSize,
    );
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
    // 详情页优先读短期缓存：详情页 UI 已抓过一次的场景（点击进阅读）
    // 不能再次真实请求——一次性 token / 防盗链站点第二次会 403/404。
    final cached = _cachedDetailPage(bookId);
    final response = cached ?? await _request(source, bookId);
    if (cached == null) {
      _cacheDetailPage(bookId, response);
    }
    final document = LegadoRuleDocument.parse(response.body, response.finalUri);
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
      throw const BookSourceProtocolException(
        'Compatible source did not return a book title.',
      );
    }
    return BookSourceBook(
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
  }

  Future<List<BookSourceChapter>> getChapters(
    RegisteredBookSource registered,
    String bookId,
  ) async {
    final source = _source(registered);
    await _ensureRunnable(source);
    final vars = _jsVariables(source);
    final tocUrl = await _tocUrl(source, bookId);
    var chapters = const <BookSourceChapter>[];
    // tocRule 求值出的目录地址请求失败（404/断连）时回退详情页：
    // 求值结果可能是非法地址或书名文本，详情页本身常含章节列表。
    try {
      chapters = await _fetchChapterPages(
        source,
        tocUrl,
        vars,
        referer: bookId,
      );
    } on BookSourceProtocolException {
      if (tocUrl == bookId) rethrow;
    }
    // 目录页解析不出章节时也回退详情页再解析一次（tocUrl 求值
    // 指向了非目录页面的常见容错，详见 yuedu_hd 同类回退）。
    if (chapters.isEmpty && tocUrl != bookId) {
      chapters = await _fetchChapterPages(
        source,
        bookId,
        vars,
        referer: bookId,
      );
    }
    if (chapters.isEmpty) {
      throw const BookSourceProtocolException(
        'Compatible source did not return any chapters.',
      );
    }
    return chapters;
  }

  /// 从 [startUrl] 开始按 nextTocUrl 翻页抓取章节列表。
  Future<List<BookSourceChapter>> _fetchChapterPages(
    LegadoBookSource source,
    String startUrl,
    Map<String, Object?> vars, {
    String? referer,
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
      } on BookSourceProtocolException catch (error) {
        // 后续分页 404/断连视为自然结束，保留已抓章节（yuedu_hd 行为）。
        if (hop > 0 && _isPaginationEndError(error)) break;
        rethrow;
      }
      pageReferer = response.finalUri.toString();
      final document = LegadoRuleDocument.parse(
        response.body,
        response.finalUri,
      );
      final contexts = await _rules.evaluateList(
        document,
        null,
        _requiredRule(rule, 'chapterList'),
        jsVariables: vars,
        sourceUrl: source.url,
      );
      for (final context in contexts) {
        final title = await _value(
          document,
          context,
          rule,
          'chapterName',
          jsVariables: vars,
          sourceUrl: source.url,
        );
        final url = await _url(
          document,
          context,
          rule,
          'chapterUrl',
          jsVariables: vars,
          sourceUrl: source.url,
        );
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
    final parts = <String>[];
    final seenPages = <String>{};
    var lastFinalUri = source.baseUri;
    var nextUrl = chapterId;
    // 正文页防盗链：首章页 Referer 指向书籍详情页，翻页后逐页前移。
    var pageReferer = bookId;
    for (var hop = 0; hop < _maxPageHops && nextUrl.isNotEmpty; hop++) {
      if (!seenPages.add(nextUrl)) break;
      final LegadoResponse response;
      try {
        response = await _request(source, nextUrl, referer: pageReferer);
      } on BookSourceProtocolException catch (error) {
        // 后续分页 404/断连视为正文自然结束，保留已抓段落。
        if (hop > 0 && _isPaginationEndError(error)) break;
        rethrow;
      }
      lastFinalUri = response.finalUri;
      pageReferer = response.finalUri.toString();
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
      if (nextChapterId != null &&
          nextChapterId.isNotEmpty &&
          nextUrl == nextChapterId) {
        break;
      }
    }
    if (parts.isEmpty) {
      throw const BookSourceProtocolException(
        'Compatible source did not return chapter content.',
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
