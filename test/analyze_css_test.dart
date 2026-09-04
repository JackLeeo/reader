import 'package:flutter_test/flutter_test.dart';

import 'package:legado_flutter/book_source/analyze/analyze_css.dart';
import 'package:legado_flutter/book_source/entities/source_rule.dart';

void main() {
  group('Legado 传统前缀选择器转译', () {
    const html = '<div class="slist">'
        '<a class="itemname" href="/novel/1.html">天龙八部之风流</a>'
        '<span class="author">佚名</span>'
        '</div>'
        '<div class="slist">'
        '<a class="itemname" href="/novel/2.html">射雕英雄传</a>'
        '<span class="author">金庸</span>'
        '</div>';

    test('class.xxx 转译为 .xxx 并命中元素', () {
      const ctx = RuleTextValue(html);
      final els = AnalyzeCss.getElements(ctx, 'class.slist');
      expect(els.length, 2);
      // 取第一条文本校验结构正确
      final name = AnalyzeCss.getString(ctx, 'class.slist class.itemname@text');
      expect(name, '天龙八部之风流');
    });

    test('class.itemname@href 取书名链接', () {
      const ctx = RuleTextValue(html);
      final url = AnalyzeCss.getString(ctx, 'class.slist class.itemname@href');
      expect(url, '/novel/1.html');
    });

    test('tag. 前缀转译为标签', () {
      const ctx = RuleTextValue(html);
      final els = AnalyzeCss.getElements(ctx, 'tag.a');
      expect(els.length, 2);
      expect(els.first.element.localName, 'a');
    });

    test('组合元素逐条提取', () {
      const ctx = RuleTextValue(html);
      expect(AnalyzeCss.getElements(ctx, 'class.slist').length, 2);
      final names = AnalyzeCss.getStringList(ctx, 'class.slist class.itemname@text');
      expect(names, ['天龙八部之风流', '射雕英雄传']);
    });
  });
}