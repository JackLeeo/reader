import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../models/registered_book_source.dart';
import '../protocol/book_source_protocol.dart';
import 'legado_book_source.dart';
import 'legado_js_engine.dart';
import 'legado_request.dart';
import 'legado_rule_engine.dart';

class LegadoRuntime {
  LegadoRuntime({LegadoTransport? transport})
    : _transport = transport ?? LegadoHttpTransport();

  static const int _maxSearchItems = 100;
  static const int _maxChapters = 30000;
  static const int _maxPageHops = 20;

  final LegadoTransport _transport;
  final LegadoRuleEngine _rules = const LegadoRuleEngine();

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
    );
    final books = <BookSourceBook>[];
    for (final context in contexts.take(_maxSearchItems)) {
      final book = await _bookFromRules(document, context, rule, vars: vars);
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
    return entries.take(_maxExploreEntriesPerSource).map((entry) {
      return BookSourceCategory(
        id: entry.url,
        name: entry.title.isEmpty ? entry.url : entry.title,
      );
    }).toList(growable: false);
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
    );
    final books = <BookSourceBook>[];
    for (final context in contexts.take(_maxSearchItems)) {
      final book = await _bookFromRules(document, context, rule, vars: vars);
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
    final response = await _request(source, bookId);
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
          )).firstOrNull;
    final title = await _value(
      document,
      context,
      rule,
      'name',
      jsVariables: vars,
    );
    if (title.isEmpty) {
      throw const BookSourceProtocolException(
        'Compatible source did not return a book title.',
      );
    }
    return BookSourceBook(
      id: response.finalUri.toString(),
      title: title,
      author: await _value(document, context, rule, 'author', jsVariables: vars),
      description: await _value(
        document,
        context,
        rule,
        'intro',
        jsVariables: vars,
      ),
      coverUrl: await _uriValue(document, context, rule, 'coverUrl', vars: vars),
      categories: _splitCategories(
        await _value(document, context, rule, 'kind', jsVariables: vars),
      ),
      status: _nullable(
        await _value(document, context, rule, 'status', jsVariables: vars),
      ),
      latestChapter: _nullable(
        await _value(document, context, rule, 'lastChapter', jsVariables: vars),
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
    final rule = source.rule('ruleToc');
    final chapters = <BookSourceChapter>[];
    final seenPages = <String>{};
    final seenChapters = <String>{};
    var nextUrl = tocUrl;
    for (var hop = 0; hop < _maxPageHops && nextUrl.isNotEmpty; hop++) {
      if (!seenPages.add(nextUrl)) break;
      final response = await _request(source, nextUrl);
      final document = LegadoRuleDocument.parse(
        response.body,
        response.finalUri,
      );
      final contexts = await _rules.evaluateList(
        document,
        null,
        _requiredRule(rule, 'chapterList'),
        jsVariables: vars,
      );
      for (final context in contexts) {
        final title = await _value(
          document,
          context,
          rule,
          'chapterName',
          jsVariables: vars,
        );
        final url = await _url(
          document,
          context,
          rule,
          'chapterUrl',
          jsVariables: vars,
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
      nextUrl = await _url(
        document,
        null,
        rule,
        'nextTocUrl',
        jsVariables: vars,
      );
    }
    if (chapters.isEmpty) {
      throw const BookSourceProtocolException(
        'Compatible source did not return any chapters.',
      );
    }
    return chapters;
  }

  Future<BookSourceChapterContent> getChapterContent(
    RegisteredBookSource registered, {
    required String bookId,
    required String chapterId,
  }) async {
    final source = _source(registered);
    await _ensureRunnable(source);
    final vars = _jsVariables(source);
    final rule = source.rule('ruleContent');
    final parts = <String>[];
    final seenPages = <String>{};
    var lastFinalUri = source.baseUri;
    var nextUrl = chapterId;
    for (var hop = 0; hop < _maxPageHops && nextUrl.isNotEmpty; hop++) {
      if (!seenPages.add(nextUrl)) break;
      final response = await _request(source, nextUrl);
      lastFinalUri = response.finalUri;
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
      );
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
      if (uri.hasAuthority &&
          (uri.scheme == 'http' || uri.scheme == 'https')) {
        urls.add(uri.toString());
        continue;
      }
      return const [];
    }
    return urls;
  }

  Future<String> _tocUrl(LegadoBookSource source, String bookId) async {
    final rule = source.rule('ruleBookInfo');
    final tocRule = _optionalRule(rule, 'tocUrl');
    if (tocRule.isEmpty) return bookId;
    final vars = _jsVariables(source);
    final response = await _request(source, bookId);
    final document = LegadoRuleDocument.parse(response.body, response.finalUri);
    final init = _optionalRule(rule, 'init');
    final context = init.isEmpty
        ? null
        : (await _rules.evaluateList(
            document,
            null,
            init,
            jsVariables: vars,
          )).firstOrNull;
    return _rules.evaluateString(
      document,
      context,
      tocRule,
      resolveUrl: true,
      jsVariables: vars,
    );
  }

  Future<BookSourceBook?> _bookFromRules(
    LegadoRuleDocument document,
    Object? context,
    Map<String, dynamic> rule, {
    Map<String, Object?> vars = const {},
  }) async {
    final title = await _value(document, context, rule, 'name', jsVariables: vars);
    final url = await _url(document, context, rule, 'bookUrl', jsVariables: vars);
    if (title.isEmpty || url.isEmpty) return null;
    return BookSourceBook(
      id: url,
      title: title,
      author: await _value(document, context, rule, 'author', jsVariables: vars),
      description: await _value(
        document,
        context,
        rule,
        'intro',
        jsVariables: vars,
      ),
      coverUrl: await _uriValue(
        document,
        context,
        rule,
        'coverUrl',
        vars: vars,
      ),
      categories: _splitCategories(
        await _value(document, context, rule, 'kind', jsVariables: vars),
      ),
      latestChapter: _nullable(
        await _value(document, context, rule, 'lastChapter', jsVariables: vars),
      ),
    );
  }

  Future<LegadoResponse> _request(
    LegadoBookSource source,
    String template, {
    Map<String, String> variables = const {},
  }) async {
    final expanded = await _expandTemplate(
      template,
      variables,
      source.baseUri,
    );
    return _transport.send(
      LegadoRequestTemplate.parse(
        expanded,
        baseUri: source.baseUri,
        variables: const {},
        sourceHeaders: await _sourceHeaders(source),
      ),
    );
  }

  /// 展开 URL 模板：`@js:`/`<js>` 脚本段与内置变量静态替换，剩余
  /// `{{}}` 表达式走 JS。JS 引擎不可用时脚本段保持原样，由请求
  /// 解析器给出可诊断错误（这类源会被导入校验标记为不可运行）。
  Future<String> _expandTemplate(
    String template,
    Map<String, String> variables,
    Uri baseUri,
  ) async {
    var working = template.trim();
    final jsVariables = {
      'key': variables['key'] ?? '',
      'page': variables['page'] ?? '',
      'baseUrl': baseUri.toString(),
      'host': baseUri.host,
      'title': variables['title'] ?? '',
    };

    // `@js:` 前缀：整个地址是一条 JS 语句，求值结果即 URL。
    if (working.toLowerCase().startsWith('@js:')) {
      final engine = LegadoJsEngine.instance;
      if (engine != null) {
        try {
          final value = await engine.evaluateExpression(
            working.substring(4),
            jsVariables,
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
        for (final match
            in RegExp(r'<js>([\s\S]*?)</js>')
                .allMatches(working)
                .toList()) {
          try {
            final value = await engine.evaluateExpression(
              match.group(1)!,
              jsVariables,
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
    final unresolved = RegExp(r'\{\{\s*([^{}]+?)\s*\}\}')
        .allMatches(expanded)
        .toList();
    if (unresolved.isEmpty) return expanded;
    final engine = LegadoJsEngine.instance;
    if (engine == null) return expanded;
    for (final match in unresolved) {
      final expression = match.group(1)!.trim();
      try {
        final value = await engine.evaluateExpression(
          expression,
          jsVariables,
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

  static String _stringOrEmpty(Object? value) =>
      value is String ? value : '';

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
          final evaluated = await engine.evaluateExpression(
            '($raw)',
            {'baseUrl': source.baseUri.toString()},
          );
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
    );
  }

  Future<String> _url(
    LegadoRuleDocument document,
    Object? context,
    Map<String, dynamic> rules,
    String key, {
    Map<String, Object?> jsVariables = const {},
  }) async {
    final rule = _optionalRule(rules, key);
    if (rule.isEmpty) return '';
    return _rules.evaluateString(
      document,
      context,
      rule,
      resolveUrl: true,
      jsVariables: jsVariables,
    );
  }

  Future<Uri?> _uriValue(
    LegadoRuleDocument document,
    Object? context,
    Map<String, dynamic> rules,
    String key, {
    Map<String, Object?> vars = const {},
  }) async {
    final value = await _url(document, context, rules, key, jsVariables: vars);
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
