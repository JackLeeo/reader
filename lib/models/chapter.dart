// 章节数据模型
class Chapter {
  final String title;
  final String url;
  final int index;
  final bool isVolume; // 是否为卷标

  Chapter({
    required this.title,
    required this.url,
    required this.index,
    this.isVolume = false,
  });

  Map<String, dynamic> toJson() => {
        'title': title,
        'url': url,
        'index': index,
        'isVolume': isVolume,
      };

  factory Chapter.fromJson(Map<String, dynamic> json) => Chapter(
        title: (json['title'] ?? '').toString(),
        url: (json['url'] ?? '').toString(),
        index: (json['index'] ?? 0) as int,
        isVolume: json['isVolume'] == true,
      );
}
