import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/books.dart';
import 'book_service.dart';

/// 文本全本缓存服务（对齐官方「缓存」）。
///
/// 把文本书的章节正文下载并落盘，供离线/省流阅读：
/// - 结构：`{root}/legado_cache/{bookKey}/{chapterIndex}.json`（含 title/body）
/// - 已缓存章节集合以 SharedPreferences 持久化。
/// - 阅读器网络失败或为空时回退读取本地缓存。
///
/// 根目录 [root] 由宿主注入（测试传临时目录，应用用 path_provider）。
class BookCacheService {
  BookCacheService._();

  static final BookCacheService instance = BookCacheService._();

  Directory? _root;
  bool _ready = false;

  final Map<String, Set<int>> _cached = {};

  static const String _prefsKey = 'book_cached_v1';

  /// 可注入的正文抓取函数（联合测试用；为空走 [BookService]）。
  Future<BookContent> Function(Book book, int index, BookChapter chapter)?
      fetchOverride;

  Future<void> setRoot(Directory dir) async {
    _root = Directory('${dir.path}${Platform.pathSeparator}legado_cache');
    if (!_root!.existsSync()) await _root!.create(recursive: true);
    await _load();
    _ready = true;
  }

  bool get ready => _ready;

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_prefsKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final dec = jsonDecode(raw) as Map<String, dynamic>;
      _cached.clear();
      dec.forEach((k, v) {
        final set = <int>{};
        if (v is List) {
          for (final i in v) {
            final n = int.tryParse('$i');
            if (n != null) set.add(n);
          }
        }
        _cached[k] = set;
      });
    } catch (_) {
      _cached.clear();
    }
  }

  Future<void> _persist() async {
    final p = await SharedPreferences.getInstance();
    final enc = <String, dynamic>{
      for (final e in _cached.entries) e.key: e.value.toList().cast<dynamic>(),
    };
    await p.setString(_prefsKey, jsonEncode(enc));
  }

  void reset() {
    _cached.clear();
    _ready = false;
  }

  static String folderOf(Book book) => BookCacheService._folder(book.sourceTag, book.bookUrl);

  static String _folder(String tag, String url) {
    var s = '$tag|$url'.replaceAll(RegExp(r'[^\w\u4e00-\u9fa5.-]'), '_');
    return s.length > 80 ? s.substring(0, 80) : s;
  }

  Directory? _bookDir(Book book) {
    if (_root == null) return null;
    return Directory(
        '${_root!.path}${Platform.pathSeparator}${folderOf(book)}');
  }

  File? _chapterFile(Book book, int index) {
    final d = _bookDir(book);
    if (d == null) return null;
    return File('${d.path}${Platform.pathSeparator}$index.json');
  }

  bool isChapterCached(Book book, int index) {
    final f = _chapterFile(book, index);
    if (f == null || !f.existsSync()) return false;
    return (_cached[book.sourceTag] ?? const <int>{}).contains(index);
  }

  List<int> cachedChapters(Book book) {
    final set = _cached[book.sourceTag] ?? const <int>{};
    final list = <int>[];
    for (final i in set) {
      if (isChapterCached(book, i)) list.add(i);
    }
    list.sort();
    return list;
  }

  /// 读取某章缓存正文；未缓存返回 null。
  Future<BookContent?> getChapter(Book book, int index, String title) async {
    final f = _chapterFile(book, index);
    if (f == null || !f.existsSync()) return null;
    try {
      final m = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      return BookContent(
        body: (m['body'] as String?) ?? '',
        title: (m['title'] as String?) ?? title,
        sourceUrl: (m['sourceUrl'] as String?) ?? '',
        succeed: ((m['body'] as String?) ?? '').isNotEmpty,
      );
    } catch (_) {
      return null;
    }
  }

  /// 写入单章缓存。
  Future<void> putChapter(Book book, int index, BookContent content) async {
    if (!_ready || _root == null) return;
    if (content.body.trim().isEmpty) return;
    final dir = _bookDir(book);
    if (dir == null) return;
    if (!dir.existsSync()) await dir.create(recursive: true);
    await _chapterFile(book, index)!.writeAsString(jsonEncode({
      'title': content.title,
      'body': content.body,
      'sourceUrl': content.sourceUrl,
    }));
    _cached.putIfAbsent(book.sourceTag, () => <int>{}).add(index);
    await _persist();
  }

  /// 删除整本书缓存。
  Future<void> deleteBookAll(Book book) async {
    final dir = _bookDir(book);
    if (dir != null && dir.existsSync()) {
      await dir.delete(recursive: true);
    }
    _cached.remove(book.sourceTag);
    await _persist();
  }

  /// 删除某章缓存。
  Future<void> deleteChapter(Book book, int index) async {
    final f = _chapterFile(book, index);
    if (f != null && f.existsSync()) await f.delete();
    _cached[book.sourceTag]?.remove(index);
    if ((_cached[book.sourceTag] ?? const <int>{}).isEmpty) {
      _cached.remove(book.sourceTag);
    }
    await _persist();
  }

  /// 下载整本书正文到缓存。
  ///
  /// [chapters] 为目录；[onProgress] 回调 `(done,total)`；跳过已缓存章节。
  Future<void> cacheBook(
    Book book,
    List<BookChapter> chapters, {
    void Function(int done, int total)? onProgress,
  }) async {
    if (!_ready || _root == null) return;
    final total = chapters.length;
    var done = 0;
    for (var i = 0; i < total; i++) {
      if (isChapterCached(book, i)) {
        done++;
        onProgress?.call(done, total);
        continue;
      }
      BookContent content;
      if (fetchOverride != null) {
        content = await fetchOverride!(book, i, chapters[i]);
      } else {
        content = await BookService().getContent(chapters[i], book);
      }
      if (content.body.trim().isNotEmpty) {
        await putChapter(book, i, content);
      }
      done++;
      onProgress?.call(done, total);
    }
  }
}