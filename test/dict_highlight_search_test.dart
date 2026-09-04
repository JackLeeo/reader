import 'package:flutter_test/flutter_test.dart';
import 'package:legado_flutter/book_source/services/content_search_service.dart';
import 'package:legado_flutter/book_source/services/dict_service.dart';
import 'package:legado_flutter/book_source/services/highlight_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    DictService.instance.clear();
    HighlightService.instance.clear();
    await DictService.instance.init();
    await HighlightService.instance.init();
  });

  // ---------------------------------------------------------------------
  // 词典查询
  // ---------------------------------------------------------------------
  group('DictService', () {
    test('DictSource 持久化往返', () async {
      DictService.instance.addSource(DictSource(
        name: '汉典',
        url: 'https://zdic.net/w/{word}',
        rule: '.def@text',
        enabled: true,
      ));
      await DictService.instance.save();

      final p = await SharedPreferences.getInstance();
      expect(p.getString('dict_sources_v1'), contains('汉典'));
      expect(p.getString('dict_sources_v1'), contains('{word}'));

      DictService.instance.clear();
      await DictService.instance.init();
      final s = DictService.instance.sourceByName('汉典');
      expect(s, isNotNull);
      expect(s!.url, 'https://zdic.net/w/{word}');
      expect(s.rule, '.def@text');
    });

    test('query 对不可达 URL 不抛异常，自动容错', () async {
      DictService.instance.addSource(DictSource(
        name: '不可达',
        url: 'https://127.0.0.1:1/no/such/{word}',
        rule: 'def@text',
      ));
      // 无效 URL / 连接失败：期望返回空结果而不是抛异常。
      final results = await DictService.instance.query('测试');
      expect(results, isEmpty);
    });

    test('query 空关键词返回空，且不发起查询', () async {
      DictService.instance.addSource(DictSource(name: 'x', url: 'http://x/{word}'));
      final r = await DictService.instance.query('   ');
      expect(r, isEmpty);
    });

    test('已禁用词典源不参与查询', () async {
      DictService.instance.addSource(DictSource(
        name: '禁用',
        url: 'https://127.0.0.1:1/no/{word}',
        rule: '',
        enabled: false,
      ));
      final r = await DictService.instance.query('词');
      expect(r, isEmpty);
    });
  });

  // ---------------------------------------------------------------------
  // 正文高亮
  // ---------------------------------------------------------------------
  group('HighlightService', () {
    test('HighlightRule.apply 关键字命中区间（高亮全部命中）', () {
      final rule = HighlightRule(name: '主角', keyword: '林一', colorHex: '#FF0000');
      final m = rule.matchAll('林一走进屋，林一坐下。');
      expect(m, hasLength(2));
      expect(m[0].start, 0);
      expect(m[0].end, 2);
      expect(m[0].ruleName, '主角');
      expect(m[0].colorHex, '#FF0000');
      expect(m[1].start, 6);
    });

    test('apply 合并多规则并按 start 排序', () {
      final s = HighlightService.instance;
      s.addRule(HighlightRule(name: 'A', keyword: '中', colorHex: '#AA0000'));
      s.addRule(HighlightRule(name: 'B', keyword: '国', colorHex: '#00AA00'));

      // 中国：'中'@0，'国'@1；反转规则顺序也应按 start 排序。
      final m = s.apply('中国');
      expect(m, hasLength(2));
      expect(m[0].ruleName, 'A');
      expect(m[0].start, 0);
      expect(m[1].ruleName, 'B');
      expect(m[1].start, 1);
    });

    test('pattern 正则高亮', () {
      final s = HighlightService.instance;
      s.addRule(HighlightRule(name: '数字', pattern: r'\d+', colorHex: '#FFAA00'));
      final m = s.apply('abc123def456');
      expect(m, hasLength(2));
      expect(m[0].start, 3);
      expect(m[0].end, 6);
      expect(m[1].start, 9);
      expect(m[1].end, 12);
    });

    test('无效正则被忽略，不抛异常', () {
      final s = HighlightService.instance;
      s.addRule(HighlightRule(name: '坏', pattern: '(['));
      expect(() => s.apply('任意文本'), returnsNormally);
    });

    test('空文本 / 停用规则返回空', () {
      final s = HighlightService.instance;
      s.addRule(HighlightRule(name: '停用', keyword: 'x', enabled: false));
      expect(s.apply(''), isEmpty);
      expect(s.apply('x'), isEmpty);
    });

    test('HighlightRule 持久化往返', () async {
      final s = HighlightService.instance;
      s.addRule(HighlightRule(name: '关键词', keyword: '江湖', colorHex: '#3366FF'));
      await s.save();

      final p = await SharedPreferences.getInstance();
      expect(p.getString('highlight_rules_v1'), contains('江湖'));

      HighlightService.instance.clear();
      await HighlightService.instance.init();
      final r = HighlightService.instance.ruleByName('关键词');
      expect(r, isNotNull);
      expect(r!.colorHex, '#3366FF');
    });
  });

  // ---------------------------------------------------------------------
  // 正文内搜索
  // ---------------------------------------------------------------------
  group('ContentSearchService', () {
    const chapters = <({String title, String content})>[
      (title: '第一章', content: '他走入江湖，从此不再回头。'),
      (title: '第二章', content: '江湖多风波。'),
      (title: '第三章', content: '岁月静好，无名过客。'),
    ];

    test('search 找到全部命中并按章节+位置排序', () {
      final hits = ContentSearchService.instance.search(chapters: chapters, keyword: '江湖');
      expect(hits, hasLength(2));
      expect(hits[0].chapterIndex, 0);
      expect(hits[0].position, 3);
      expect(hits[1].chapterIndex, 1);
      expect(hits[1].position, 0);
    });

    test('snippet 命中前后各默认 20 字', () {
      final hits = ContentSearchService.instance
          .search(chapters: chapters, keyword: '风波', context: 2);
      expect(hits.single.chapterTitle, '第二章');
      expect(hits.single.snippet, '湖多风波。');
      expect(hits.single.snippet, contains('风波'));
    });

    test('大小写不敏感', () {
      const ch = <({String title, String content})>[
        (title: '第一章', content: 'Hello World hello'),
      ];
      final hits = ContentSearchService.instance.search(chapters: ch, keyword: 'hello');
      expect(hits, hasLength(2));
    });

    test('空关键字 / 无命中返回空', () {
      expect(
        ContentSearchService.instance.search(chapters: chapters, keyword: '   '),
        isEmpty,
      );
      expect(
        ContentSearchService.instance.search(chapters: chapters, keyword: '不存在的词'),
        isEmpty,
      );
      expect(
        ContentSearchService.instance.search(chapters: const [], keyword: 'x'),
        isEmpty,
      );
    });
  });
}