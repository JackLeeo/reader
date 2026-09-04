import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:legado_flutter/book_source/analyze/text_pager.dart';

void main() {
  const style = TextStyle(fontSize: 18, height: 1.7);

  TextPaginator make(String body, double w, double h) =>
      TextPaginator(body: body, style: style, size: Size(w, h));

  /// 拼接所有页应还原原文（无丢弃、无重复）。
  String join(List<String> pages) => pages.join('');

  group('TextPaginator', () {
    test('空正文产生一页空页', () {
      final p = make('', 300, 400);
      p.paginate();
      expect(p.pages, ['']);
    });

    test('短文本一页装下，且内容完整还原', () {
      final body = '你好，世界。这是一段很短的正文。';
      final p = make(body, 300, 400);
      p.paginate();
      expect(p.pages.length, 1);
      expect(join(p.pages), body);
    });

    test('长文分多页且按字符完整还原（无丢字）', () {
      final body = List.generate(60, (i) => '第$i段内容。' * 8).join('\n');
      final p = make(body, 300, 300); // 小视口强制分页
      p.paginate();
      expect(p.pages.length, greaterThan(1));
      expect(join(p.pages), body);
    });

    test('视口变大页数变少', () {
      final body = List.generate(40, (i) => '行$i ' * 12).join('');
      final small = make(body, 300, 300);
      small.paginate();
      final big = make(body, 300, 600);
      big.paginate();
      expect(big.pages.length, lessThan(small.pages.length));
    });

    test('每页高度不超过视口（抽样第一页）', () {
      final p = make('一二三四五六七八九十一二三四五六七八九十' * 40, 240, 200);
      p.paginate();
      // 解包首页，度量高度应约等于视口高，不会明显超出。
      final first = p.pages.first;
      final painter = TextPainter(
        text: TextSpan(text: first, style: style),
        textDirection: TextDirection.ltr,
      )..layout(minWidth: 240, maxWidth: 240);
      expect(painter.height, lessThanOrEqualTo(200 + 1));
      painter.dispose();
    });
  });
}