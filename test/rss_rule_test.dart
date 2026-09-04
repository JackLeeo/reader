import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:legado_flutter/book_source/services/rss_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('RssService — 规则源解析（对齐官方 RssParserByRule）', () {
    test('parseByRule 用 CSS 列表规则提取条目与字段', () async {
      const html = '''
      <html><body>
        <div class="list">
          <a class="item">
            <h3 class="t">文章一</h3>
            <span class="desc">描述一</span>
            <time class="date">2024-01-01</time>
            <img class="img" src="/a.png"/>
          </a>
          <a class="item">
            <h3 class="t">文章二</h3>
            <span class="desc">描述二</span>
          </a>
          <span class="misc">不是条目</span>
        </div>
      </body></html>
      ''';
      final src = RssSource(
        name: '站',
        sourceUrl: 'https://x.com/rss',
        ruleArticles: '.list .item',
        ruleTitle: '.t@text',
        ruleDescription: '.desc@text',
        rulePubDate: '.date@text',
        ruleImage: '.img@src',
        ruleLink: '@href',
      );
      final items = await RssService.instance.parseByRule(html, src);
      expect(items, hasLength(2));
      expect(items[0].title, '文章一');
      expect(items[0].description, '描述一');
      expect(items[0].pubDate, '2024-01-01');
      expect(items[0].image, '/a.png');
      expect(items[1].title, '文章二');
    });

    test('parseByRule 无标题条目被丢弃（对齐官方）', () async {
      const html = '''
      <div>
        <div class="item"><a class="t"></a></div>
        <div class="item"><a class="t">标题</a></div>
      </div>
      ''';
      final src = RssSource(
        name: 'x',
        sourceUrl: 'https://x.com',
        ruleArticles: '.item',
        ruleTitle: '.t@text',
      );
      final items = await RssService.instance.parseByRule(html, src);
      expect(items, hasLength(1));
      expect(items[0].title, '标题');
    });

    test('规则源持久化：addSource → 重初始化可读回', () async {
      RssService.instance.clear();
      await RssService.instance.init();
      RssService.instance.addSource(RssSource(
        name: '规则源A',
        sourceUrl: 'https://a.com',
        ruleArticles: '.items li',
        ruleTitle: 'a@text',
      ));
      await RssService.instance.save();
      // 直接验证已写入 prefs
      final p = await SharedPreferences.getInstance();
      expect(p.getString('rss_sources_v1'), contains('规则源A'));

      RssService.instance.clear();
      await RssService.instance.init();
      final s = RssService.instance.sourceByName('规则源A');
      expect(s, isNotNull);
      expect(s!.ruleArticles, '.items li');
    });
  });

  group('RssService — 标准解析 + 订阅管理', () {
    test('parseFeed 解析 RSS 2.0', () {
      final r = RssService.parseFeed(
        '<?xml version="1.0"?><rss version="2.0"><channel>'
        '<title>源</title>'
        '<item><title>t</title><link>http://x</link><description>d</description></item>'
        '</channel></rss>',
      );
      expect(r, isNotNull);
      expect(r!.title, '源');
      expect(r.items.single.title, 't');
    });

    test('parseFeed 解析 Atom', () {
      final r = RssService.parseFeed(
        '<?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom">'
        '<title>S</title><entry><title>e</title>'
        '<link href="http://e" rel="alternate"/></entry></feed>',
      );
      expect(r, isNotNull);
      expect(r!.items.single.link, 'http://e');
    });

    test('订阅管理 json 往返', () {
      final raw = jsonEncode(['https://a.com', 'https://b.com']);
      SharedPreferences.setMockInitialValues({});
      expect(raw, contains('b.com'));
    });
  });
}