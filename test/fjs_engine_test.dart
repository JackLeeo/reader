import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:legado_flutter/book_source/js/fjs_engine.dart';
import 'package:legado_flutter/book_source/analyze/analyze_rule.dart';

void main() {
  group('FjsJsEngine — QuickJS 可用性与降级', () {
    late FjsJsEngine engine;

    setUp(() async {
      engine = FjsJsEngine.instance;
      await engine.ensureReady();
    });

    test('引擎状态可读（可用或按宿主能力降级不可用）', () {
      expect(engine.isAvailable, isA<bool>());
    });

    test('真实执行：表达式求值（仅当原生库可用）', () async {
      if (!engine.isAvailable) return;
      final v = await engine.evaluate('1 + 2 * 3');
      expect(v, '7');
    });

    test(r'真实执行：$api.base64Encode（仅当原生库可用）', () async {
      if (!engine.isAvailable) return;
      final v = await engine.evaluate(r'''$api.base64Encode('hello')''');
      expect(v, 'aGVsbG8=');
    });

    test('真实执行：jsonToString 结构（仅当原生库可用）', () async {
      if (!engine.isAvailable) return;
      final v = await engine.evaluate(r'''$api.jsonToString({a:1,b:'x'})''');
      expect(jsonDecode(v!), {'a': 1, 'b': 'x'});
    });
  });

  group('AnalyzeRule — JS 规则降级路径（fjs 不可用时回退 DartJs）', () {
    test('普通 JS 表达式在无 fjs 宿主下经 DartJs 求值', () async {
      final rule = AnalyzeRule();
      rule.setContent('<html><body>hello</body></html>');
      final v = await rule.getStringAsync(
        '@js:1+2',
      );
      expect(v, '3');
    });

    test(r'$api 编码工具在无 fjs 宿主下经 DartJs 求值', () async {
      final rule = AnalyzeRule();
      rule.setContent('fake');
      final v = await rule.getStringAsync(
        r'@js:$api.base64Encode("hi")',
      );
      expect(v, 'aGk=');
    });
  });
}