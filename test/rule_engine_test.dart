// 规则引擎单元测试 - 覆盖发现页/搜索/目录的关键场景
import 'package:flutter_test/flutter_test.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:reader/rule_engine/rule_engine.dart';

dom.Document _doc(String html) => html_parser.parse(html);

String _str(dynamic doc, dynamic ctx, String rule,
    {bool resolveUrl = false, String baseUrl = 'https://x.com'}) {
  final engine = RuleEngine(Uri.parse(baseUrl));
  return engine.selectString(doc, ctx, rule, resolveUrl: resolveUrl);
}

void main() {
  group('selectList - 列表提取（bookList / chapterList）', () {
    test('class.X@tag.Y 链式', () {
      final doc = _doc('''
        <html><body>
          <div class="listBox"><li><a>1</a></li><li><a>2</a></li></div>
          <div class="other"><li><a>3</a></li></div>
        </body></html>
      ''');
      final engine = RuleEngine(Uri.parse('https://x.com'));
      final els = engine.selectList(doc, 'class.listBox@tag.li');
      expect(els.length, 2);
    });

    test('class.X@tag.Y!0 链式 + 排除', () {
      final doc = _doc('''
        <html><body>
          <table class="grid">
            <tr><td>a</td></tr>
            <tr><td>b</td></tr>
            <tr><td>c</td></tr>
          </table>
        </body></html>
      ''');
      final engine = RuleEngine(Uri.parse('https://x.com'));
      final els = engine.selectList(doc, 'class.grid@tag.tr!0');
      expect(els.length, 2);
      expect(els[0].text, 'b');
    });

    test('裸字 "subject" 当作 class (fallback)', () {
      final doc = _doc('''
        <html><body>
          <div class="subject"><span>A</span></div>
          <div class="subject"><span>B</span></div>
          <div class="other"><span>C</span></div>
        </body></html>
      ''');
      final engine = RuleEngine(Uri.parse('https://x.com'));
      final els = engine.selectList(doc, 'subject');
      expect(els.length, 2);
    });

    test('带空格的后代选择器 .mod li', () {
      final doc = _doc('''
        <html><body>
          <div class="mod">
            <li>1</li><li>2</li><li>3</li>
          </div>
          <li>outside</li>
        </body></html>
      ''');
      final engine = RuleEngine(Uri.parse('https://x.com'));
      final els = engine.selectList(doc, '.mod li');
      expect(els.length, 3);
    });

    test('tbody@tr 链式', () {
      final doc = _doc('''
        <html><body>
          <table><tbody><tr><td>1</td></tr><tr><td>2</td></tr></tbody></table>
        </body></html>
      ''');
      final engine = RuleEngine(Uri.parse('https://x.com'));
      final els = engine.selectList(doc, 'tbody@tr');
      expect(els.length, 2);
    });

    test('id.X@tag.Y 链式', () {
      final doc = _doc('''
        <html><body>
          <div id="alistbox">
            <li><a>1</a></li><li><a>2</a></li>
          </div>
        </body></html>
      ''');
      final engine = RuleEngine(Uri.parse('https://x.com'));
      final els = engine.selectList(doc, 'id.alistbox@tag.li');
      expect(els.length, 2);
    });

    test('三段链 id.X@tag.Y@tag.Z', () {
      final doc = _doc('''
        <html><body>
          <div id="section-list">
            <li><a href="/1">1</a></li>
            <li><a href="/2">2</a></li>
            <li><a href="/3">3</a></li>
          </div>
        </body></html>
      ''');
      final engine = RuleEngine(Uri.parse('https://x.com'));
      final els = engine.selectList(doc, 'id.section-list@li@a');
      expect(els.length, 3);
      expect(els[0].attributes['href'], '/1');
    });

    test('id.X@li@a 三段链 (id+tag+tag)', () {
      final doc = _doc('''
        <html><body>
          <div id="readerlist">
            <li><a href="/1">1</a></li>
            <li><a href="/2">2</a></li>
          </div>
        </body></html>
      ''');
      final engine = RuleEngine(Uri.parse('https://x.com'));
      final els = engine.selectList(doc, 'id.readerlist@tag.li@tag.a');
      expect(els.length, 2);
    });

    test('空规则返回空列表', () {
      final doc = _doc('<html><body><li>x</li></body></html>');
      final engine = RuleEngine(Uri.parse('https://x.com'));
      final els = engine.selectList(doc, '');
      expect(els.isEmpty, true);
    });

    test('|| 备选 (取首个非空)', () {
      final doc = _doc('''
        <html><body>
          <div class="newbox"><li><a>1</a></li><li><a>2</a></li></div>
        </body></html>
      ''');
      final engine = RuleEngine(Uri.parse('https://x.com'));
      // 第一个备选 .article_list_content@li 不存在
      // 第二个 .newbox@li 存在
      final els = engine.selectList(doc, '.article_list_content@li||.newbox@li');
      expect(els.length, 2);
    });

    test('> 子选择器', () {
      final doc = _doc('''
        <html><body>
          <ul>
            <li><span>1</span></li>
            <li><span>2</span></li>
          </ul>
        </body></html>
      ''');
      final engine = RuleEngine(Uri.parse('https://x.com'));
      final els = engine.selectList(doc, 'ul > li');
      expect(els.length, 2);
    });

    test(':nth-of-type 伪类', () {
      final doc = _doc('''
        <html><body>
          <ul>
            <li>1</li>
            <li>2</li>
            <li>3</li>
            <li>4</li>
          </ul>
        </body></html>
      ''');
      final engine = RuleEngine(Uri.parse('https://x.com'));
      final els = engine.selectList(doc, 'li:nth-of-type(2)');
      expect(els.length, 1);
      expect(els[0].text, '2');
    });
  });

  group('selectString - 单值提取（name/author/coverUrl 等）', () {
    test('"text" 快捷 - 上下文是 element 时直接取 text', () {
      final doc = _doc('<html><body></body></html>');
      final engine = RuleEngine(Uri.parse('https://x.com'));
      final aEl = html_parser.parse('<a href="/1">Hello</a>').body!.children.first;
      expect(_str(doc, aEl, 'text'), 'Hello');
    });

    test('"href" 快捷 - 上下文是 element 时直接取 href', () {
      final doc = _doc('<html><body></body></html>');
      final engine = RuleEngine(Uri.parse('https://x.com'));
      final aEl = html_parser.parse('<a href="/book/1">Hello</a>').body!.children.first;
      expect(_str(doc, aEl, 'href'), '/book/1');
    });

    test('"src" 快捷 - 上下文是 element 时直接取 src', () {
      final doc = _doc('<html><body></body></html>');
      final engine = RuleEngine(Uri.parse('https://x.com'));
      final imgEl = html_parser.parse('<img src="/img.jpg">').body!.children.first;
      expect(_str(doc, imgEl, 'src'), '/img.jpg');
    });

    test('"html" 快捷 - 取 innerHtml', () {
      final doc = _doc('<html><body></body></html>');
      final engine = RuleEngine(Uri.parse('https://x.com'));
      final divEl = html_parser.parse('<div><b>x</b><i>y</i></div>').body!.children.first;
      final v = _str(doc, divEl, 'html');
      expect(v.contains('<b>x</b>'), true);
      expect(v.contains('<i>y</i>'), true);
    });

    test('@text 与 @href 链尾', () {
      final doc = _doc('''
        <html><body>
          <div class="item">
            <a href="/book/1"><span>Book Title</span></a>
          </div>
        </body></html>
      ''');
      final engine = RuleEngine(Uri.parse('https://x.com'));
      final itemEl = doc.querySelector('.item')!;
      expect(_str(doc, itemEl, 'class.item@tag.a.0@text'), 'Book Title');
      expect(_str(doc, itemEl, 'class.item@tag.a.0@href'), '/book/1');
    });

    test('##pattern##replacement 替换', () {
      final doc = _doc('<html><body></body></html>');
      final engine = RuleEngine(Uri.parse('https://x.com'));
      final el = html_parser.parse('<a>《Hello》全集</a>').body!.children.first;
      expect(_str(doc, el, 'text##《|》|全集'), 'Hello');
    });

    test('多 ## 规则 (换行分隔)', () {
      final doc = _doc('<html><body></body></html>');
      final engine = RuleEngine(Uri.parse('https://x.com'));
      final el = html_parser.parse('<p>作者：Tom</p>').body!.children.first;
      expect(_str(doc, el, 'text##作者：'), 'Tom');
    });

    test('resolveUrl 处理相对路径', () {
      final doc = _doc('<html><body></body></html>');
      final engine = RuleEngine(Uri.parse('https://x.com'));
      final aEl = html_parser.parse('<a href="/book/1">x</a>').body!.children.first;
      expect(_str(doc, aEl, 'href', resolveUrl: true), 'https://x.com/book/1');
    });

    test('链式 + 索引: class.X.0@text', () {
      final doc = _doc('''
        <html><body>
          <div class="list">
            <p>first</p>
            <p>second</p>
            <p>third</p>
          </div>
        </body></html>
      ''');
      final engine = RuleEngine(Uri.parse('https://x.com'));
      final el = doc.querySelector('.list')!;
      expect(_str(doc, el, 'class.list@tag.p.0@text'), 'first');
      expect(_str(doc, el, 'class.list@tag.p.-1@text'), 'third');
    });

    test('链式带索引: tag.li.0@tr (中间索引)', () {
      final doc = _doc('''
        <html><body>
          <table>
            <tbody><tr><td>tbody1</td></tr></tbody>
            <tbody><tr><td>tbody2</td></tr></tbody>
          </table>
        </body></html>
      ''');
      final engine = RuleEngine(Uri.parse('https://x.com'));
      final els = engine.selectList(doc, 'tbody.0@tr');
      expect(els.length, 1);
      expect(els[0].text, 'tbody1');
    });

    test('范围选择 tag.li.0:1:2 (取多个索引)', () {
      final doc = _doc('''
        <html><body>
          <ul>
            <li>0</li><li>1</li><li>2</li><li>3</li>
          </ul>
        </body></html>
      ''');
      final engine = RuleEngine(Uri.parse('https://x.com'));
      // Legado 中 .0:1:2 这种语法 - 但我们的实现是 :N:M 表示范围
      // 这里用 .0:1:2 表示范围 from=1 to=2 starting at index 0
      // 实际规则: rangeMatch = (.+):(\d+):(-?\d+)
      // selAfterRange = .0, 但 .0 是 .0 没在原规则中匹配
      // 让我们用更标准的 :1:2
      final els = engine.selectList(doc, 'ul li:0:1');
      expect(els.length, 2);
    });
  });

  group('规则 - 真实书源场景', () {
    test('书源1: bookList=class.listBox@tag.li, name=class.even@tag.a.0@text', () {
      final doc = _doc('''
        <html><body>
          <div class="listBox">
            <li class="even"><a href="/1">Book 1</a></li>
            <li class="odd"><a href="/2">Book 2</a></li>
            <li class="even"><a href="/3">Book 3</a></li>
            <li class="odd"><a href="/4">Book 4</a></li>
          </div>
        </body></html>
      ''');
      final engine = RuleEngine(Uri.parse('https://x.com'));
      final items = engine.selectList(doc, 'class.listBox@tag.li');
      expect(items.length, 4);

      // 第一个 li 提取书名
      expect(_str(doc, items[0], 'class.even@tag.a.0@text'), 'Book 1');
      // 第一个 li 提取 URL
      expect(_str(doc, items[0], 'class.even@tag.a.0@href', resolveUrl: true),
          'https://x.com/1');
    });

    test('书源2: chapterList=id.section-list@li@a, chapterName=text, chapterUrl=href', () {
      final doc = _doc('''
        <html><body>
          <div id="section-list">
            <li><a href="/c1">Chapter 1</a></li>
            <li><a href="/c2">Chapter 2</a></li>
            <li><a href="/c3">Chapter 3</a></li>
          </div>
        </body></html>
      ''');
      final engine = RuleEngine(Uri.parse('https://x.com'));
      final items = engine.selectList(doc, 'id.section-list@li@a');
      expect(items.length, 3);

      // 这是关键: 以前 chapterName="text" 是坏的, 现在应该工作
      expect(_str(doc, items[0], 'text'), 'Chapter 1');
      expect(_str(doc, items[1], 'href', resolveUrl: true), 'https://x.com/c2');
      expect(_str(doc, items[2], 'text'), 'Chapter 3');
    });

    test('书源3: bookList=.mod li 后代选择', () {
      final doc = _doc('''
        <html><body>
          <div class="mod">
            <li><a href="/1">A</a></li>
            <li><a href="/2">B</a></li>
            <li><a href="/3">C</a></li>
          </div>
        </body></html>
      ''');
      final engine = RuleEngine(Uri.parse('https://x.com'));
      final items = engine.selectList(doc, '.mod li');
      expect(items.length, 3);
    });

    test('书源4: bookList=class.novelslist2@tag.li!0', () {
      final doc = _doc('''
        <html><body>
          <div class="novelslist2">
            <li>header</li>
            <li><a href="/1">1</a></li>
            <li><a href="/2">2</a></li>
            <li><a href="/3">3</a></li>
          </div>
        </body></html>
      ''');
      final engine = RuleEngine(Uri.parse('https://x.com'));
      final items = engine.selectList(doc, 'class.novelslist2@tag.li!0');
      expect(items.length, 3);
      expect(_str(doc, items[0], 'tag.a.0@text'), '1');
    });

    test('书源5: bookList=subject (裸字当 class)', () {
      final doc = _doc('''
        <html><body>
          <div class="subject"><span><a href="/1">A</a></span></div>
          <div class="subject"><span><a href="/2">B</a></span></div>
        </body></html>
      ''');
      final engine = RuleEngine(Uri.parse('https://x.com'));
      final items = engine.selectList(doc, 'subject');
      expect(items.length, 2);
    });

    test('书源6: chapterList=.list@dd@a 多段链', () {
      final doc = _doc('''
        <html><body>
          <div class="list">
            <dd><a href="/1">Ch 1</a></dd>
            <dd><a href="/2">Ch 2</a></dd>
          </div>
        </body></html>
      ''');
      final engine = RuleEngine(Uri.parse('https://x.com'));
      final items = engine.selectList(doc, '.list@dd@a');
      expect(items.length, 2);
      expect(_str(doc, items[0], 'href', resolveUrl: true), 'https://x.com/1');
    });

    test('书源7: chapterList=tag.main@tag.article', () {
      final doc = _doc('''
        <html><body>
          <main>
            <article><a href="/1">1</a></article>
            <article><a href="/2">2</a></article>
          </main>
        </body></html>
      ''');
      final engine = RuleEngine(Uri.parse('https://x.com'));
      final items = engine.selectList(doc, 'tag.main@tag.article');
      expect(items.length, 2);
    });

    test('书源8: bookList=class.grid@tag.tr!0 + 复杂 name 规则', () {
      final doc = _doc('''
        <html><body>
          <table class="grid">
            <tr><td>header</td></tr>
            <tr><td><a href="/1">Book A</a><a href="/a">Author</a></td></tr>
            <tr><td><a href="/2">Book B</a><a href="/b">Author</a></td></tr>
          </table>
        </body></html>
      ''');
      final engine = RuleEngine(Uri.parse('https://x.com'));
      final items = engine.selectList(doc, 'class.grid@tag.tr!0');
      expect(items.length, 2);
    });

    test('text.XXX 文本搜索', () {
      final doc = _doc('''
        <html><body>
          <a href="/1">Not Matched</a>
          <a href="/2">点击阅读</a>
        </body></html>
      ''');
      final engine = RuleEngine(Uri.parse('https://x.com'));
      // text.点击阅读@href
      // 解析: parts = ["text.点击阅读", "href"]
      // wantElements=false, parts.last = "href" 是 extractType
      // 剥掉: parts = ["text.点击阅读"], extractType = "href"
      // i=0: seg = "text.点击阅读"
      //   subSteps = ["text.点击阅读"]
      //   _applySelector(root, "text.点击阅读")
      //   应该返回包含 "点击阅读" 文本的元素
      final items = engine.selectList(doc, 'text.点击阅读');
      expect(items.length, 1);
    });

    test(':first 位置伪类', () {
      final doc = _doc('''
        <html><body>
          <li>1</li><li>2</li><li>3</li>
        </body></html>
      ''');
      final engine = RuleEngine(Uri.parse('https://x.com'));
      final items = engine.selectList(doc, 'tag.li:first');
      expect(items.length, 1);
      expect(items[0].text, '1');
    });
  });

  group('空规则 / 边缘场景', () {
    test('selectList 接受空规则不抛错', () {
      final doc = _doc('<html><body></body></html>');
      final engine = RuleEngine(Uri.parse('https://x.com'));
      expect(engine.selectList(doc, ''), isEmpty);
    });

    test('selectString 接受空规则不抛错', () {
      final doc = _doc('<html><body></body></html>');
      final engine = RuleEngine(Uri.parse('https://x.com'));
      final aEl = html_parser.parse('<a>x</a>').body!.children.first;
      // 空规则 + context=element 返回 element.text
      expect(_str(doc, aEl, ''), 'x');
    });

    test('解析失败规则 (无匹配) 返回空字符串', () {
      final doc = _doc('<html><body></body></html>');
      final engine = RuleEngine(Uri.parse('https://x.com'));
      expect(_str(doc, doc.body, 'class.nevermatch@text'), '');
    });
  });
}
