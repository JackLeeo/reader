// 书签 / 笔记
class Bookmark {
  final String bookId;
  final int chapterIndex;
  final String chapterTitle;
  final int offset; // 章节内字符 offset
  final String snippet; // 选中的文字片段
  final String? note; // 用户笔记（可空）
  final DateTime createdAt;

  Bookmark({
    required this.bookId,
    required this.chapterIndex,
    required this.chapterTitle,
    this.offset = 0,
    this.snippet = '',
    this.note,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  String get key => '${bookId}_${chapterIndex}_$offset';

  Map<String, dynamic> toJson() => {
        'bookId': bookId,
        'chapterIndex': chapterIndex,
        'chapterTitle': chapterTitle,
        'offset': offset,
        'snippet': snippet,
        'note': note,
        'createdAt': createdAt.toIso8601String(),
      };

  factory Bookmark.fromJson(Map<String, dynamic> json) => Bookmark(
        bookId: (json['bookId'] ?? '').toString(),
        chapterIndex: (json['chapterIndex'] ?? 0) as int,
        chapterTitle: (json['chapterTitle'] ?? '').toString(),
        offset: (json['offset'] ?? 0) as int,
        snippet: (json['snippet'] ?? '').toString(),
        note: json['note'] as String?,
        createdAt: DateTime.tryParse((json['createdAt'] ?? '').toString()) ??
            DateTime.now(),
      );
}
