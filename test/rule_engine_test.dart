import 'package:flutter_test/flutter_test.dart';
import 'package:legado_flutter/book_source/analyze/analyze_rule.dart';
import 'package:legado_flutter/book_source/models/book_source.dart';

void main() {
  group('AnalyzeRule — 规则引擎对标官方', () {
    late AnalyzeRule rule;

    setUp(() {
      rule = AnalyzeRule();
    });

    const html = '''
<html><body>
  <div class="book-list">
    <a class="book-item" href="/book/100.html"><span class="name">斗破苍穹</span></a>
    <a class="book-item" href="/book/200.html"><span class="name">凡人修仙传</span></a>
  </div>
</body></html>
''';

    test('CSS 文本提取', () {
      rule.setContent(html);
      expect(rule.getString(r'div.book-list a.book-item span.name@text##^\s+|\s+$'), '斗破苍穹');
      expect(rule.getString(r'a.book-item span.name'), '斗破苍穹');
    });

    test('CSS 列表提取', () {
      rule.setContent(html);
      final names = rule.getStringList(r'a.book-item span.name');
      expect(names, ['斗破苍穹', '凡人修仙传']);
    });

    test('取属性并归一化 URL', () {
      rule.setContent(html, baseUrl: 'https://www.example.com/catalog/');
      final urls = rule.getStringList(r'a.book-item@href', isUrl: true);
      expect(urls, ['https://www.example.com/book/100.html', 'https://www.example.com/book/200.html']);
    });

    test('@@ 前缀 = CSS', () {
      rule.setContent(html);
      expect(rule.getString(r'@@a.book-item span.name'), '斗破苍穹');
    });

    test('多段链 / ## 替换', () {
      rule.setContent(html);
      expect(rule.getString(r'a.book-item span.name##破##X'), '斗X苍穹');
    });

    test('XPath 提取', () {
      rule.setContent(html);
      expect(rule.getString(r'//span[@class="name"]'), '斗破苍穹');
      expect(rule.getString('@XPath://span/text()'), '斗破苍穹');
    });

    test('JSONPath 提取', () {
      rule.setContent({
        'data': {'list': [{'title': '书的标题', 'url': '/x/1'}]},
      });
      expect(rule.getString(r'$.data.list[0].title'), '书的标题');
      expect(rule.getString(r'@Json:$.data.list[0].title'), '书的标题');
    });

    test('@put: 保存变量', () {
      rule.setContent(html);
      final s = rule.getString(r'a.book-item span.name@text@put:{"name":"a.book-item span.name@text"}');
      expect(rule.get('name'), '斗破苍穹');
      expect(s, '斗破苍穹');
    });

    test('正则 ## 替换', () {
      rule.setContent(html);
      expect(rule.getString(r'a.book-item span.name##^\s+|\s+$##'), '斗破苍穹');
      expect(rule.getString('div:last()'), '');
    });

    test('JS 不可用时 {{}} 透传为空', () {
      rule.setContent(html);
      // 未接入 JS 引擎：{{...}} 解析为空串
      expect(rule.getString(r'{{rule.something}}/abc'), '/abc');
    });

    test('@js: 真实执行（纯 Dart 解释器）', () {
      rule.setContent('http://www.test.com/a 百度/');
      expect(rule.getString(r'@js:result.replace("百度","知道")'), 'http://www.test.com/a 知道/');
    });

    test('<js> 变量拼接', () {
      rule.put('chap', '第1章');
      rule.setContent('x');
      expect(rule.getString(r'<js>chap + " 标题"</js>'), '第1章 标题');
    });

    test('@js: 引用 jsLib 函数', () {
      final src = AnalyzeRule(
        source: BookSource.fromJson({
          'bookSourceUrl': 'jslib.com',
          'jsLib': 'function cat(a,b){return a+"-"+b;}',
        }),
      );
      src.setContent('x');
      expect(src.getString(r'@js:cat("甲","乙")'), '甲-乙');
    });
  });
}