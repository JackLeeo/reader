/// 搜索 / 书籍 / 章节 / 正文 实体。
library;

/// 聚合搜索结果单条（对应官方 `SearchBook`）。
class SearchBook {
  SearchBook({
    this.name = '',
    this.author,
    this.coverUrl,
    this.bookUrl = '',
    this.intro,
    this.origin = '',
    this.note,
    this.type = 0,
  });

  String name;
  String? author;
  String? coverUrl;
  String bookUrl;
  String? intro;
  String origin;
  String? note;
  int type;

  /// 书名（无作者）唯一键
  String get key => name;

  /// 是否文本源（type=0，官方 bookSourceType）。
  bool get isText => type == 0;

  /// 是否音频/听书源（type=1）。
  bool get isAudioSource => type == 1;

  /// 是否图片/漫画源（type=2）。
  bool get isImageSource => type == 2;

  /// 是否媒体源（非文本）。
  bool get isMediaSource => type != 0;

  @override
  String toString() => name.isEmpty ? '未知' : name;
}

/// 书籍详情（对应官方 `Book`）。
class Book {
  Book({
    this.name = '',
    this.author,
    this.coverUrl,
    this.bookUrl = '',
    this.intro,
    this.tocUrl,
    this.lastChapter,
    this.kind,
    this.wordCount,
    this.type = 0,
    this.origin = '',
    this.sourceTag = '',
  });

  String name;
  String? author;
  String? coverUrl;
  String bookUrl;
  String? intro;
  String? tocUrl;
  String? lastChapter;
  String? kind;
  String? wordCount;
  int type;
  String origin;
  String sourceTag;

  /// 是否文本源（type=0，官方 bookSourceType）。
  bool get isText => type == 0;

  /// 是否音频/听书源（type=1）。
  bool get isAudioSource => type == 1;

  /// 是否图片/漫画源（type=2）。
  bool get isImageSource => type == 2;

  /// 是否媒体源（非文本）。
  bool get isMediaSource => type != 0;

  /// 是否视频源（type=4）。
  bool get isVideoSource => type == 4;
}

/// 章节目录项（对应官方 `BookChapter`）。
class BookChapter {
  BookChapter({
    this.title = '',
    this.url = '',
    this.displayTitle,
    this.isVolume = false,
    this.isVip = false,
    this.isPay = false,
  });

  String title;
  String url;
  String? displayTitle;
  bool isVolume;
  bool isVip;
  bool isPay;

  /// 是否卷标记（仅对章节管理有意义）
  bool get isHeader => displayTitle == null && isVolume;
}

/// 章节正文（对应官方 `BookContent`）。
class BookContent {
  BookContent({
    this.body = '',
    this.title = '',
    this.sourceUrl = '',
    this.nextUrl,
    this.succeed = false,
    this.msg = '',
  });

  String body;
  String title;
  String sourceUrl;
  String? nextUrl;
  bool succeed;
  String msg;

  /// 合并正文与下一章正文（分页加载用）
  void withBody(String more) {
    if (body.isEmpty) {
      body = more;
    } else {
      body += '\n\n$more';
    }
  }
}