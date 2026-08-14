// 单元测试 - Bookmark / ShelfBook 模型
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/models/book.dart';
import 'package:reader/models/bookmark.dart';
import 'package:reader/models/chapter.dart';
import 'package:reader/models/local_book.dart';
import 'package:reader/models/reading_stats.dart';
import 'package:reader/models/shelf_book.dart';

void main() {
  group('Bookmark', () {
    test('serializes correctly', () {
      final b = Bookmark(
        bookId: 'b1',
        chapterIndex: 2,
        chapterTitle: '第3章',
        offset: 100,
        snippet: '天地玄黄',
      );
      final json = b.toJson();
      final restored = Bookmark.fromJson(json);
      expect(restored.bookId, 'b1');
      expect(restored.chapterIndex, 2);
      expect(restored.offset, 100);
      expect(restored.snippet, '天地玄黄');
    });

    test('key is deterministic', () {
      final b1 = Bookmark(
        bookId: 'b1',
        chapterIndex: 0,
        chapterTitle: 't',
        offset: 50,
      );
      final b2 = Bookmark(
        bookId: 'b1',
        chapterIndex: 0,
        chapterTitle: 't2',
        offset: 50,
      );
      expect(b1.key, b2.key);
    });
  });

  group('ShelfBook', () {
    test('progress = 0 when no chapters', () {
      final sb = ShelfBook(book: _dummyBook(), totalChapters: 0);
      expect(sb.progress, 0);
    });

    test('progress = 0.5 at half', () {
      final sb = ShelfBook(book: _dummyBook(), lastChapterIndex: 1, totalChapters: 4);
      expect(sb.progress, closeTo(0.5, 0.001));
    });

    test('round trip via JSON', () {
      final sb = ShelfBook(
        book: _dummyBook(),
        lastChapterIndex: 5,
        lastOffset: 200,
        totalChapters: 10,
      );
      final json = sb.toJson();
      final r = ShelfBook.fromJson(json);
      expect(r.lastChapterIndex, 5);
      expect(r.lastOffset, 200);
      expect(r.totalChapters, 10);
    });
  });

  group('LocalBook', () {
    test('round trip', () {
      final b = LocalBook(
        id: 'local_abc',
        name: 'book',
        author: 'author',
        filePath: '/tmp/book.txt',
        fileSize: 1024,
      );
      final j = b.toJson();
      final r = LocalBook.fromJson(j);
      expect(r.id, 'local_abc');
      expect(r.fileSize, 1024);
    });
  });

  group('ReadingSession / DailyStats', () {
    test('merge adds up', () {
      final s1 = ReadingSession(
        bookId: 'a',
        date: DateTime(2026, 1, 1),
        duration: const Duration(minutes: 5),
        charsRead: 100,
      );
      final s2 = ReadingSession(
        bookId: 'b',
        date: DateTime(2026, 1, 1),
        duration: const Duration(minutes: 3),
        charsRead: 50,
      );
      final d = DailyStats(date: DateTime(2026, 1, 1))
          .merge(s1)
          .merge(s2);
      expect(d.totalSeconds, 8 * 60);
      expect(d.totalChars, 150);
      expect(d.booksRead.length, 2);
    });
  });

  group('Chapter', () {
    test('round trip', () {
      final c = Chapter(title: 't1', url: '/u1', index: 0);
      final j = c.toJson();
      final r = Chapter.fromJson(j);
      expect(r.title, 't1');
      expect(r.url, '/u1');
      expect(r.index, 0);
    });
  });
}

Book _dummyBook() => Book(
      name: 'Test',
      author: 'Author',
      bookUrl: 'https://x.com/b/1',
      sourceId: 'src1',
      sourceName: 'src',
    );
