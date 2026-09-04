import 'package:flutter_test/flutter_test.dart';
import 'package:legado_flutter/book_source/help/chinese_converter.dart';
import 'package:legado_flutter/book_source/help/content_processor.dart';
import 'package:legado_flutter/book_source/services/replace_rule_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
  });

  group('ReplaceRuleService', () {
    test('upsert / 生效规则按作用域过滤', () async {
      final s = ReplaceRuleService.instance;
      await s.init();
      s.clear();

      s.upsert(ReplaceRule(
        name: '去广告',
        pattern: r'\[广告\].*',
        isRegex: true,
        scopeContent: true,
        scopeTitle: false,
      ));
      s.upsert(ReplaceRule(
        name: '标题修',
        pattern: '正文',
        replacement: '正文X',
        isRegex: false,
        scopeContent: false,
        scopeTitle: true,
      ));

      final content = s.activeFor(sourceUrl: null, forTitle: false);
      expect(content.length, 1);
      expect(content.first.name, '去广告');

      final title = s.activeFor(sourceUrl: null, forTitle: true);
      expect(title.length, 1);
      expect(title.first.name, '标题修');
    });

    test('按书源过滤：不同源规则隔离', () async {
      final s = ReplaceRuleService.instance;
      await s.init();
      s.clear();

      s.upsert(ReplaceRule(name: '源A', sourceUrl: 'a.com', pattern: 'x', replacement: 'y'));
      s.upsert(ReplaceRule(name: '全局', sourceUrl: '', pattern: 'x', replacement: 'y'));

      expect(s.activeFor(sourceUrl: 'a.com', forTitle: true).length, 2);
      expect(s.activeFor(sourceUrl: 'b.com', forTitle: true).length, 1);
    });
  });

  group('ContentProcessor 接入替换与简繁', () {
    test('replaceRules 钩子应用', () {
      final cp = ContentProcessor(
        replaceRules: [
          (_, text) => text.replaceAll('广告', '**'),
        ],
      );
      expect(cp.clean('这里有广告内容'), '这里有**内容');
    });

    test('简繁转换接入 clean', () {
      const cp = ContentProcessor(convertType: kConvertToTraditional);
      final out = cp.clean('我们喜欢阅读小说');
      expect(out, '我們喜歡閱讀小說');
    });
  });

  group('ChineseConverter', () {
    test('常用简体→繁体', () {
      expect(ChineseConverter.toTraditional('小说'), '小說');
      expect(ChineseConverter.toTraditional('阅读'), '閱讀');
      expect(ChineseConverter.toTraditional('我们'), '我們');
      expect(ChineseConverter.toTraditional('我们的时代'), '我們的時代');
    });

    test('繁体→简体', () {
      expect(ChineseConverter.toSimplified('小說'), '小说');
      expect(ChineseConverter.toSimplified('我們喜歡閱讀'), '我们喜欢阅读');
    });

    test('英文数字不动', () {
      expect(ChineseConverter.toTraditional('abc 123'), 'abc 123');
    });
  });
}