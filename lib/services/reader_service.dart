// 阅读服务 - 用书源规则解析书籍数据
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../models/book.dart';
import '../models/book_source.dart';
import '../models/chapter.dart';
import '../rule_engine/json_selector.dart';
import '../rule_engine/rule_engine.dart';
import '../utils/log.dart';
import 'http_client.dart';

class SearchResult {
  final List<Book> books;
  final bool hasMore;
  final int page;
  SearchResult({required this.books, this.hasMore = false, this.page = 1});
}

class ReaderService {
  final HttpClient _http = HttpClient();

  /// 搜索单本书源
  Future<SearchResult> search(
    BookSource source,
    String keyword, {
    int page = 1,
  }) async {
    if (source.searchUrl.isEmpty) {
      return SearchResult(books: []);
    }
    final url = _buildUrl(source.searchUrl, source.baseUrl, {
      'key': keyword,
      'page': page.toString(),
    });

    Log.i('搜索 [${source.bookSourceName}] $url');
    final resp = await _http.get(url, source: source);
    if (resp.statusCode != 200 || resp.data == null || resp.data!.isEmpty) {
      Log.w('搜索失败 status=${resp.statusCode}');
      return SearchResult(books: []);
    }

    final body = resp.data!;
    final engine = RuleEngine(Uri.parse(url));
    final isJson = body.trimLeft().startsWith('{') || body.trimLeft().startsWith('[');

    if (isJson) {
      return _searchFromJson(engine, source, body, page);
    }
    return _searchFromHtml(engine, source, body, page);
  }

  SearchResult _searchFromHtml(
    RuleEngine engine,
    BookSource source,
    String body,
    int page,
  ) {
    final doc = html_parser.parse(body);
    final bookListRule = source.ruleSearch['bookList']?.toString() ?? '';
    if (bookListRule.isEmpty) return SearchResult(books: []);

    final elements = engine.selectList(doc, bookListRule);
    if (elements.isEmpty) return SearchResult(books: []);

    final books = <Book>[];
    for (final el in elements) {
      try {
        final book = _parseBookFromElement(engine, source, el);
        if (book.name.isNotEmpty) books.add(book);
      } catch (e) {
        Log.w('解析搜索项失败: $e');
      }
    }
    return SearchResult(books: books, hasMore: books.isNotEmpty, page: page);
  }

  SearchResult _searchFromJson(
    RuleEngine engine,
    BookSource source,
    String body,
    int page,
  ) {
    final json = JsonSelector(RuleEngine.parseJson(body));
    final bookListPath = source.ruleSearch['bookList']?.toString() ?? '';
    if (bookListPath.isEmpty) return SearchResult(books: []);

    final items = json.selectList(bookListPath);
    if (items.isEmpty) return SearchResult(books: []);

    final books = <Book>[];
    for (final item in items) {
      final book = _parseBookFromJson(source, item.root);
      if (book.name.isNotEmpty) books.add(book);
    }
    return SearchResult(books: books, hasMore: books.isNotEmpty, page: page);
  }

  Book _parseBookFromElement(
    RuleEngine engine,
    BookSource source,
    dom.Element el,
  ) {
    String get(String field, {bool resolveUrl = false, String def = ''}) {
      final rule = source.ruleSearch[field]?.toString() ?? '';
      if (rule.isEmpty) return def;
      return engine.selectString(html_parser.parse('<html><body></body></html>'), el, rule, resolveUrl: resolveUrl);
    }

    return Book(
      name: get('name', def: '未命名'),
      author: get('author'),
      coverUrl: get('coverUrl', resolveUrl: true),
      intro: get('intro'),
      kind: get('kind'),
      lastChapter: get('lastChapter'),
      wordCount: get('wordCount'),
      tocUrl: get('tocUrl', resolveUrl: true),
      bookUrl: get('bookUrl', resolveUrl: true, def: el.baseUri?.toString() ?? ''),
      sourceId: source.id,
      sourceName: source.bookSourceName,
    );
  }

  Book _parseBookFromJson(BookSource source, dynamic raw) {
    final json = JsonSelector(raw);
    String get(String field, {String def = ''}) {
      final path = source.ruleSearch[field]?.toString() ?? '';
      if (path.isEmpty) return def;
      return json.select(path)?.string ?? def;
    }

    return Book(
      name: get('name', def: '未命名'),
      author: get('author'),
      coverUrl: get('coverUrl'),
      intro: get('intro'),
      kind: get('kind'),
      lastChapter: get('lastChapter'),
      wordCount: get('wordCount'),
      tocUrl: get('tocUrl'),
      bookUrl: get('bookUrl', def: ''),
      sourceId: source.id,
      sourceName: source.bookSourceName,
    );
  }

  /// 探索（按分类浏览）
  Future<SearchResult> explore(
    BookSource source,
    String exploreUrl, {
    int page = 1,
  }) async {
    final url = _buildUrl(exploreUrl, source.baseUrl, {'page': page.toString()});
    Log.i('探索 [${source.bookSourceName}] $url');
    final resp = await _http.get(url, source: source);
    if (resp.statusCode != 200 || resp.data == null) {
      return SearchResult(books: []);
    }
    final body = resp.data!;
    final engine = RuleEngine(Uri.parse(url));
    final isJson = body.trimLeft().startsWith('{') || body.trimLeft().startsWith('[');

    if (isJson) {
      final json = JsonSelector(RuleEngine.parseJson(body));
      final bookListPath = source.ruleExplore['bookList']?.toString() ?? '';
      if (bookListPath.isEmpty) return SearchResult(books: []);
      final items = json.selectList(bookListPath);
      final books = <Book>[];
      for (final item in items) {
        try {
          final book = _parseExploreFromJson(source, item.root);
          if (book.name.isNotEmpty) books.add(book);
        } catch (e) {
          Log.w('解析探索项失败: $e');
        }
      }
      return SearchResult(books: books, hasMore: books.isNotEmpty, page: page);
    }

    final doc = html_parser.parse(body);
    final bookListRule = source.ruleExplore['bookList']?.toString() ?? '';
    if (bookListRule.isEmpty) return SearchResult(books: []);

    final elements = engine.selectList(doc, bookListRule);
    final books = <Book>[];
    for (final el in elements) {
      try {
        final book = _parseExploreFromElement(engine, source, el);
        if (book.name.isNotEmpty) books.add(book);
      } catch (e) {
        Log.w('解析探索项失败: $e');
      }
    }
    return SearchResult(books: books, hasMore: books.isNotEmpty, page: page);
  }

  Book _parseExploreFromElement(
    RuleEngine engine,
    BookSource source,
    dom.Element el,
  ) {
    String get(String field, {bool resolveUrl = false, String def = ''}) {
      final rule = source.ruleExplore[field]?.toString() ?? '';
      if (rule.isEmpty) return def;
      return engine.selectString(html_parser.parse('<html><body></body></html>'), el, rule, resolveUrl: resolveUrl);
    }

    return Book(
      name: get('name', def: '未命名'),
      author: get('author'),
      coverUrl: get('coverUrl', resolveUrl: true),
      intro: get('intro'),
      kind: get('kind'),
      lastChapter: get('lastChapter'),
      wordCount: get('wordCount'),
      tocUrl: get('tocUrl', resolveUrl: true),
      bookUrl: get('bookUrl', resolveUrl: true, def: el.baseUri?.toString() ?? ''),
      sourceId: source.id,
      sourceName: source.bookSourceName,
    );
  }

  Book _parseExploreFromJson(BookSource source, dynamic raw) {
    final json = JsonSelector(raw);
    String get(String field, {String def = ''}) {
      final path = source.ruleExplore[field]?.toString() ?? '';
      if (path.isEmpty) return def;
      return json.select(path)?.string ?? def;
    }

    return Book(
      name: get('name', def: '未命名'),
      author: get('author'),
      coverUrl: get('coverUrl'),
      intro: get('intro'),
      kind: get('kind'),
      lastChapter: get('lastChapter'),
      wordCount: get('wordCount'),
      tocUrl: get('tocUrl'),
      bookUrl: get('bookUrl', def: ''),
      sourceId: source.id,
      sourceName: source.bookSourceName,
    );
  }

  /// 获取书籍详情
  Future<Book> getBookInfo(BookSource source, Book book) async {
    if (book.bookUrl.isEmpty) return book;
    Log.i('获取详情 [${source.bookSourceName}] ${book.bookUrl}');
    final resp = await _http.get(book.bookUrl, source: source);
    if (resp.statusCode != 200 || resp.data == null) return book;

    final body = resp.data!;
    final engine = RuleEngine(Uri.parse(book.bookUrl));
    final isJson = body.trimLeft().startsWith('{') || body.trimLeft().startsWith('[');

    if (isJson) {
      return _parseInfoFromJson(source, body, book);
    }

    final doc = html_parser.parse(body);
    String get(String field, {bool resolveUrl = false, String def = ''}) {
      final rule = source.ruleBookInfo[field]?.toString() ?? '';
      if (rule.isEmpty) return def;
      return engine.selectString(doc, doc.body, rule, resolveUrl: resolveUrl);
    }

    return book.copyWith(
      name: get('name', def: book.name),
      author: get('author', def: book.author),
      coverUrl: get('coverUrl', resolveUrl: true, def: book.coverUrl),
      intro: get('intro', def: book.intro),
      kind: get('kind', def: book.kind),
      lastChapter: get('lastChapter', def: book.lastChapter),
      wordCount: get('wordCount', def: book.wordCount),
      tocUrl: get('tocUrl', resolveUrl: true, def: book.tocUrl),
    );
  }

  Book _parseInfoFromJson(BookSource source, String body, Book book) {
    final json = JsonSelector(RuleEngine.parseJson(body));
    String get(String field, {String def = ''}) {
      final path = source.ruleBookInfo[field]?.toString() ?? '';
      if (path.isEmpty) return def;
      return json.select(path)?.string ?? def;
    }

    return book.copyWith(
      name: get('name', def: book.name),
      author: get('author', def: book.author),
      coverUrl: get('coverUrl', def: book.coverUrl),
      intro: get('intro', def: book.intro),
      kind: get('kind', def: book.kind),
      lastChapter: get('lastChapter', def: book.lastChapter),
      wordCount: get('wordCount', def: book.wordCount),
      tocUrl: get('tocUrl', def: book.tocUrl),
    );
  }

  /// 获取章节目录
  Future<List<Chapter>> getToc(BookSource source, Book book) async {
    String tocUrl = book.tocUrl.isNotEmpty ? book.tocUrl : book.bookUrl;
    if (tocUrl.isEmpty) return [];

    Log.i('获取目录 [${source.bookSourceName}] $tocUrl');
    final resp = await _http.get(tocUrl, source: source);
    if (resp.statusCode != 200 || resp.data == null) return [];

    final body = resp.data!;
    final engine = RuleEngine(Uri.parse(tocUrl));
    final isJson = body.trimLeft().startsWith('{') || body.trimLeft().startsWith('[');

    if (isJson) {
      return _parseTocFromJson(source, body);
    }

    final doc = html_parser.parse(body);
    final chapterListRule = source.ruleToc['chapterList']?.toString() ?? '';
    if (chapterListRule.isEmpty) return [];

    final elements = engine.selectList(doc, chapterListRule);
    final chapters = <Chapter>[];
    int idx = 0;
    for (final el in elements) {
      final name = engine.selectString(
        doc,
        el,
        source.ruleToc['chapterName']?.toString() ?? '@text',
      );
      var url = engine.selectString(
        doc,
        el,
        source.ruleToc['chapterUrl']?.toString() ?? '@href',
        resolveUrl: true,
      );
      // 若URL为空，使用bookUrl（某些源把所有章节塞到同一URL）
      if (url.isEmpty) {
        url = book.bookUrl;
      }
      if (name.isEmpty && url.isEmpty) continue;
      chapters.add(Chapter(title: name, url: url, index: idx++));
    }
    Log.i('获取目录完成: ${chapters.length} 章');
    return chapters;
  }

  List<Chapter> _parseTocFromJson(BookSource source, String body) {
    final json = JsonSelector(RuleEngine.parseJson(body));
    final listPath = source.ruleToc['chapterList']?.toString() ?? '';
    if (listPath.isEmpty) return [];

    final items = json.selectList(listPath);
    final chapters = <Chapter>[];
    int idx = 0;
    for (final item in items) {
      final name = item.select(source.ruleToc['chapterName']?.toString() ?? '')?.string ?? '';
      final url = item.select(source.ruleToc['chapterUrl']?.toString() ?? '')?.string ?? '';
      if (name.isEmpty && url.isEmpty) continue;
      chapters.add(Chapter(title: name, url: url, index: idx++));
    }
    return chapters;
  }

  /// 获取章节内容
  Future<String> getContent(BookSource source, String chapterUrl) async {
    if (chapterUrl.isEmpty) return '';
    Log.i('获取内容 [${source.bookSourceName}] $chapterUrl');
    final resp = await _http.get(chapterUrl, source: source);
    if (resp.statusCode != 200 || resp.data == null) return '';

    final body = resp.data!;
    final engine = RuleEngine(Uri.parse(chapterUrl));
    final isJson = body.trimLeft().startsWith('{') || body.trimLeft().startsWith('[');

    String content;
    if (isJson) {
      final json = JsonSelector(RuleEngine.parseJson(body));
      final contentPath = source.ruleContent['content']?.toString() ?? '';
      content = json.select(contentPath)?.string ?? '';
    } else {
      final doc = html_parser.parse(body);
      content = engine.selectString(
        doc,
        doc.body,
        source.ruleContent['content']?.toString() ?? '@text',
      );
    }

    // 应用替换规则
    final replace = source.ruleContent['replaceRegex']?.toString() ?? '';
    if (replace.isNotEmpty && content.isNotEmpty) {
      content = _applyReplaceRules(content, replace);
    }

    return content.trim();
  }

  /// 应用##pattern##replacement 链式替换
  String _applyReplaceRules(String input, String rule) {
    var result = input;
    for (final part in rule.split('\n')) {
      final t = part.trim();
      if (t.isEmpty) continue;
      final match = RegExp(r'^##(.+?)(##(.*))?$', dotAll: true).firstMatch(t);
      if (match == null) continue;
      final pattern = match.group(1)!;
      final replacement = match.group(3) ?? '';
      try {
        result = result.replaceAll(RegExp(pattern, multiLine: true, dotAll: true), replacement);
      } catch (_) {
        // 正则无效则跳过
      }
    }
    return result;
  }

  /// 构建URL（处理 {{key}} {{page}} 占位符）
  String _buildUrl(String template, String baseUrl, Map<String, String> params) {
    var url = template;
    // 替换 {{var}}
    for (final entry in params.entries) {
      url = url.replaceAll('{{${entry.key}}}', Uri.encodeComponent(entry.value));
    }
    // 处理 search.html?searchkey={{key}} 这种形式
    // 如果URL不是绝对的，则与baseUrl合并
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      if (url.startsWith('/')) {
        url = '$baseUrl$url';
      } else {
        url = '$baseUrl/$url';
      }
    }
    return url;
  }
}
