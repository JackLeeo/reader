import 'package:flutter_test/flutter_test.dart';
import 'package:legado_flutter/book_source/analyze/analyze_rule.dart';

void main() {
  group('CSS 元素索引/筛选（对标官方 ElementsSingle）', () {
    late AnalyzeRule rule;

    setUp(() {
      rule = AnalyzeRule();
    });

    const html = '''
<html><body>
<div class="list">
  <a class="item" href="/1"><span>一</span></a>
  <a class="item" href="/2"><span>二</span></a>
  <a class="item" href="/3"><span>三</span></a>
  <a class="item" href="/4"><span>四</span></a>
</div>
</body></html>
''';

    test('.N 取单个', () {
      rule.setContent(html);
      expect(rule.getString(r'a.item.0@text'), '一');
      expect(rule.getString(r'a.item.2@text'), '三');
    });

    test('负索引 .-1 取末', () {
      rule.setContent(html);
      expect(rule.getString(r'a.item.-1@text'), '四');
    });

    test('!N 排除', () {
      rule.setContent(html);
      final names = rule.getStringList(r'a.item!0@text');
      expect(names, ['二', '三', '四']);
    });

    test('区间 a.item.0:2@ 文本', () {
      rule.setContent(html);
      expect(rule.getString(r'a.item.0:2@text'), '一');
      final names = rule.getStringList(r'a.item.0:2@text');
      expect(names, ['一', '二', '三']);
    });

    test('-1:0 反向', () {
      rule.setContent(html);
      final names = rule.getStringList(r'a.item.-1:0@text');
      expect(names, ['四', '三', '二', '一']);
    });

    test('[] 索引列表', () {
      rule.setContent(html);
      final names = rule.getStringList(r'a.item[0,2]@text');
      expect(names, ['一', '三']);
    });

    test('[] 范围 [1, 2:3]', () {
      rule.setContent(html);
      final names = rule.getStringList(r'a.item[1,2:3]@text');
      expect(names, ['二', '三', '四']);
    });
  });

  group('CSS 组合语法 && / || / %%', () {
    late AnalyzeRule rule;

    setUp(() {
      rule = AnalyzeRule();
    });

    const html = '''
<html><body>
<div class="a">A1</div>
<div class="b">B1</div>
<div class="a">A2</div>
</body></html>
''';

    test('&& 并集', () {
      rule.setContent(html);
      final names = rule.getStringList(r'div.a && div.b@text');
      expect(names, ['A1', 'A2', 'B1']);
    });

    test('|| 或（前非空短路）', () {
      rule.setContent(html);
      final names = rule.getStringList(r'div.a || div.none@text');
      expect(names, ['A1', 'A2']);
    });
  });
}