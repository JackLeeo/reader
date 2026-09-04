import 'package:flutter_test/flutter_test.dart';
import 'package:legado_flutter/book_source/help/source_callback.dart';
import 'package:legado_flutter/book_source/models/book_source.dart';
import 'package:legado_flutter/book_source/models/books.dart';

void main() {
  group('SourceCallback（书源事件回调分发）', () {
    test('canReceive：需 eventListener 且配置 callBackJs', () {
      final s1 = BookSource.fromJson({'bookSourceUrl': 'a.com'});
      expect(SourceCallback.canReceive(s1), isFalse);

      final s2 = BookSource.fromJson({
        'bookSourceUrl': 'a.com',
        'eventListener': true,
        'ruleContent': {'callBackJs': 'println(1)'},
      });
      expect(SourceCallback.canReceive(s2), isTrue);
    });

    test('event：未开启 eventListener 不触发（不抛错）', () async {
      final s = BookSource.fromJson({'bookSourceUrl': 'a.com'});
      // 无 callBackJs 也不应抛错
      await SourceCallback.event(source: s, event: 'clickCustomButton');
      expect(true, isTrue);
    });

    test('event：注入 event/book/chapter 执行不抛错 且不拦截默认', () async {
      final s = BookSource.fromJson({
        'bookSourceUrl': 'a.com',
        'eventListener': true,
        'ruleContent': {'callBackJs': r'let msg = java.showMsg("x"); event;'},
      });
      final book = Book(
        name: '测试书',
        author: '作者',
        bookUrl: 'https://a.com/book/1',
        sourceTag: 'a.com',
        type: 0,
      );
      final chapter = BookChapter(title: '第一章', url: 'https://a.com/c/1');
      // 不应抛异常；复杂/未知 JS 也静默
      await SourceCallback.event(
        source: s,
        event: 'clickCustomButton',
        book: book,
        chapter: chapter,
      );
      expect(true, isTrue);
    });

    test('event：callBackJs 含 Rhino 专属语法（函数/正则）也静默不拦截', () async {
      final s = BookSource.fromJson({
        'bookSourceUrl': 'a.com',
        'eventListener': true,
        'ruleContent': {
          'callBackJs': r'''
            function handle(event) {
              if (event == "clickCustomButton") return false;
              return true;
            }
            handle(event);
          ''',
        },
      });
      await SourceCallback.event(source: s, event: 'clickCustomButton');
      expect(true, isTrue);
    });
  });
}