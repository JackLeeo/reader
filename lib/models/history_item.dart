// 历史记录项
import 'book.dart';

class HistoryItem {
  final Book book;
  final DateTime readTime;
  final int chapterIndex;
  final int chapterCount;
  final String chapterTitle;

  HistoryItem({
    required this.book,
    required this.readTime,
    required this.chapterIndex,
    required this.chapterCount,
    required this.chapterTitle,
  });

  String get id => '${book.id}_$chapterIndex';

  double get progress {
    if (chapterCount <= 0) return 0;
    return (chapterIndex + 1) / chapterCount;
  }

  Map<String, dynamic> toJson() => {
        'book': book.toJson(),
        'readTime': readTime.toIso8601String(),
        'chapterIndex': chapterIndex,
        'chapterCount': chapterCount,
        'chapterTitle': chapterTitle,
      };

  factory HistoryItem.fromJson(Map<String, dynamic> json) => HistoryItem(
        book: Book.fromJson(json['book'] as Map<String, dynamic>),
        readTime:
            DateTime.tryParse((json['readTime'] ?? '').toString()) ?? DateTime.now(),
        chapterIndex: (json['chapterIndex'] ?? 0) as int,
        chapterCount: (json['chapterCount'] ?? 0) as int,
        chapterTitle: (json['chapterTitle'] ?? '').toString(),
      );
}
