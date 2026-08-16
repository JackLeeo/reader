import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/core/reader/chapter_heading_library.dart';

void main() {
  group('ChineseNumberParser', () {
    test('parses common chinese numbers', () {
      expect(ChineseNumberParser.tryParse('一'), 1);
      expect(ChineseNumberParser.tryParse('二'), 2);
      expect(ChineseNumberParser.tryParse('两'), 2);
      expect(ChineseNumberParser.tryParse('十'), 10);
      expect(ChineseNumberParser.tryParse('十一'), 11);
      expect(ChineseNumberParser.tryParse('二十'), 20);
      expect(ChineseNumberParser.tryParse('二十一'), 21);
      expect(ChineseNumberParser.tryParse('一百'), 100);
      expect(ChineseNumberParser.tryParse('一百零一'), 101);
      expect(ChineseNumberParser.tryParse('一百二十三'), 123);
      expect(ChineseNumberParser.tryParse('一千'), 1000);
      expect(ChineseNumberParser.tryParse('三千二百一十'), 3210);
      expect(ChineseNumberParser.tryParse('一万'), 10000);
      expect(ChineseNumberParser.tryParse('一万零一'), 10001);
      expect(ChineseNumberParser.tryParse('壹佰贰拾叁'), 123);
      expect(ChineseNumberParser.tryParse('〇'), 0);
      expect(ChineseNumberParser.tryParse('123'), 123);
    });

    test('returns null for invalid inputs', () {
      expect(ChineseNumberParser.tryParse(''), isNull);
      expect(ChineseNumberParser.tryParse('abc'), isNull);
      expect(ChineseNumberParser.tryParse('第章'), isNull);
    });
  });

  group('ChapterHeadingLibrary', () {
    test('default rules count matches enabled entries', () {
      final enabled = ChapterHeadingLibrary.defaultRules.length;
      // enable=true 的条目：0,1,6,7,8,9,11,13,14,18 = 10
      expect(enabled, 10);
      expect(ChapterHeadingLibrary.allRules.length, 19);
    });

    test('rule 0: 相对通用 matches 第X章/第X草', () {
      final r = ChapterHeadingLibrary.allRules[0];
      expect(r.pattern.hasMatch('第一章 雪夜'), true);
      expect(r.pattern.hasMatch('第十二草 无题'), true);
      expect(r.pattern.hasMatch('第一二三章'), true);
      expect(r.pattern.hasMatch('第１章'), true);
      expect(r.pattern.hasMatch('完全不相关'), false);
    });

    test('rule 1: 目录行首标准格式', () {
      final r = ChapterHeadingLibrary.allRules[1];
      expect(r.pattern.hasMatch('第一章 大风'), true);
      expect(r.pattern.hasMatch('第1章 大风'), true);
      expect(r.pattern.hasMatch('  序章'), true);
      expect(r.pattern.hasMatch('楔子 关于过去'), true);
      expect(r.pattern.hasMatch('番外一'), true, reason: '番外一 不含章节单位但算特殊标题');
      // 负向前瞻：节课/集合/部分/篇张
      expect(r.pattern.hasMatch('第一节课'), false);
      expect(r.pattern.hasMatch('第一部分'), false);
      expect(r.pattern.hasMatch('第一篇张'), false);
    });

    test('rule 6: 数字 分隔符 标题', () {
      final r = ChapterHeadingLibrary.allRules[6];
      expect(r.pattern.hasMatch('12. 风雪夜归人'), true);
      expect(r.pattern.hasMatch('001-风雪夜'), true);
      expect(r.pattern.hasMatch('3、章节名'), true);
      expect(r.pattern.hasMatch('5,title'), true);
      expect(r.pattern.hasMatch('123456.超长数字'), false,
          reason: '超过 5 位数字不命中');
      expect(r.pattern.hasMatch('12.'), false, reason: '必须有标题部分');
    });

    test('rule 7: 大写数字 分隔符 标题', () {
      final r = ChapterHeadingLibrary.allRules[7];
      expect(r.pattern.hasMatch('一、大风'), true);
      expect(r.pattern.hasMatch('十二 风雪'), true);
      expect(r.pattern.hasMatch('壹佰贰拾-名字'), true);
    });

    test('rule 8: 正文 标题/序号', () {
      final r = ChapterHeadingLibrary.allRules[8];
      expect(r.pattern.hasMatch('正文 第一章'), true);
      expect(r.pattern.hasMatch('正文　　序'), true);
    });

    test('rule 9: Chapter/Section 等英文标题', () {
      final r = ChapterHeadingLibrary.allRules[9];
      expect(r.pattern.hasMatch('Chapter 1 Beginning'), true);
      expect(r.pattern.hasMatch('chapter 12 End'), true);
      expect(r.pattern.hasMatch('Section 2'), true);
      expect(r.pattern.hasMatch('Part 9 卷'), true);
      expect(r.pattern.hasMatch('ＰＡＲＴ　１　序'), true);
      expect(r.pattern.hasMatch('No. 3 Hello'), true);
      expect(r.pattern.hasMatch('Episode 99 Return'), true);
    });

    test('rule 11: 特殊符号括号包裹的章节序号', () {
      final r = ChapterHeadingLibrary.allRules[11];
      expect(r.pattern.hasMatch('【第一章 大风】'), true);
      expect(r.pattern.hasMatch('〔Chapter 1〕'), true);
      expect(r.pattern.hasMatch('「第十章」'), true);
      expect(r.pattern.hasMatch('[第12节]'), true);
    });

    test('rule 13: 特殊符号(单个)开头的标题', () {
      final r = ChapterHeadingLibrary.allRules[13];
      expect(r.pattern.hasMatch('☆ 序章'), true);
      expect(r.pattern.hasMatch('★大风起兮'), true);
      expect(r.pattern.hasMatch('✦楔子'), true);
    });

    test('rule 14: 章/卷/序号直接开头', () {
      final r = ChapterHeadingLibrary.allRules[14];
      expect(r.pattern.hasMatch('卷一 大风'), true);
      expect(r.pattern.hasMatch('章十二 标题'), true);
      expect(r.pattern.hasMatch('简介 关于这本书'), true);
    });

    test('rule 18: 标题(序号)', () {
      final r = ChapterHeadingLibrary.allRules[18];
      expect(r.pattern.hasMatch('大风起兮(一)'), true);
      expect(r.pattern.hasMatch('标题名称（12）'), true);
      expect(r.pattern.hasMatch('短（壹佰贰拾）'), true);
    });

    test('looksLikeHeading with default rules covers real-world cases', () {
      final samples = <String>[
        '第一章 雪夜',
        '第123章 大风起兮云飞扬',
        '序章 关于那个冬天',
        '楔子',
        '番外一 之后的故事',
        '12. 风雪夜',
        '001-初入江湖',
        '一、少年游',
        'Chapter 1 The Beginning',
        'Part 9 Roll Credits',
        '【第一章 大风】',
        '☆ 楔子',
        '卷一 风起',
        '大风起兮(一)',
      ];
      for (final s in samples) {
        expect(ChapterHeadingLibrary.looksLikeHeading(s), true,
            reason: 'Should match: $s');
      }
    });

    test('looksLikeHeading rejects non-heading noise lines', () {
      final noise = <String>[
        '首页',
        '排行榜',
        '加入书架',
        '投推荐票',
        '上一章',
        '下一章',
        '返回目录',
        '本站所有小说为转载作品',
        'Copyright 2024',
        '    ',
        '',
      ];
      for (final n in noise) {
        expect(ChapterHeadingLibrary.looksLikeHeading(n), false,
            reason: 'Should NOT match: $n');
      }
    });

    test('filter keeps order and only heading-like items', () {
      final input = [
        _T('1', '首页'),
        _T('2', '第一章 大风'),
        _T('3', '排行榜'),
        _T('4', '第二章 雪夜'),
        _T('5', '加入书架'),
      ];
      final out = ChapterHeadingLibrary.filter(
        input,
        titleOf: (t) => t.title,
      );
      expect(out.map((e) => e.id), ['2', '4']);
    });
  });

  group('normalizeForCrossSource + extractIndex (换源对齐)', () {
    test('normalize strips decorative wrappers but keeps numeric wrappers', () {
      expect(
        ChapterHeadingLibrary.normalizeForCrossSource('【VIP】【新书】第一章 雪夜'),
        '第一章 雪夜',
      );
      expect(
        ChapterHeadingLibrary.normalizeForCrossSource('第一章 雪夜（订阅）'),
        '第一章 雪夜',
      );
      // 含数字的括号 (1)（一）保留
      expect(
        ChapterHeadingLibrary.normalizeForCrossSource('大风起兮(一)'),
        '大风起兮(一)',
      );
    });

    test('normalize trims symbols', () {
      expect(
        ChapterHeadingLibrary.normalizeForCrossSource('———第一章 大风***'),
        '第一章 大风',
      );
      expect(
        ChapterHeadingLibrary.normalizeForCrossSource('  ★ 楔子 '),
        '楔子',
      );
    });

    test('extractIndex parses chinese/english/plain chapter numbers', () {
      expect(ChapterHeadingLibrary.extractIndex('第一章 大风')!.numeric, 1);
      expect(ChapterHeadingLibrary.extractIndex('第一百二十章')!.numeric, 120);
      expect(ChapterHeadingLibrary.extractIndex('Chapter 12 Hello')!.numeric, 12);
      expect(ChapterHeadingLibrary.extractIndex('Chapter 12 Hello')!.unit, '章');
      expect(ChapterHeadingLibrary.extractIndex('Section 5')!.unit, '节');
      expect(ChapterHeadingLibrary.extractIndex('Part 9')!.unit, '部');
      expect(ChapterHeadingLibrary.extractIndex('Episode 4')!.unit, '集');
      expect(ChapterHeadingLibrary.extractIndex('12. 风雪夜')!.numeric, 12);
      expect(ChapterHeadingLibrary.extractIndex('12. 风雪夜')!.unit, '');
      expect(ChapterHeadingLibrary.extractIndex('【第十二章】')!.numeric, 12);
      expect(ChapterHeadingLibrary.extractIndex('完全没有序号的一句话'), isNull);
    });

    test('extractIndex unit mismatch blocks cross-unit fallback', () {
      // 章节单位不同时：numeric 相同也不能用"同一章"做等值，除非有空unit
      final a = ChapterHeadingLibrary.extractIndex('第一章 x')!; // 1,章
      final b = ChapterHeadingLibrary.extractIndex('第一节 x')!; // 1,节
      final c = ChapterHeadingLibrary.extractIndex('1. x')!; // 1,''
      expect(a.numeric == b.numeric, true);
      expect(a.unit == b.unit, false);
      // c 是空unit，按照算法里"空 unit 和任何都兼容"的判定应视为匹配OK
      expect(c.unit.isEmpty, true);
    });
  });

  group('shouldTryHeadingFallback', () {
    test('chapterListHits == 0 强制 fallback', () {
      expect(shouldTryHeadingFallback(chapterListHits: 0, validChapters: 0), true);
      expect(shouldTryHeadingFallback(chapterListHits: 0, validChapters: 100), true);
    });

    test('比率很差时 fallback', () {
      // 命中 200 条才出 10 条有效 → 1/20 < 0.2
      expect(shouldTryHeadingFallback(chapterListHits: 200, validChapters: 10), true);
    });

    test('比率健康时不 fallback', () {
      expect(shouldTryHeadingFallback(chapterListHits: 100, validChapters: 95), false);
      expect(shouldTryHeadingFallback(chapterListHits: 20, validChapters: 20), false);
    });
  });
}

class _T {
  _T(this.id, this.title);
  final String id;
  final String title;
}
