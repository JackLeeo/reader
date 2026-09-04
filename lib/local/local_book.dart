/// 本地书数据模型（含 JSON 序列化，供本地书存储持久化）。
class LocalChapter {
  LocalChapter({this.title = '', this.content = ''});
  String title;
  String content;

  factory LocalChapter.fromJson(Map<String, dynamic> m) => LocalChapter(
        title: (m['title'] as String?) ?? '',
        content: (m['content'] as String?) ?? '',
      );

  Map<String, dynamic> toJson() => {'title': title, 'content': content};
}

class LocalBook {
  LocalBook({
    this.name = '',
    this.author,
    this.cover,
    this.chapters = const [],
  });
  String name;
  String? author;

  /// 封面引用：`data:` 内嵌(data URI)或 `file://`(已落盘)。
  String? cover;
  List<LocalChapter> chapters;

  /// 本地书唯一键（用书名）。
  String get key => name;

  factory LocalBook.fromJson(Map<String, dynamic> m) => LocalBook(
        name: (m['name'] as String?) ?? '',
        author: m['author'] as String?,
        cover: m['cover'] as String?,
        chapters: ((m['chapters'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => LocalChapter.fromJson(e.cast<String, dynamic>()))
            .toList(),
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'author': author,
        'cover': cover,
        'chapters': chapters.map((c) => c.toJson()).toList(),
      };
}