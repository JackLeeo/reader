import 'package:flutter_test/flutter_test.dart';
import 'package:legado_flutter/book_source/analyze/analyze_rule.dart';

void main() {
  group('JS 桥接 \$api / 特殊变量（对标官方 JsExtensions）', () {
    AnalyzeRule newRule([String baseUrl = '']) {
      final r = AnalyzeRule();
      r.setContent('', baseUrl: baseUrl.isEmpty ? null : baseUrl);
      return r;
    }

    String evalJs(AnalyzeRule rule, String expr) {
      return rule.getString('@@<js>$expr</js>');
    }

    test(r'$api.base64Encode 可在 @js 中调用并得到 UTF8 Base64', () {
      final rule = newRule();
      expect(evalJs(rule, r'$api.base64Encode("测试")'), '5rWL6K+V');
    });

    test(r'$api.base64Decode 可还原', () {
      final rule = newRule();
      expect(evalJs(rule, r'$api.base64Decode("5rWL6K+V")'), '测试');
    });

    test(r'$api.base64UrlEncode / base64UrlDecode 往返', () {
      final rule = newRule();
      final enc = evalJs(rule, r'$api.base64UrlEncode("a+b/c d")');
      // 'a+b/c d' 共 7 字节，其 unpadded base64 = 'YStiL2MgZA'（无 + / =，本身就是 URL-safe）
      expect(enc, 'YStiL2MgZA');
      expect(evalJs(rule, r'$api.base64UrlDecode("YStiL2MgZA")'), 'a+b/c d');
    });

    test(r'$api.encodeURIComponent / decodeURIComponent', () {
      final rule = newRule();
      expect(evalJs(rule, r'$api.encodeURIComponent("a b")'), 'a%20b');
      expect(evalJs(rule, r'$api.decodeURIComponent("a%20b")'), 'a b');
    });

    test(r'$api.getAbsoluteURL 基于 baseUrl 解析相对链接', () {
      final rule = newRule('https://www.booksite.com/catalog/');
      expect(evalJs(rule, r'$api.getAbsoluteURL("/book/1")'),
          'https://www.booksite.com/book/1');
    });

    test('Dart 函数作为 JS 全局可调用（encodeURIComponent）', () {
      final rule = newRule();
      expect(evalJs(rule, r'encodeURIComponent("a b")'), 'a%20b');
    });

    test('特殊变量 @host / @date 解析', () {
      final rule = newRule('https://www.booksite.com/catalog/');
      expect(rule.getVariable('@host'), 'www.booksite.com');
      expect(rule.getVariable('@date'),
          matches(RegExp(r'^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$')));
    });
  });

  group('@js 特殊变量注入', () {
    test('host/cookie/date 绑定供 @js 引用', () {
      final rule = AnalyzeRule();
      rule.setContent('', baseUrl: 'https://x.example.com/a/');
      expect(rule.getString(r'@@<js>host</js>'), 'x.example.com');
      final d = rule.getString(r'@@<js>date</js>');
      expect(d, matches(RegExp(r'^\d{4}-\d{2}-\d{2}')));
    });
  });

  group('getVariable / setVariable（官方 putVariable 语义）', () {
    test('setVariable 后可读取', () {
      final rule = AnalyzeRule();
      rule.setContent('');
      rule.setVariable('key', 'val');
      expect(rule.getVariable('key'), 'val');
      expect(rule.getVariable('@key'), 'val');
    });

    test('特殊变量优先，普通键为空返回空串', () {
      final rule = AnalyzeRule();
      rule.setContent('', baseUrl: 'https://a.b.c/');
      expect(rule.getVariable('not-set'), '');
      expect(rule.getVariable('@host'), 'a.b.c');
    });
  });

  group('@js 字符串拼接与求值', () {
    test('字符串拼接保留长度语义', () {
      final rule = AnalyzeRule();
      rule.setContent('');
      expect(rule.getString(r'@@<js>"a"+"b"</js>'), 'ab');
    });
  });
}