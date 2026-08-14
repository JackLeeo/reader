// 阅读统计
class ReadingSession {
  final String bookId;
  final DateTime date;
  final Duration duration;
  final int pagesRead;
  final int charsRead;

  ReadingSession({
    required this.bookId,
    required this.date,
    required this.duration,
    this.pagesRead = 0,
    this.charsRead = 0,
  });

  Map<String, dynamic> toJson() => {
        'bookId': bookId,
        'date': date.toIso8601String(),
        'duration': duration.inSeconds,
        'pagesRead': pagesRead,
        'charsRead': charsRead,
      };

  factory ReadingSession.fromJson(Map<String, dynamic> json) => ReadingSession(
        bookId: (json['bookId'] ?? '').toString(),
        date: DateTime.tryParse((json['date'] ?? '').toString()) ??
            DateTime.now(),
        duration: Duration(seconds: (json['duration'] ?? 0) as int),
        pagesRead: (json['pagesRead'] ?? 0) as int,
        charsRead: (json['charsRead'] ?? 0) as int,
      );
}

/// 每日聚合统计
class DailyStats {
  final DateTime date; // 当天零点
  final int totalSeconds;
  final int totalChars;
  final int totalPages;
  final Set<String> booksRead;

  DailyStats({
    required this.date,
    this.totalSeconds = 0,
    this.totalChars = 0,
    this.totalPages = 0,
    Set<String>? booksRead,
  }) : booksRead = booksRead ?? <String>{};

  DailyStats merge(ReadingSession s) {
    return DailyStats(
      date: date,
      totalSeconds: totalSeconds + s.duration.inSeconds,
      totalChars: totalChars + s.charsRead,
      totalPages: totalPages + s.pagesRead,
      booksRead: booksRead..add(s.bookId),
    );
  }

  Map<String, dynamic> toJson() => {
        'date': date.toIso8601String(),
        'totalSeconds': totalSeconds,
        'totalChars': totalChars,
        'totalPages': totalPages,
        'booksRead': booksRead.toList(),
      };

  factory DailyStats.fromJson(Map<String, dynamic> json) => DailyStats(
        date: DateTime.tryParse((json['date'] ?? '').toString()) ??
            DateTime.now(),
        totalSeconds: (json['totalSeconds'] ?? 0) as int,
        totalChars: (json['totalChars'] ?? 0) as int,
        totalPages: (json['totalPages'] ?? 0) as int,
        booksRead: (json['booksRead'] as List?)?.cast<String>().toSet() ??
            <String>{},
      );
}
