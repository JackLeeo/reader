// 书籍数据模型
class Book {
  final String name;
  final String author;
  final String coverUrl;
  final String intro;
  final String kind;
  final String lastChapter;
  final String wordCount;
  final String tocUrl; // 目录页URL（用于进一步解析章节目录）
  final String bookUrl; // 书籍详情页URL
  final String sourceId; // 所属书源ID
  final String sourceName;

  Book({
    required this.name,
    this.author = '',
    this.coverUrl = '',
    this.intro = '',
    this.kind = '',
    this.lastChapter = '',
    this.wordCount = '',
    this.tocUrl = '',
    required this.bookUrl,
    required this.sourceId,
    required this.sourceName,
  });

  /// 生成稳定ID
  String get id {
    return '${sourceId}_${bookUrl.hashCode.toRadixString(16)}';
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'author': author,
        'coverUrl': coverUrl,
        'intro': intro,
        'kind': kind,
        'lastChapter': lastChapter,
        'wordCount': wordCount,
        'tocUrl': tocUrl,
        'bookUrl': bookUrl,
        'sourceId': sourceId,
        'sourceName': sourceName,
      };

  factory Book.fromJson(Map<String, dynamic> json) => Book(
        name: (json['name'] ?? '').toString(),
        author: (json['author'] ?? '').toString(),
        coverUrl: (json['coverUrl'] ?? '').toString(),
        intro: (json['intro'] ?? '').toString(),
        kind: (json['kind'] ?? '').toString(),
        lastChapter: (json['lastChapter'] ?? '').toString(),
        wordCount: (json['wordCount'] ?? '').toString(),
        tocUrl: (json['tocUrl'] ?? '').toString(),
        bookUrl: (json['bookUrl'] ?? '').toString(),
        sourceId: (json['sourceId'] ?? '').toString(),
        sourceName: (json['sourceName'] ?? '').toString(),
      );

  Book copyWith({
    String? name,
    String? author,
    String? coverUrl,
    String? intro,
    String? kind,
    String? lastChapter,
    String? wordCount,
    String? tocUrl,
  }) {
    return Book(
      name: name ?? this.name,
      author: author ?? this.author,
      coverUrl: coverUrl ?? this.coverUrl,
      intro: intro ?? this.intro,
      kind: kind ?? this.kind,
      lastChapter: lastChapter ?? this.lastChapter,
      wordCount: wordCount ?? this.wordCount,
      tocUrl: tocUrl ?? this.tocUrl,
      bookUrl: bookUrl,
      sourceId: sourceId,
      sourceName: sourceName,
    );
  }
}
