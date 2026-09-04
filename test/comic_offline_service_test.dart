import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:legado_flutter/book_source/models/books.dart';
import 'package:legado_flutter/book_source/services/comic_offline_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('comic_offline_test_');
  });

  tearDown(() async {
    ComicOfflineService.instance.reset();
    if (tmp.existsSync()) {
      await tmp.delete(recursive: true);
    }
  });

  Book makeBook({String tag = 'https://manga.a.com', String url = 'https://manga.a.com/book/1'}) =>
      Book(
        name: '测试漫画',
        bookUrl: url,
        type: 2, // 图片/漫画源
        origin: '漫画源',
        sourceTag: tag,
      );

  test('downloadChapter 下载到缓存并标记已下载', () async {
    await ComicOfflineService.instance.setRoot(tmp);
    final off = ComicOfflineService.instance;
    off.fetchBytesOverride = (url) async => 'img-$url'.codeUnits;

    final book = makeBook();
    final chapter = BookChapter(title: '第1话', url: 'https://manga.a.com/c1');

    await off.downloadChapter(book, chapter, 0, urls: ['https://manga.a.com/i1.jpg', 'https://manga.a.com/i2.jpg']);

    expect(off.isChapterDownloaded(book, 0), isTrue);
    final files = off.offlineChapterImages(book, 0);
    expect(files.length, 2);
    // 内容确实写入
    expect(File(files[0].path).readAsStringSync(), 'img-https://manga.a.com/i1.jpg');
    // 排序稳定（按文件名 0000,0001）。
    expect(files[0].path, endsWith('0000.img'));
    expect(files[1].path, endsWith('0001.img'));
  });

  test('任一图片失败时整章作废（不标记成功）', () async {
    await ComicOfflineService.instance.setRoot(tmp);
    final off = ComicOfflineService.instance;
    off.fetchBytesOverride = (url) async {
      if (url.contains('i2')) return null; // 第二张失败
      return [1, 2, 3];
    };

    final book = makeBook();
    await off.downloadChapter(
      book,
      BookChapter(title: '第2话', url: 'c2'),
      1,
      urls: ['http://a/i1.jpg', 'http://a/i2.jpg'],
    );

    expect(off.isChapterDownloaded(book, 1), isFalse);
    expect(off.downloadedChapters(book), isEmpty);
  });

  test('重复下载默认跳过；force 重新抓取', () async {
    await ComicOfflineService.instance.setRoot(tmp);
    final off = ComicOfflineService.instance;
    var calls = 0;
    off.fetchBytesOverride = (url) async {
      calls++;
      return [1, 2, 3];
    };

    final book = makeBook();
    await off.downloadChapter(book, BookChapter(title: 't', url: 'u'), 2, urls: ['http://a/i.jpg']);
    final afterFirst = calls;
    await off.downloadChapter(book, BookChapter(title: 't', url: 'u'), 2, urls: ['http://a/i.jpg']);
    expect(calls, afterFirst); // 未重新抓取

    await off.downloadChapter(book, BookChapter(title: 't', url: 'u'), 2, urls: ['http://a/i.jpg'], force: true);
    expect(calls, afterFirst + 1); // force 重新抓取
  });

  test('downloadedChapters 返回升序且只含有效章节', () async {
    await ComicOfflineService.instance.setRoot(tmp);
    final off = ComicOfflineService.instance;
    off.fetchBytesOverride = (url) async => [1, 2, 3];

    final book = makeBook();
    await off.downloadChapter(book, BookChapter(title: 'c', url: 'u'), 5, urls: ['http://a/i.jpg']);
    await off.downloadChapter(book, BookChapter(title: 'c', url: 'u'), 2, urls: ['http://a/i.jpg']);

    expect(off.downloadedChapters(book), [2, 5]);
  });

  test('deleteChapter 清理文件与状态', () async {
    await ComicOfflineService.instance.setRoot(tmp);
    final off = ComicOfflineService.instance;
    off.fetchBytesOverride = (url) async => [1, 2, 3];

    final book = makeBook();
    await off.downloadChapter(book, BookChapter(title: 'c', url: 'u'), 0, urls: ['http://a/i.jpg']);
    expect(off.isChapterDownloaded(book, 0), isTrue);

    await off.deleteChapter(book, 0);
    expect(off.isChapterDownloaded(book, 0), isFalse);
    expect(off.downloadedChapters(book), isEmpty);
  });

  test('folderOf 文件系统安全化', () {
    final book = makeBook();
    final folder = ComicOfflineService.folderOf(book);
    expect(folder.contains('|'), isFalse);
    expect(folder.contains('/'), isFalse);
    expect(folder.contains(':'), isFalse);
    expect(folder.contains('?'), isFalse);
    expect(folder.isNotEmpty, isTrue);
    // 允许字符：字母/数字/_/-/点/中文。
    expect(RegExp(r'^[\w\u4e00-\u9fa5.-]+$').hasMatch(folder), isTrue);
  });
}