import 'package:flutter_test/flutter_test.dart';
import 'package:legado_flutter/book_source/js/js_interp.dart';

void main() {
  group('DartJs — 规则内联表达式', () {
    test('字符串 replace（正则/全局）', () {
      final r = DartJs(
        bindings: {'result': '百度搜索://www.baidu.com/s'},
      ).evaluateExpression("result.replace(/百度搜索:/,'')");
      expect(r, '//www.baidu.com/s');
    });

    test('replaceAll 全局替换', () {
      final r = DartJs(bindings: {'result': 'a,b,c'})
          .evaluateExpression("result.replaceAll(',', '|')");
      expect(r, 'a|b|c');
    });

    test('trim / toUpperCase / split / join', () {
      final d = DartJs();
      expect(d.evaluateExpression("'  hi  '.trim().toUpperCase()"), 'HI');
      expect(d.evaluateExpression("'a,b,c'.split(',').join('-')"), 'a-b-c');
    });

    test('算术与比较', () {
      final d = DartJs();
      expect(d.evaluateExpression('1+2*3'), 7);
      expect(d.evaluateExpression('(1+2)*3'), 9);
      expect(d.evaluateExpression('"5"+1'), '51');
      expect(d.evaluateExpression('5 > 3 && 2 < 4'), true);
      expect(d.evaluateExpression('!false'), true);
    });

    test('三元与变量绑定', () {
      final d = DartJs(bindings: {'a': '1'});
      expect(d.evaluateExpression('a == "1" ? "yes" : "no"'), 'yes');
    });

    test('数组 map/filter', () {
      final d = DartJs();
      expect(d.evaluateExpression('[1,2,3].map(function(x){return x*2;}).join(",")'), '2,4,6');
      expect(d.evaluateExpression('[1,2,3,4].filter(function(x){return x>2;}).length'), 2);
    });

    test('模板字符串（原样，不含插值）', () {
      final d = DartJs();
      expect(d.evaluateExpression('`书名:火影`'), '书名:火影');
    });

    test('正则提取 match', () {
      final d = DartJs();
      expect(d.evaluateExpression(r"'abc123'.match(/\d+/)[0]"), '123');
    });
  });

  group('DartJs — 脚本执行（jsLib/变量）', () {
    test('定义函数并调用', () {
      final d = DartJs();
      d.run('function get(a){return "v_"+a;} var out=get("x");');
      expect(d.getVariable('out'), 'v_x');
    });

    test('for 循环汇总', () {
      final d = DartJs();
      d.run('var sum=0; for(var i=1;i<=5;i++){sum=sum+i;} var out=sum;');
      expect(d.getVariable('out'), 15);
    });

    test('对象字面量访问', () {
      final d = DartJs();
      d.run('var obj={a:1,b:"x"}; var out=obj.b;');
      expect(d.getVariable('out'), 'x');
    });
  });
}