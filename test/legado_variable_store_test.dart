// 变量池与阅读链路修复的回归测试：
// 1. @put:/@get: 规则语法（跨求值共享、按源隔离）
// 2. tocUrl 求值为空/`-` 时回退 bookUrl
// 3. URL 模板 @get:{name} 展开
// 4. Rhino 专属语法源在导入扫描时被拦截
import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/legado/legado_book_source.dart';
import 'package:xxread/book_sources/legado/legado_rule_engine.dart';
import 'package:xxread/book_sources/legado/legado_variable_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => LegadoVariableStore.instance.clearAll());

  group('LegadoVariableStore', () {
    test('isolates variables per source', () {
      LegadoVariableStore.instance.put('https://a.test', 't', 'token-a');
      LegadoVariableStore.instance.put('https://b.test', 't', 'token-b');

      expect(
        LegadoVariableStore.instance.get('https://a.test', 't'),
        'token-a',
      );
      expect(
        LegadoVariableStore.instance.get('https://b.test', 't'),
        'token-b',
      );
      expect(
        LegadoVariableStore.instance.get('https://a.test', 'missing'),
        isNull,
      );
    });

    test('expandGetsStrict keeps unresolved @get intact', () {
      LegadoVariableStore.instance.put('https://a.test', 'page', '3');
      final expanded = LegadoVariableSyntax.expandGetsStrict(
        '/list/@get:{page}/@get:{nope}',
        (name) => LegadoVariableStore.instance.get('https://a.test', name),
      );
      expect(expanded, '/list/3/@get:{nope}');
    });
  });

  group('LegadoRuleEngine variable syntax', () {
    const engine = LegadoRuleEngine();
    const sourceUrl = 'https://vars.test';

    test('rule-level @get:{name} reads the variable pool', () async {
      LegadoVariableStore.instance.put(sourceUrl, 't', 'https://toc.test/1');
      final document = LegadoRuleDocument.parse(
        '<html></html>',
        Uri.parse('https://vars.test/book/1'),
      );
      final value = await engine.evaluateString(
        document,
        null,
        '@get:{t}',
        sourceUrl: sourceUrl,
      );
      expect(value, 'https://toc.test/1');
    });

    test(
      'put:{name:rule} segment stores value without emitting output',
      () async {
        final document = LegadoRuleDocument.parse(
          '<div class="meta" data-id="9527">书名</div>',
          Uri.parse('https://vars.test/book/1'),
        );
        // 先执行 put 段：把 data-id 存入变量池。
        await engine.evaluateString(
          document,
          null,
          'class.meta@put:{bookId:data-id}',
          sourceUrl: sourceUrl,
        );
        expect(LegadoVariableStore.instance.get(sourceUrl, 'bookId'), '9527');
        // 随后的请求用 @get 取回。
        final value = await engine.evaluateString(
          document,
          null,
          '@get:{bookId}',
          sourceUrl: sourceUrl,
        );
        expect(value, '9527');
      },
    );
  });

  group('LegadoCompatibilityScanner rhino detection', () {
    LegadoBookSource buildSource(Map<String, dynamic> extra) {
      return LegadoBookSource.fromJson({
        'bookSourceUrl': 'https://rhino.test',
        'bookSourceName': 'rhino',
        ...extra,
      });
    }

    test('flags JavaImporter scripts as unsupported', () {
      final source = buildSource({
        'ruleToc': {
          'tocUrl':
              '@js:var ji = new JavaImporter(); ji.importPackage(Packages.java.lang); result;',
        },
        'ruleContent': {'content': 'id.content@text'},
      });
      final report = const LegadoCompatibilityScanner().scan(source);
      expect(report.canRun, isFalse);
      expect(report.issues, contains(LegadoCompatibilityIssue.rhinoScript));
    });

    test('does not flag plain QuickJS scripts', () {
      final source = buildSource({
        'searchUrl': 'https://rhino.test/s?q={{key}}',
        'ruleToc': {
          'chapterList': 'id.list@dd',
          'chapterName': 'a@text',
          'chapterUrl': 'a@href',
        },
        'ruleContent': {'content': 'id.content@text'},
      });
      final report = const LegadoCompatibilityScanner().scan(source);
      expect(
        report.issues,
        isNot(contains(LegadoCompatibilityIssue.rhinoScript)),
      );
    });
  });
}
