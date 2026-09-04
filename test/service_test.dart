import 'package:flutter_test/flutter_test.dart';
import 'package:legado_flutter/book_source/models/books.dart';
import 'package:legado_flutter/book_source/models/book_source.dart';
import 'package:legado_flutter/book_source/services/backup_service.dart';
import 'package:legado_flutter/book_source/services/book_source_service.dart';
import 'package:legado_flutter/book_source/services/rss_service.dart';
import 'package:legado_flutter/book_source/services/search_service.dart';
import 'package:legado_flutter/book_source/services/shelf_service.dart';
import 'package:legado_flutter/book_source/services/switch_source_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('BookSourceService — 书源管理', () {
    setUp(() => BookSourceService.instance.clear());

    BookSource makeSource(String url, {String? group, bool enabled = true}) =>
        BookSource.fromJson({
          'bookSourceUrl': url,
          'bookSourceName': '源$url',
          'bookSourceGroup': group,
          'enabled': enabled,
          'searchUrl': 'https://$url/search?key={key}',
        });

    test('importAll 合并覆盖，按 URL 去重', () {
      final svc = BookSourceService.instance;
      svc.importAll([
        makeSource('a.com'),
        makeSource('b.com'),
        makeSource('a.com'),
      ]);
      expect(svc.sources.length, 2);
    });

    test('分组解析（中英文分隔符）', () {
      final s = BookSource.fromJson({
        'bookSourceUrl': 'x.com',
        'bookSourceGroup': '文学,玄幻&言情',
      });
      expect(s.groups, ['文学', '玄幻', '言情']);
    });

    test('启用/禁用只作用于单个源', () {
      final svc = BookSourceService.instance;
      svc.importAll([makeSource('c.com'), makeSource('d.com', enabled: false)]);
      svc.setEnabled('c.com', false);
      expect(svc.sources.where((s) => s.bookSourceUrl == 'c.com').first.enabled,
          false);
      expect(svc.enabledSources.length, 0);
      svc.setEnabled('c.com', true);
      expect(svc.enabledSources.length, 1);
    });

    test('导出后重导入结构一致', () {
      final svc = BookSourceService.instance;
      svc.importAll([makeSource('e.com')]);
      final json = svc.exportAll();
      final svc2 = BookSourceService.instance;
      svc2.importFromJson(json);
      expect(svc2.sources.any((s) => s.bookSourceUrl == 'e.com'), isTrue);
    });

    test('eventListener / customButton 解析并往返', () {
      final s = BookSource.fromJson({
        'bookSourceUrl': 'b.com',
        'bookSourceName': '带按钮',
        'searchUrl': 'https://b.com/s?key={key}',
        'eventListener': true,
        'customButton': true,
      });
      expect(s.eventListener, isTrue);
      expect(s.customButton, isTrue);
      // 序列化后重解析保持一致
      final s2 = BookSource.fromJson(s.toJson());
      expect(s2.eventListener, isTrue);
      expect(s2.customButton, isTrue);
      // 缺省为 false
      final s3 = BookSource.fromJson({'bookSourceUrl': 'c.com'});
      expect(s3.eventListener, isFalse);
      expect(s3.customButton, isFalse);
    });
  });

  group('SearchService — 搜索 URL 关键字', () {
    test('替换 {key} 与 {searchKey} 并 URL 编码', () {
      final replaced =
              SearchService.replaceKey('https://a.com/s?k={key}&s={searchKey}', '斗破苍穹');
      expect(replaced.contains(Uri.encodeComponent('斗破苍穹')), isTrue);
      expect(replaced.contains('{key}'), isFalse);
      expect(replaced.contains('{searchKey}'), isFalse);
    });
  });

  group('ShelfService — 书架', () {
    setUp(() => ShelfService.instance.clear());

    ShelfBook shelf(String url) => ShelfBook(
          name: '书名',
          bookUrl: url,
          origin: '源A',
          sourceTag: 'https://a.com',
          addTime: 0,
        );

    test('添加去重唯一键', () {
      final svc = ShelfService.instance;
      final added1 = svc.addBook(shelf('https://a.com/book/1'));
      final added2 = svc.addBook(shelf('https://a.com/book/1'));
      expect(added1, isTrue);
      expect(added2, isFalse);
      expect(svc.books.length, 1);
    });

    test('更新进度保留字段', () {
      final svc = ShelfService.instance;
      final b = shelf('https://a.com/book/1');
      svc.addBook(b);
      svc.updateProgress(
        b.key,
        lastReadIndex: 5,
        lastReadChapter: '第6章',
        readingProgress: 0.6,
      );
      final updated = svc.books.first;
      expect(updated.lastReadIndex, 5);
      expect(updated.lastReadChapter, '第6章');
      expect(updated.name, '书名');
    });

    test('序列化往返', () {
      final b = shelf('https://a.com/book/2');
      final round = ShelfBook.fromJson(b.toJson());
      expect(round.bookUrl, b.bookUrl);
      expect(round.key, b.key);
    });

    test('updateMeta 编辑书名/作者/简介/封面', () {
      final svc = ShelfService.instance;
      final b = shelf('https://a.com/book/3');
      svc.addBook(b);
      svc.updateMeta(
        b.key,
        name: '新书名',
        author: '新作者',
        intro: '新简介',
        coverUrl: 'https://c.png',
      );
      final updated = svc.findByKey(b.key)!;
      expect(updated.name, '新书名');
      expect(updated.author, '新作者');
      expect(updated.intro, '新简介');
      expect(updated.coverUrl, 'https://c.png');
      // bookUrl/origin/sourceTag 不被改
      expect(updated.bookUrl, b.bookUrl);
      expect(updated.key, b.key);
    });

    test('updateMeta 传空串清空可编辑字段', () {
      final svc = ShelfService.instance;
      final b = shelf('https://a.com/book/4');
      svc.addBook(b);
      svc.updateMeta(b.key, author: '');
      expect(svc.findByKey(b.key)!.author, isNull);
    });

    test('分组：setGroup / groups / booksInGroup', () {
      final svc = ShelfService.instance;
      final a = shelf('https://a.com/book/g1');
      final b2 = shelf('https://a.com/book/g2');
      final c = shelf('https://a.com/book/g3');
      svc.addBook(a);
      svc.addBook(b2);
      svc.addBook(c);
      // 默认分组包含全部（group 为空）
      expect(svc.booksInGroup('默认').length, 3);
      // 移动到分组
      svc.setGroup(a, '玄幻');
      svc.setGroup(b2, '玄幻');
      svc.setGroup(c, '都市');
      expect(svc.groups, ['默认', '玄幻', '都市']);
      expect(svc.booksInGroup('玄幻').map((b) => b.bookUrl),
          ['https://a.com/book/g1', 'https://a.com/book/g2']);
      expect(svc.booksInGroup('都市').single.bookUrl, 'https://a.com/book/g3');
      expect(svc.booksInGroup('默认'), isEmpty);
    });

    test('分组：更新进度/元数据不清空分组', () {
      final svc = ShelfService.instance;
      final b = shelf('https://a.com/book/g4');
      svc.addBook(b);
      svc.setGroup(b, '历史');
      svc.updateProgress(
        b.key,
        lastReadIndex: 9,
        lastReadChapter: '第10章',
        readingProgress: 0.9,
      );
      svc.updateMeta(b.key, name: '改名');
      final updated = svc.findByKey(b.key)!;
      expect(updated.group, '历史');
      expect(updated.lastReadIndex, 9);
      expect(updated.name, '改名');
    });

    test('分组：序列化往返保留 group', () {
      final b = shelf('https://a.com/book/g5');
      final withGroup = ShelfBook(
        name: b.name,
        bookUrl: b.bookUrl,
        origin: b.origin,
        sourceTag: b.sourceTag,
        addTime: 0,
        group: '完本',
      );
      final round = ShelfBook.fromJson(withGroup.toJson());
      expect(round.group, '完本');
    });
  });

  group('SwitchSourceService — 换源匹配', () {
    setUp(() => BookSourceService.instance.clear());

    test('无启用书源时返回空列表（不抛错）', () async {
      final book = Book(
        name: '斗破苍穹',
        author: '天蚕土豆',
        bookUrl: 'u1',
        origin: '源A',
        sourceTag: 'https://a.com',
      );
      final service = SwitchSourceService();
      final hits = await service.findSameBook(book);
      expect(hits, isEmpty);
    });

    test('空书名直接返回空', () async {
      final book = Book(name: '', bookUrl: 'u', origin: '源A', sourceTag: 'x');
      final hits = await SwitchSourceService().findSameBook(book);
      expect(hits, isEmpty);
    });
  });

  group('RssService — 解析', () {
    test('解析 RSS 2.0 源', () {
      const xml = '''
      <rss version="2.0">
        <channel>
          <title>测试源</title>
          <item>
            <title>文章一</title>
            <link>https://a.com/1</link>
            <description><![CDATA[<p>内容</p>]]></description>
          </item>
          <item>
            <title>文章二</title>
            <link>https://a.com/2</link>
          </item>
        </channel>
      </rss>''';
      final feed = RssService.parseFeed(xml)!;
      expect(feed.title, '测试源');
      expect(feed.items.length, 2);
      expect(feed.items.first.link, 'https://a.com/1');
    });

    test('解析 Atom 源', () {
      const xml = '''
      <feed xmlns="http://www.w3.org/2005/Atom">
        <title>博客</title>
        <entry>
          <title>文章</title>
          <link href="https://b.com/p/1" rel="alternate"/>
          <updated>2026-01-01T00:00:00Z</updated>
        </entry>
      </feed>''';
      final feed = RssService.parseFeed(xml)!;
      expect(feed.title, '博客');
      expect(feed.items.single.link, 'https://b.com/p/1');
    });

    test('订阅源列表增删', () {
      final svc = RssService.instance;
      svc.clear();
      svc.addFeed('https://a.com/rss.xml');
      svc.addFeed('https://a.com/rss.xml'); // 重复
      svc.addFeed('https://b.com/rss.xml');
      expect(svc.urls.length, 2);
      svc.removeFeed('https://a.com/rss.xml');
      expect(svc.urls.length, 1);
    });

    test('文章收藏：toggle / isFavorite', () {
      final svc = RssService.instance;
      svc.clear();
      final item = RssItem(title: '文', link: 'https://a.com/1', description: '');
      expect(svc.isFavorite('feed1', item), isFalse);
      svc.toggleFavorite('feed1', item);
      expect(svc.isFavorite('feed1', item), isTrue);
      expect(svc.isFavorite('feed2', item), isFalse); // 不同源不互相干扰
      svc.toggleFavorite('feed1', item);
      expect(svc.isFavorite('feed1', item), isFalse);
    });
  });

  group('媒体源类型判断', () {
    test('Book / SearchBook 类型 getter', () {
      expect(Book(type: 0).isText, isTrue);
      expect(Book(type: 0).isMediaSource, isFalse);
      expect(Book(type: 1).isAudioSource, isTrue);
      expect(Book(type: 2).isImageSource, isTrue);
      expect(Book(type: 3).isMediaSource, isTrue);
      expect(SearchBook(type: 2).isImageSource, isTrue);
    });

    test('BookSource 类型 getter（0 文本 / 1 音频 / 2 图片 / 3 文件）', () {
      final media = BookSource.fromJson(
          {'bookSourceUrl': 'm.com', 'bookSourceType': 2});
      expect(media.isImageSource, isTrue);
      expect(media.isMediaSource, isTrue);
      expect(media.isTextSource, isFalse);

      final text = BookSource.fromJson(
          {'bookSourceUrl': 't.com', 'bookSourceType': 0});
      expect(text.isTextSource, isTrue);
      expect(text.isMediaSource, isFalse);
    });

    test('BookSource.isExploreSource 需启用且配置 exploreUrl', () {
      final plain = BookSource.fromJson(
          {'bookSourceUrl': 'no.com', 'bookSourceType': 2});
      expect(plain.isExploreSource, isFalse);

      final enabled = BookSource.fromJson({
        'bookSourceUrl': 'es.com',
        'enabledExplore': true,
        'exploreUrl': 'https://es.com/paihang',
      });
      expect(enabled.isExploreSource, isTrue);

      final disabled = BookSource.fromJson({
        'bookSourceUrl': 'ed.com',
        'enabledExplore': false,
        'exploreUrl': 'https://ed.com/paihang',
      });
      expect(disabled.isExploreSource, isFalse);
    });
  });

  group('SearchService — 发现 explore', () {
    setUp(() => BookSourceService.instance.clear());

    test('无 exploreUrl 返回空列表', () async {
      final s = BookSource.fromJson({
        'bookSourceUrl': 'n.com',
        'bookSourceName': '无发现',
        'searchUrl': 'https://n.com/s?key={key}',
        'ruleSearch': {'bookList': 'div.item'},
      });
      final r = await SearchService.instance.explore(s);
      expect(r.hasKinds, isFalse);
      expect(r.books, isEmpty);
    });

    test('有 exploreUrl 但无列表规则返回空（不抛错）', () async {
      final s = BookSource.fromJson({
        'bookSourceUrl': 'p.com',
        'bookSourceName': '有发现无规则',
        'exploreUrl': 'https://p.com/paihang',
        'searchUrl': 'https://p.com/s?key={key}',
      });
      final r = await SearchService.instance.explore(s);
      expect(r.hasKinds, isFalse);
      expect(r.books, isEmpty);
    });
  });

  group('BackupService — 备份恢复', () {
    setUp(() {
      BookSourceService.instance.clear();
      ShelfService.instance.clear();
    });

    test('导出->导入往返', () {
      BookSourceService.instance.importAll([
        BookSource.fromJson({'bookSourceUrl': 'a.com', 'bookSourceName': '源A'}),
      ]);
      ShelfService.instance.addBook(ShelfBook(
        name: '书名',
        bookUrl: 'https://a.com/book/1',
        origin: '源A',
        sourceTag: 'a.com',
        addTime: 0,
      ));
      final json = BackupService.instance.export();

      // 清空后恢复
      BookSourceService.instance.clear();
      ShelfService.instance.clear();
      final r = BackupService.instance.import(json);
      expect(r.sources, 1);
      expect(r.shelf, 1);
      expect(BookSourceService.instance.sources.any((s) => s.bookSourceName == '源A'),
          isTrue);
      expect(ShelfService.instance.books.single.name, '书名');
    });

    test('非法 JSON 抛出 FormatException', () {
      expect(() => BackupService.instance.import('not-json{'),
          throwsFormatException);
    });
  });
}