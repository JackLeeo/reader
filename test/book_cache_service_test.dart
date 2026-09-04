import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:legado_flutter/book_source/models/books.dart';
import 'package:legado_flutter/book_source/services/book_cache_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('book_cache_test_');
  });

  tearDown(() async {
    BookCacheService.instance.reset();
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  Book makeBook() => Book(
        name: '缓存测试',
        bookUrl: 'https://b.com/book/1',
        type: 0,
        origin: '源',
        sourceTag: 'https://b.com',
      );

  test('putChapter/getChapter 往返且成功标记', () async {
    await BookCacheService.instance.setRoot(tmp);
    final svc = BookCacheService.instance;
    final book = makeBook();

    await svc.putChapter(book, 0, BookContent(
      body: '第一章正文内容',
      title: '第一章',
      sourceUrl: 'https://b.com/c1',
      succeed: true,
    ));
    expect(svc.isChapterCached(book, 0), isTrue);
    expect(svc.cachedChapters(book), [0]);

    final back = await svc.getChapter(book, 0, 'x');
    expect(back, isNotNull);
    expect(back!.body, '第一章正文内容');
    expect(back.title, '第一章');
  });

  test('空正文不入缓存', () async {
    await BookCacheService.instance.setRoot(tmp);
    final svc = BookCacheService.instance;
    final book = makeBook();
    await svc.putChapter(book, 0, BookContent(body: '   ', succeed: true));
    expect(svc.isChapterCached(book, 0), isFalse);
  });

  test('cacheBook 跳过已缓存章节', () async {
    await BookCacheService.instance.setRoot(tmp);
    final svc = BookCacheService.instance;
    final book = makeBook();
    var fetched = <int>[];
    svc.fetchOverride = (b, i, c) async {
      fetched.add(i);
      return BookContent(body: '第$i章正文', title: c.title, succeed: true);
    };

    final chapters = [
      BookChapter(title: 'c0', url: 'u0'),
      BookChapter(title: 'c1', url: 'u1'),
    ];
    await svc.cacheBook(book, chapters);
    expect(fetched, [0, 1]);
    // 再次缓存：跳过已存在的
    await svc.cacheBook(book, chapters);
    expect(fetched, [0, 1]);
  });

  test('deleteChapter 清理', () async {
    await BookCacheService.instance.setRoot(tmp);
    final svc = BookCacheService.instance;
    final book = makeBook();
    await svc.putChapter(book, 0, BookContent(body: 'abc', title: 't', succeed: true));
    await svc.deleteChapter(book, 0);
    expect(svc.isChapterCached(book, 0), isFalse);
    expect(await svc.getChapter(book, 0, 't'), isNull);
  });
}