// 单元测试 - JsonSelector JSON 解析
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/rule_engine/json_selector.dart';

void main() {
  group('JsonSelector', () {
    test('parses simple object', () {
      final s = JsonSelector.decode('{"a": 1, "b": "x"}');
      expect(s, isA<Map>());
    });

    test('parses array', () {
      final s = JsonSelector.decode('[1, 2, 3]');
      expect(s, isA<List>());
    });

    test('returns null on invalid', () {
      final s = JsonSelector.decode('not json');
      expect(s, isNull);
    });

    test('select $.field', () {
      final s = JsonSelector(JsonSelector.decode('{"a": {"b": 42}}'));
      expect(s.select('a.b')?.string, '42');
    });

    test('select array index', () {
      final s = JsonSelector(JsonSelector.decode('{"items": [10, 20, 30]}'));
      expect(s.select('items[1]')?.string, '20');
    });

    test('select list', () {
      final s = JsonSelector(JsonSelector.decode(
          '{"data": [{"x": 1}, {"x": 2}, {"x": 3}]}'));
      final list = s.selectList('data');
      expect(list.length, 3);
      expect(list[0].select('x')?.string, '1');
    });

    test('empty path returns self', () {
      final s = JsonSelector({'a': 1});
      final sel = s.select('\$');
      expect(sel, isNotNull);
    });
  });
}
