// 书架书籍（带阅读进度）
import 'book.dart';

class ShelfBook {
  final Book book;
  final DateTime addTime;
  DateTime? lastReadTime;
  int lastChapterIndex;
  int lastOffset; // 章节内滚动位置
  int totalChapters;
  String? cachedIntro;

  ShelfBook({
    required this.book,
    DateTime? addTime,
    this.lastReadTime,
    this.lastChapterIndex = 0,
    this.lastOffset = 0,
    this.totalChapters = 0,
    this.cachedIntro,
  }) : addTime = addTime ?? DateTime.now();

  String get id => book.id;

  /// 阅读进度 0-1
  double get progress {
    if (totalChapters <= 0) return 0;
    return (lastChapterIndex + 1) / totalChapters;
  }

  Map<String, dynamic> toJson() => {
        'book': book.toJson(),
        'addTime': addTime.toIso8601String(),
        'lastReadTime': lastReadTime?.toIso8601String(),
        'lastChapterIndex': lastChapterIndex,
        'lastOffset': lastOffset,
        'totalChapters': totalChapters,
        'cachedIntro': cachedIntro,
      };

  factory ShelfBook.fromJson(Map<String, dynamic> json) => ShelfBook(
        book: Book.fromJson(json['book'] as Map<String, dynamic>),
        addTime: DateTime.tryParse((json['addTime'] ?? '').toString()) ??
            DateTime.now(),
        lastReadTime: json['lastReadTime'] != null
            ? DateTime.tryParse((json['lastReadTime'] as String))
            : null,
        lastChapterIndex: (json['lastChapterIndex'] ?? 0) as int,
        lastOffset: (json['lastOffset'] ?? 0) as int,
        totalChapters: (json['totalChapters'] ?? 0) as int,
        cachedIntro: json['cachedIntro'] as String?,
      );
}
