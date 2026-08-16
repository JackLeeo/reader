// 文件说明：阅读链路修复的回归测试。
// 覆盖：详情页只请求一次、分页 404 容错、%% 交替合并、
// URL 模板 @put: 展开、bookUrl 空回退 tocUrl、正文下一页=下一章截断。

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xxread/book_sources/legado/legado_book_source.dart';
import 'package:xxread/book_sources/legado/legado_request.dart';
import 'package:xxread/book_sources/protocol/book_source_protocol.dart';
import 'package:xxread/book_sources/legado/legado_rule_engine.dart';
import 'package:xxread/book_sources/legado/legado_runtime.dart';
import 'package:xxread/book_sources/legado/legado_variable_store.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LegadoVariableStore.instance.clearAll();
  });

  group('LegadoRuleEngine %% merge', () {
    const engine = LegadoRuleEngine();

    test('interleaves parallel list segments', () async {
      final document = LegadoRuleDocument.parse(
        '<div><a href="/1">一</a><a href="/2">二</a>'
        '<span href="/x">甲</span><span href="/y">乙</span></div>',
        Uri.parse('https://books.test/list'),
      );
      final items = await engine.evaluateList(
        document,
        document.value,
        'tag.a@href%%tag.span@href',
      );
      expect(items.map((e) => e.toString()), ['/1', '/x', '/2', '/y']);
    });
  });

  group('reading chain fixes', () {
    test(
      'detail page is fetched once across getBook and getChapters',
      () async {
        final transport = _CountingTransport({
          'https://books.test/book/1': _detailHtml(),
          'https://books.test/toc/1': _tocHtml(page: 1),
        });
        final runtime = LegadoRuntime(transport: transport);
        final registered = _source().toRegisteredSource(enabled: true);

        await runtime.getBook(registered, 'https://books.test/book/1');
        await runtime.getChapters(registered, 'https://books.test/book/1');

        expect(transport.requestCount['https://books.test/book/1'], 1);
        expect(transport.requestCount['https://books.test/toc/1'], 1);
      },
    );

    test('pagination 404 keeps chapters from earlier pages', () async {
      final transport = _CountingTransport({
        'https://books.test/toc': _tocHtml(
          page: 1,
          nextPage: 'https://books.test/toc?page=2',
        ),
      });
      transport.failWith404.add('https://books.test/toc?page=2');
      final runtime = LegadoRuntime(transport: transport);
      final registered = _source().toRegisteredSource(enabled: true);

      final chapters = await runtime.getChapters(
        registered,
        'https://books.test/toc',
      );
      expect(chapters, isNotEmpty);
      expect(chapters.first.title, '第一章');
    });

    test('URL @put: literal is stripped and readable via @get:', () async {
      final transport = _CountingTransport({
        'https://books.test/s?k=abc': _searchHtml(),
      });
      final runtime = LegadoRuntime(transport: transport);
      final registered = _source(
        searchUrl: '/s?k=abc@put:{t:token1}',
        tocUrl: 'class.toc@href',
      ).toRegisteredSource(enabled: true);

      final page = await runtime.search(registered, 'abc');
      expect(page.items, hasLength(1));
      expect(
        LegadoVariableStore.instance.get(
          'https://books.test/s?k=abc@put:{t:token1}',
          'bookSourceUrl',
        ),
        isNull,
      );
      // 变量按源（bookSourceUrl）隔离存储。
      expect(
        LegadoVariableStore.instance.get('https://books.test', 't'),
        'token1',
      );
      expect(
        transport.requests.first.url.toString(),
        'https://books.test/s?k=abc',
      );
    });

    test('bookUrl falling back to tocUrl when empty', () async {
      final transport = _CountingTransport({
        'https://books.test/s?q=x': '''
          <div class="book">
            <h3 class="name">书名</h3>
            <a class="toc" href="/toc/9">目录</a>
          </div>
        ''',
      });
      final runtime = LegadoRuntime(transport: transport);
      final source = _source(
        searchUrl: '/s?q=x',
        bookUrlRule: 'class.missing@href',
        tocUrlRuleInSearch: 'class.toc@href',
      );
      final registered = source.toRegisteredSource(enabled: true);

      final page = await runtime.search(registered, 'x');
      expect(page.items, hasLength(1));
      expect(page.items.first.id, 'https://books.test/toc/9');
    });

    test('content pagination stops when next page is next chapter', () async {
      final transport = _CountingTransport({
        'https://books.test/c/1': '''
          <div id="content">第一页</div>
          <a id="next" href="/c/2">下一页</a>
        ''',
        'https://books.test/c/2': '<div id="content">不应被抓取</div>',
      });
      final runtime = LegadoRuntime(transport: transport);
      final registered = _contentSource().toRegisteredSource(enabled: true);

      final content = await runtime.getChapterContent(
        registered,
        bookId: 'https://books.test/book/1',
        chapterId: 'https://books.test/c/1',
        nextChapterId: 'https://books.test/c/2',
      );
      expect(content.content, contains('第一页'));
      expect(content.content, isNot(contains('不应被抓取')));
      expect(
        transport.requestCount.containsKey('https://books.test/c/2'),
        false,
      );
    });

    test('toc page 404 falls back to the detail page catalog', () async {
      // tocUrl 求值出的目录页 404；详情页自身含章节列表，应回退解析。
      final transport = _CountingTransport({
        'https://books.test/book/1': '''
          <html><body>
            <h1>详情书名</h1>
            <a class="toc" href="/toc/1">目录</a>
            <ul id="chapters">
              <li><a href="/c/1">第一章</a></li>
              <li><a href="/c/2">第二章</a></li>
            </ul>
          </body></html>
        ''',
      });
      transport.failWith404.add('https://books.test/toc/1');
      final runtime = LegadoRuntime(transport: transport);
      final registered = _source().toRegisteredSource(enabled: true);

      final chapters = await runtime.getChapters(
        registered,
        'https://books.test/book/1',
      );
      expect(chapters, hasLength(2));
      expect(chapters.first.title, '第一章');
    });

    test('empty toc page falls back to the detail page catalog', () async {
      // tocUrl 指向的页面解析不出章节；详情页含章节列表，应回退解析。
      final transport = _CountingTransport({
        'https://books.test/book/1': '''
          <html><body>
            <h1>详情书名</h1>
            <a class="toc" href="/toc/1">目录</a>
            <ul id="chapters">
              <li><a href="/c/1">第一章</a></li>
            </ul>
          </body></html>
        ''',
        // 目录页无 #chapters 结构：chapterList 求值为空。
        'https://books.test/toc/1': '<html><body><p>空目录页</p></body></html>',
      });
      final runtime = LegadoRuntime(transport: transport);
      final registered = _source().toRegisteredSource(enabled: true);

      final chapters = await runtime.getChapters(
        registered,
        'https://books.test/book/1',
      );
      expect(chapters, hasLength(1));
      expect(chapters.first.title, '第一章');
    });

    test('empty toc rule never refetches the detail page', () async {
      // tocRule 为空 → 目录页即详情页。getBook 之后即使详情页 URL
      // 被站点拒绝（一次性 token 二次请求 404/403），getChapters 也
      // 必须复用缓存解析，不再发起第二次真实请求。
      final transport = _CountingTransport({
        'https://books.test/book/1': '''
          <html><body>
            <h1>详情书名</h1>
            <ul id="chapters">
              <li><a href="/c/1">第一章</a></li>
              <li><a href="/c/2">第二章</a></li>
            </ul>
          </body></html>
        ''',
      });
      final runtime = LegadoRuntime(transport: transport);
      final registered = _contentSource().toRegisteredSource(enabled: true);

      await runtime.getBook(registered, 'https://books.test/book/1');
      transport.failWith404.add('https://books.test/book/1');
      final chapters = await runtime.getChapters(
        registered,
        'https://books.test/book/1',
      );
      expect(transport.requestCount['https://books.test/book/1'], 1);
      expect(chapters, hasLength(2));
    });

    test('repeated getBook reuses the cached detail page', () async {
      final transport = _CountingTransport({
        'https://books.test/book/1': _detailHtml(),
      });
      final runtime = LegadoRuntime(transport: transport);
      final registered = _source().toRegisteredSource(enabled: true);

      await runtime.getBook(registered, 'https://books.test/book/1');
      transport.failWith404.add('https://books.test/book/1');
      await runtime.getBook(registered, 'https://books.test/book/1');

      expect(transport.requestCount['https://books.test/book/1'], 1);
    });

    test('toc and content requests carry the anti-leech referer', () async {
      // 目录页请求 Referer=详情页；正文请求 Referer=详情页起步、
      // 翻页后逐页前移。防盗链站点缺失 Referer 会 403。
      final transport = _CountingTransport({
        'https://books.test/book/1': _detailHtml(),
        'https://books.test/toc/1': _tocHtml(),
        'https://books.test/c/1': '''
          <html><body><div id="content">正文第一页</div>
          <a id="next" href="/c/1?p=2">下一页</a></body></html>
        ''',
        'https://books.test/c/1?p=2': '''
          <html><body><div id="content">正文第二页</div></body></html>
        ''',
      });
      final runtime = LegadoRuntime(transport: transport);
      final registered = _source().toRegisteredSource(enabled: true);

      await runtime.getChapters(registered, 'https://books.test/book/1');
      final tocRequest = transport.requests.firstWhere(
        (r) => r.url.toString() == 'https://books.test/toc/1',
      );
      expect(tocRequest.referer, 'https://books.test/book/1');

      await runtime.getChapterContent(
        registered,
        bookId: 'https://books.test/book/1',
        chapterId: 'https://books.test/c/1',
      );
      final firstPage = transport.requests.firstWhere(
        (r) => r.url.toString() == 'https://books.test/c/1',
      );
      expect(firstPage.referer, 'https://books.test/book/1');
      final secondPage = transport.requests.firstWhere(
        (r) => r.url.toString() == 'https://books.test/c/1?p=2',
      );
      expect(secondPage.referer, 'https://books.test/c/1');
    });
  });
}

LegadoBookSource _source({
  String searchUrl = '/s?q={{key}}',
  String bookUrlRule = 'tag.a@href',
  String? tocUrlRuleInSearch,
  String tocUrl = 'class.toc@href',
}) {
  return LegadoBookSource.fromJson({
    'bookSourceName': 'chain test',
    'bookSourceUrl': 'https://books.test',
    'searchUrl': searchUrl,
    'ruleSearch': {
      'bookList': 'class.book',
      'name': 'class.name@text',
      'bookUrl': bookUrlRule,
      if (tocUrlRuleInSearch != null) 'tocUrl': tocUrlRuleInSearch,
    },
    'ruleBookInfo': {'name': 'h1@text', 'tocUrl': tocUrl},
    'ruleToc': {
      'chapterList': '#chapters@li',
      'chapterName': 'a@text',
      'chapterUrl': 'a@href',
    },
    'ruleContent': {'content': '#content@html', 'nextContentUrl': '#next@href'},
  });
}

LegadoBookSource _contentSource() {
  return LegadoBookSource.fromJson({
    'bookSourceName': 'content test',
    'bookSourceUrl': 'https://books.test',
    'searchUrl': '/s?q={{key}}',
    'ruleSearch': {
      'bookList': 'class.book',
      'name': 'class.name@text',
      'bookUrl': 'tag.a@href',
    },
    'ruleBookInfo': {'name': 'h1@text'},
    'ruleToc': {
      'chapterList': '#chapters@li',
      'chapterName': 'a@text',
      'chapterUrl': 'a@href',
    },
    'ruleContent': {'content': '#content@html', 'nextContentUrl': '#next@href'},
  });
}

String _detailHtml() => '''
  <html><body>
    <h1>详情书名</h1>
    <a class="toc" href="/toc/1">目录</a>
  </body></html>
''';

String _tocHtml({int page = 1, String? nextPage}) =>
    '''
  <html><body>
    <ul id="chapters">
      <li><a href="/c/1">第一章</a></li>
      <li><a href="/c/2">第二章</a></li>
    </ul>
    ${nextPage == null ? '' : '<a id="next" href="$nextPage">下一页</a>'}
  </body></html>
''';

String _searchHtml() => '''
  <html><body>
    <div class="book">
      <h3 class="name">搜索书名</h3>
      <a href="/book/1">详情</a>
    </div>
  </body></html>
''';

/// 统计请求次数的假传输层；可指定 URL 直接返回 404。
class _CountingTransport implements LegadoTransport {
  _CountingTransport(this.responses);

  final Map<String, String> responses;
  final Map<String, int> requestCount = {};
  final Set<String> failWith404 = {};
  final List<LegadoRequestTemplate> requests = [];

  @override
  Future<LegadoResponse> send(LegadoRequestTemplate request) async {
    final url = request.url.toString();
    requests.add(request);
    requestCount[url] = (requestCount[url] ?? 0) + 1;
    if (failWith404.contains(url)) {
      throw const BookSourceProtocolException(
        'Legado source returned HTTP 404.',
      );
    }
    final body = responses[url];
    if (body == null) {
      throw StateError('Missing fake response for $url');
    }
    return LegadoResponse(body: body, finalUri: request.url);
  }
}
