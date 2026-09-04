import 'package:flutter_test/flutter_test.dart';

import 'package:legado_flutter/book_source/models/books.dart';
import 'package:legado_flutter/book_source/services/search_service.dart';

void main() {
  SearchBook sb(String name, {String? author}) =>
      SearchBook(name: name, author: author, bookUrl: '/$name', origin: '源');

  group('搜索结果去重排序', () {
    test('相同书名+同作者跨源去重，保留先到源', () {
      final first = merge([sb('天龙八部', author: '金庸')]);
      final second = merge(first, incoming: [sb('天龙八部', author: '金庸')]);
      expect(second.length, 1);
    });

    test('同名不同作者不去重', () {
      final first = merge([sb('斗罗大陆', author: '唐家三少')]);
      final second = merge(first,
          incoming: [sb('斗罗大陆', author: '爆料')]);
      expect(second.length, 2);
    });

    test('按相关度排序：完全一致排最前', () {
      final merged = merge([
        sb('天龙八部4', author: '金庸'),
        sb('天龙八部', author: '金庸'),
        sb('新天龙八部', author: '佚名'),
      ]);
      expect(merged.first.name, '天龙八部');
    });

    test('前缀一致优先于含于书名', () {
      final merged = merge([sb('剑来正传'), sb('剑来')]);
      expect(merged.first.name, '剑来');
      expect(merged.last.name, '剑来正传');
    });

    test('流式合并增量去重排序稳定', () {
      var acc = <SearchBook>[
        sb('A书', author: '甲'),
        sb('B书', author: '乙'),
      ];
      acc = SearchService.mergeResults(acc, [sb('A书', author: '甲')], 'a');
      expect(acc.length, 2);
      acc = SearchService.mergeResults(acc, [sb('A书', author: '丙')], 'a');
      expect(acc.length, 3);
    });
  });
}

List<SearchBook> merge(List<SearchBook> initial, {List<SearchBook> incoming = const []}) {
  return SearchService.mergeResults(initial, incoming, '天龙八部');
}