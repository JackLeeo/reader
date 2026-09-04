import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 阅读书签。
class Bookmark {
  Bookmark({
    required this.bookKey,
    required this.chapterIndex,
    required this.chapterTitle,
    this.addTime = 0,
  });

  final String bookKey;
  final int chapterIndex;
  final String chapterTitle;
  final int addTime;

  factory Bookmark.fromJson(Map<String, dynamic> m) => Bookmark(
        bookKey: (m['bookKey'] ?? '') as String,
        chapterIndex: (m['chapterIndex'] ?? 0) as int,
        chapterTitle: (m['chapterTitle'] ?? '') as String,
        addTime: (m['addTime'] ?? 0) as int,
      );

  Map<String, dynamic> toJson() => {
        'bookKey': bookKey,
        'chapterIndex': chapterIndex,
        'chapterTitle': chapterTitle,
        'addTime': addTime,
      };

  /// 去重键：同一本书同章节只留一个书签。
  String get dedupeKey => '$bookKey|$chapterIndex';
}

/// 书签服务：按书持久化章节书签。
class BookmarkService {
  BookmarkService._();

  static final BookmarkService instance = BookmarkService._();

  static const String _prefsKey = 'reader_bookmarks_v1';

  final List<Bookmark> _items = [];
  bool initialized = false;

  List<Bookmark> forBook(String bookKey) =>
      _items.where((b) => b.bookKey == bookKey).toList()
        ..sort((a, b) => a.chapterIndex.compareTo(b.chapterIndex));

  /// 全部书签（按添加时间倒序）。
  List<Bookmark> get all => List.of(_items)
    ..sort((a, b) => b.addTime.compareTo(a.addTime));

  /// 全部书的去重书签键（用于分组展示）。
  List<String> get bookKeys {
    final seen = <String>{};
    final out = <String>[];
    for (final b in _items) {
      if (seen.add(b.bookKey)) out.add(b.bookKey);
    }
    return out;
  }

  Future<void> init() async {
    if (initialized) return;
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_prefsKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        _items
          ..clear()
          ..addAll((jsonDecode(raw) as List)
              .map((e) => Bookmark.fromJson(e as Map<String, dynamic>)));
      } catch (_) {
        _items.clear();
      }
    }
    initialized = true;
  }

  /// 返回是否新增（同书同章重复则幂等保留首次）。
  bool add(Bookmark bm) {
    final existing = _items.any((b) => b.dedupeKey == bm.dedupeKey);
    if (existing) return false;
    _items.add(bm);
    save();
    return true;
  }

  void remove(String bookKey, int chapterIndex) {
    _items.removeWhere(
        (b) => b.bookKey == bookKey && b.chapterIndex == chapterIndex);
    save();
  }

  bool contains(String bookKey, int chapterIndex) =>
      _items.any((b) => b.bookKey == bookKey && b.chapterIndex == chapterIndex);

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(
        _prefsKey, jsonEncode(_items.map((b) => b.toJson()).toList()));
  }

  void clear() {
    _items.clear();
  }
}