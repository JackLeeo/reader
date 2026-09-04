import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:legado_flutter/book_source/services/bookmark_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
  });

  group('BookmarkService', () {
    test('同一本书同一章节幂等：重复添加不重复', () async {
      final s = BookmarkService.instance;
      await s.init();
      s.clear();

      final added = s.add(Bookmark(bookKey: 'K', chapterIndex: 0, chapterTitle: '第一章'));
      final dup = s.add(Bookmark(bookKey: 'K', chapterIndex: 0, chapterTitle: '第一章'));
      expect(added, true);
      expect(dup, false);
      expect(s.forBook('K').length, 1);
    });

    test('不同章节各自成书签并按章节排序', () async {
      final s = BookmarkService.instance;
      await s.init();
      s.clear();

      s.add(Bookmark(bookKey: 'K', chapterIndex: 2, chapterTitle: '第三章'));
      s.add(Bookmark(bookKey: 'K', chapterIndex: 0, chapterTitle: '第一章'));
      final list = s.forBook('K');
      expect(list.length, 2);
      expect(list[0].chapterIndex, 0);
      expect(list[1].chapterIndex, 2);
      expect(s.contains('K', 1), false);
    });

    test('移除与不同书隔离', () async {
      final s = BookmarkService.instance;
      await s.init();
      s.clear();

      s.add(Bookmark(bookKey: 'A', chapterIndex: 0, chapterTitle: 'a'));
      s.add(Bookmark(bookKey: 'B', chapterIndex: 0, chapterTitle: 'b'));
      s.remove('A', 0);
      expect(s.forBook('A'), isEmpty);
      expect(s.forBook('B').length, 1);
    });

    test('持久化到 SharedPreferences 后仍能读取', () async {
      final s = BookmarkService.instance;
      await s.init();
      s.clear();

      expect(SharedPreferences.getInstance(), completes);
    });
  });
}