import 'package:flutter_test/flutter_test.dart';

import 'package:legado_flutter/book_source/services/shelf_service.dart';

void main() {
  List<ShelfBook> build() => [
        ShelfBook(
          name: '乙',
          author: 'B',
          bookUrl: 'b',
          origin: 'o',
          sourceTag: 'tag1',
          lastReadIndex: 3,
          readingProgress: 0.5,
          addTime: 2,
        ),
        ShelfBook(
          name: '丙',
          author: 'A',
          bookUrl: 'c',
          origin: 'o',
          sourceTag: 'tag2',
          lastReadIndex: 1,
          readingProgress: 0.1,
          addTime: 3,
        ),
        ShelfBook(
          name: '甲',
          author: 'C',
          bookUrl: 'a',
          origin: 'o',
          sourceTag: 'tag3',
          lastReadIndex: 5,
          readingProgress: 0.9,
          addTime: 1,
        ),
      ];

  List<String> names(List<ShelfBook> list) => [for (final b in list) b.name];

  test('默认按添加时间倒序', () {
    expect(
      names(ShelfBook.sortShelf(build(), SortMode.addTime)),
      ['丙', '乙', '甲'],
    );
  });

  test('按书名排序（UTF-16 码位升序：丙<乙<甲）', () {
    expect(
      names(ShelfBook.sortShelf(build(), SortMode.name)),
      ['丙', '乙', '甲'],
    );
  });

  test('按作者排序', () {
    expect(
      names(ShelfBook.sortShelf(build(), SortMode.author)),
      ['丙', '乙', '甲'],
    );
  });

  test('按阅读进度倒序', () {
    expect(
      names(ShelfBook.sortShelf(build(), SortMode.progress)),
      ['甲', '乙', '丙'],
    );
  });

  test('按最近阅读章序倒序', () {
    expect(
      names(ShelfBook.sortShelf(build(), SortMode.recentRead)),
      ['甲', '乙', '丙'],
    );
  });

  test('排序不修改原列表', () {
    final src = build();
    final before = names(src);
    ShelfBook.sortShelf(src, SortMode.name);
    expect(names(src), before);
  });
}
