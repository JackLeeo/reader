import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 书架排序方式（对齐官方书籍排序）。
enum SortMode {
  addTime, // 添加时间（默认）
  recentRead, // 最近阅读（按章序）
  name,
  author,
  progress, // 阅读进度
}

/// 书架上的一本书（持久化用）。
class ShelfBook {
  ShelfBook({
    required this.name,
    this.author,
    this.coverUrl,
    required this.bookUrl,
    required this.origin,
    required this.sourceTag,
    this.intro,
    this.lastChapter,
    this.lastReadIndex = 0,
    this.lastReadChapter = '',
    this.readingProgress = 0.0,
    this.addTime = 0,
    this.isLocal = false,
    this.lastReadPage = 0,
    this.group = '',
    this.locked = false,
  });

  final String name;
  final String? author;
  final String? coverUrl;
  final String bookUrl;
  final String origin;
  final String sourceTag;
  final String? intro;
  final String? lastChapter;
  final int lastReadIndex;
  final String lastReadChapter;
  final double readingProgress;
  final int addTime;
  final bool isLocal;
  final int lastReadPage;

  /// 所属书架分组（官方 group，空 = 默认分组）。
  final String group;

  /// 是否锁定来源（官方“源锁定”）。锁定后不再提示/自动换源。
  final bool locked;

  /// 按 [mode] 排序并返回新列表（不动原列表）。
  static List<ShelfBook> sortShelf(List<ShelfBook> src, SortMode mode) {
    final list = List<ShelfBook>.of(src);
    switch (mode) {
      case SortMode.recentRead:
        list.sort((a, b) => b.lastReadIndex.compareTo(a.lastReadIndex));
        break;
      case SortMode.name:
        list.sort((a, b) => a.name.compareTo(b.name));
        break;
      case SortMode.author:
        list.sort((a, b) => (a.author ?? '').compareTo(b.author ?? ''));
        break;
      case SortMode.progress:
        list.sort((a, b) => b.readingProgress.compareTo(a.readingProgress));
        break;
      default:
        list.sort((a, b) => b.addTime.compareTo(a.addTime));
    }
    return list;
  }

  static String? _s(Map<String, dynamic> m, String k) => m[k] as String?;
  static int _i(Map<String, dynamic> m, String k) =>
      m[k] is int ? m[k] as int : int.tryParse('${m[k]}') ?? 0;

  factory ShelfBook.fromJson(Map<String, dynamic> m) => ShelfBook(
        name: _s(m, 'name') ?? '',
        author: _s(m, 'author'),
        coverUrl: _s(m, 'coverUrl'),
        bookUrl: _s(m, 'bookUrl') ?? '',
        origin: _s(m, 'origin') ?? '',
        sourceTag: _s(m, 'sourceTag') ?? '',
        intro: _s(m, 'intro'),
        lastChapter: _s(m, 'lastChapter'),
        lastReadIndex: _i(m, 'lastReadIndex'),
        lastReadChapter: _s(m, 'lastReadChapter') ?? '',
        readingProgress: (m['readingProgress'] as num?)?.toDouble() ?? 0,
        addTime: _i(m, 'addTime'),
        isLocal: (m['isLocal'] as bool?) ?? false,
        lastReadPage: _i(m, 'lastReadPage'),
        group: _s(m, 'group') ?? '',
        locked: (m['locked'] as bool?) ?? false,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'author': author,
        'coverUrl': coverUrl,
        'bookUrl': bookUrl,
        'origin': origin,
        'sourceTag': sourceTag,
        'intro': intro,
        'lastChapter': lastChapter,
        'lastReadIndex': lastReadIndex,
        'lastReadChapter': lastReadChapter,
        'readingProgress': readingProgress,
        'addTime': addTime,
        'isLocal': isLocal,
        'lastReadPage': lastReadPage,
        'group': group,
        'locked': locked,
      };

  /// 唯一键 = 书源 + 书Url（同一书源下同书去重）。
  String get key => isLocal ? 'local|$bookUrl' : '$sourceTag|$bookUrl';
}

/// 书架服务（对应官方 bookshelf + 阅读进度）。
class ShelfService {
  ShelfService._();

  static final ShelfService instance = ShelfService._();

  static const String _prefsKey = 'shelf_books_v1';

  final List<ShelfBook> _books = [];
  bool initialized = false;

  List<ShelfBook> get books => List.unmodifiable(_books);

  ShelfBook? findByKey(String key) {
    for (final b in _books) {
      if (b.key == key) return b;
    }
    return null;
  }

  Future<void> init() async {
    if (initialized) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = jsonDecode(raw) as List;
        _books.clear();
        _books.addAll(
            list.map((e) => ShelfBook.fromJson(e as Map<String, dynamic>)));
      } catch (_) {
        _books.clear();
      }
    }
    initialized = true;
  }

  /// 加入书架（已存在则更新信息）。返回是否新增。
  bool addBook(ShelfBook book) {
    final idx = _books.indexWhere((b) => b.key == book.key);
    if (idx >= 0) {
      _books[idx] = book;
      return false;
    }
    _books.add(book);
    return true;
  }

  void removeBook(ShelfBook book) {
    _books.removeWhere((b) => b.key == book.key);
  }

  /// 书架全部分组名（按首次出现顺序），包含默认分组（显示为「默认」）。
  List<String> get groups {
    final seen = <String>['默认'];
    for (final b in _books) {
      if (b.group.trim().isNotEmpty && !seen.contains(b.group)) {
        seen.add(b.group);
      }
    }
    return seen;
  }

  /// 某分组下的书；[group] 为「默认」或空表示默认分组。
  List<ShelfBook> booksInGroup(String group) => [
        for (final b in _books)
          if ((b.group.trim().isEmpty ? '默认' : b.group) == group) b,
      ];

  /// 把某本书移到分组（空 = 默认）。
  void setGroup(ShelfBook book, String group) {
    final idx = _books.indexWhere((b) => b.key == book.key);
    if (idx < 0) return;
    final old = _books[idx];
    _books[idx] = ShelfBook(
      name: old.name,
      author: old.author,
      coverUrl: old.coverUrl,
      bookUrl: old.bookUrl,
      origin: old.origin,
      sourceTag: old.sourceTag,
      intro: old.intro,
      lastChapter: old.lastChapter,
      lastReadIndex: old.lastReadIndex,
      lastReadChapter: old.lastReadChapter,
      readingProgress: old.readingProgress,
      addTime: old.addTime,
      isLocal: old.isLocal,
      lastReadPage: old.lastReadPage,
      group: group.trim().isEmpty ? '' : group.trim(),
    );
  }

  /// 更新阅读进度（按 key 定位，内存 + 持久化）。
  void updateProgress(
    String key, {
    int? lastReadIndex,
    String? lastReadChapter,
    double? readingProgress,
    String? lastChapter,
    int? lastReadPage,
  }) {
    final idx = _books.indexWhere((b) => b.key == key);
    if (idx < 0) return;
    final old = _books[idx];
    _books[idx] = ShelfBook(
      name: old.name,
      author: old.author,
      coverUrl: old.coverUrl,
      bookUrl: old.bookUrl,
      origin: old.origin,
      sourceTag: old.sourceTag,
      intro: old.intro,
      lastChapter: lastChapter ?? old.lastChapter,
      lastReadIndex: lastReadIndex ?? old.lastReadIndex,
      lastReadChapter: lastReadChapter ?? old.lastReadChapter,
      readingProgress: readingProgress ?? old.readingProgress,
      addTime: old.addTime,
      isLocal: old.isLocal,
      lastReadPage: lastReadPage ?? old.lastReadPage,
      group: old.group,
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _prefsKey, jsonEncode(_books.map((b) => b.toJson()).toList()));
  }

  /// 更新书籍元数据（书名/作者/封面/简介）。
  ///
  /// 用于官方 `ui/book/info/edit` 的本地编辑：覆盖原字段并持久化。
  void updateMeta(
    String key, {
    String? name,
    String? author,
    String? coverUrl,
    String? intro,
  }) {
    final idx = _books.indexWhere((b) => b.key == key);
    if (idx < 0) return;
    final old = _books[idx];
    _books[idx] = ShelfBook(
      name: name ?? old.name,
      author: author != null ? (author.isEmpty ? null : author) : old.author,
      coverUrl: coverUrl != null
          ? (coverUrl.isEmpty ? null : coverUrl)
          : old.coverUrl,
      bookUrl: old.bookUrl,
      origin: old.origin,
      sourceTag: old.sourceTag,
      intro: intro != null ? (intro.isEmpty ? null : intro) : old.intro,
      lastChapter: old.lastChapter,
      lastReadIndex: old.lastReadIndex,
      lastReadChapter: old.lastReadChapter,
      readingProgress: old.readingProgress,
      addTime: old.addTime,
      isLocal: old.isLocal,
      lastReadPage: old.lastReadPage,
      group: old.group,
    );
  }

  /// 设置是否锁定来源（官方“源锁定”）。
  void setLocked(String key, bool locked) {
    final idx = _books.indexWhere((b) => b.key == key);
    if (idx < 0) return;
    final old = _books[idx];
    _books[idx] = _copy(old, locked: locked);
  }

  /// 用字段覆盖重建 [ShelfBook]。
  ShelfBook _copy(ShelfBook old, {bool? locked}) => ShelfBook(
        name: old.name,
        author: old.author,
        coverUrl: old.coverUrl,
        bookUrl: old.bookUrl,
        origin: old.origin,
        sourceTag: old.sourceTag,
        intro: old.intro,
        lastChapter: old.lastChapter,
        lastReadIndex: old.lastReadIndex,
        lastReadChapter: old.lastReadChapter,
        readingProgress: old.readingProgress,
        addTime: old.addTime,
        isLocal: old.isLocal,
        lastReadPage: old.lastReadPage,
        group: old.group,
        locked: locked ?? old.locked,
      );

  /// 测试用清空。
  void clear() {
    _books.clear();
  }
}