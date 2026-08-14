// 本地书籍（用户导入的TXT）
class LocalBook {
  final String id; // 文件 hash
  final String name;
  final String author;
  final String filePath;
  final int fileSize;
  final DateTime addedAt;
  int lastChapterIndex;
  int lastOffset;

  LocalBook({
    required this.id,
    required this.name,
    this.author = '',
    required this.filePath,
    this.fileSize = 0,
    DateTime? addedAt,
    this.lastChapterIndex = 0,
    this.lastOffset = 0,
  }) : addedAt = addedAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'author': author,
        'filePath': filePath,
        'fileSize': fileSize,
        'addedAt': addedAt.toIso8601String(),
        'lastChapterIndex': lastChapterIndex,
        'lastOffset': lastOffset,
      };

  factory LocalBook.fromJson(Map<String, dynamic> json) => LocalBook(
        id: (json['id'] ?? '').toString(),
        name: (json['name'] ?? '').toString(),
        author: (json['author'] ?? '').toString(),
        filePath: (json['filePath'] ?? '').toString(),
        fileSize: (json['fileSize'] ?? 0) as int,
        addedAt: DateTime.tryParse((json['addedAt'] ?? '').toString()) ??
            DateTime.now(),
        lastChapterIndex: (json['lastChapterIndex'] ?? 0) as int,
        lastOffset: (json['lastOffset'] ?? 0) as int,
      );
}
