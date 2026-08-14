// 单元测试 - BookSource JSON 解析
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/models/book_source.dart';

void main() {
  group('BookSource.fromJson', () {
    test('parses minimal source', () {
      final s = BookSource.fromJson({
        'bookSourceName': '测试源',
        'bookSourceUrl': 'https://example.com',
        'searchUrl': '/search?key={{key}}',
        'ruleSearch': {
          'bookList': 'div.book',
          'name': 'h3@text',
        },
      });
      expect(s.bookSourceName, '测试源');
      expect(s.baseUrl, 'https://example.com');
      expect(s.id, isNotEmpty);
      expect(s.isEnabled, isTrue);
      expect(s.ruleSearch['name'], 'h3@text');
    });

    test('parses explore URL in JSON format', () {
      final s = BookSource.fromJson({
        'bookSourceName': 't',
        'bookSourceUrl': 'https://x.com',
        'exploreUrl': '[{"title":"A","url":"/a"},{"title":"B","url":"/b"}]',
      });
      final cats = s.exploreCategories;
      expect(cats.length, 2);
      expect(cats[0].title, 'A');
      expect(cats[1].url, '/b');
    });

    test('parses explore URL in "title::URL" format', () {
      final s = BookSource.fromJson({
        'bookSourceName': 't',
        'bookSourceUrl': 'https://x.com',
        'exploreUrl': '玄幻::/xuanhuan\n修真::/xiuzhen',
      });
      final cats = s.exploreCategories;
      expect(cats.length, 2);
      expect(cats[0].title, '玄幻');
      expect(cats[0].url, '/xuanhuan');
    });

    test('parses header as JSON string', () {
      final s = BookSource.fromJson({
        'bookSourceName': 't',
        'bookSourceUrl': 'https://x.com',
        'header': '{"User-Agent": "Mozilla/5.0"}',
      });
      expect(s.header['User-Agent'], 'Mozilla/5.0');
    });

    test('id is stable for same URL', () {
      final s1 = BookSource.fromJson({
        'bookSourceName': 'a',
        'bookSourceUrl': 'https://x.com',
      });
      final s2 = BookSource.fromJson({
        'bookSourceName': 'a',
        'bookSourceUrl': 'https://x.com',
      });
      expect(s1.id, s2.id);
    });

    test('enabled defaults to true', () {
      final s = BookSource.fromJson({
        'bookSourceName': 't',
        'bookSourceUrl': 'https://x.com',
      });
      expect(s.isEnabled, isTrue);
    });

    test('enabled=false preserved', () {
      final s = BookSource.fromJson({
        'bookSourceName': 't',
        'bookSourceUrl': 'https://x.com',
        'enabled': false,
      });
      expect(s.isEnabled, isFalse);
    });
  });
}
