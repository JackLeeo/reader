import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/books.dart';
import 'book_service.dart';
import 'http_service.dart';

/// 漫画离线下载服务。
///
/// 把图片源章节的图片批量下载到本地缓存目录，供无网/省流下阅读：
/// - 目录结构：`{root}/comic_offline/{bookKey}/{chapterIndex}/{0000.img...}+meta.json`
/// - [meta.json] 记录章节序号、标题与原始图片 URL 顺序，便于按名还原排序。
/// - 已下载章节集合以 SharedPreferences 持久化，重启不丢。
///
/// 存储根目录 [root] 由宿主注入（单元测试传临时目录，应用用 path_provider）。
class ComicOfflineService {
  ComicOfflineService._();

  static final ComicOfflineService instance = ComicOfflineService._();

  /// 注入目录（真正的根目录为 {root}/comic_offline，方便测试与回收）。
  Directory? _root;
  bool _ready = false;

  /// 章节下载状态：bookKey -> (chapterIndex -> true)
  final Map<String, Map<int, bool>> _state = {};

  static const String _prefsKey = 'comic_offline_v1';

  /// 可注入的字节获取函数（联合测试用；为空则走 [fetchBytes]）。
  Future<List<int>?> Function(String url)? fetchBytesOverride;

  /// 由宿主注入根目录（如应用文档目录）。
  Future<void> setRoot(Directory dir) async {
    _root = Directory('${dir.path}${Platform.pathSeparator}comic_offline');
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
      _state.clear();
      dec.forEach((k, v) {
        final m = <int, bool>{};
        if (v is List) {
          for (final i in v) {
            final n = int.tryParse('$i');
            if (n != null) m[n] = true;
          }
        }
        _state[k] = m;
      });
    } catch (_) {
      _state.clear();
    }
  }

  Future<void> _persist() async {
    final p = await SharedPreferences.getInstance();
    final enc = <String, dynamic>{
      for (final e in _state.entries)
        e.key: e.value.keys.toList().cast<dynamic>(),
    };
    await p.setString(_prefsKey, jsonEncode(enc));
  }

  void reset() {
    _state.clear();
    _ready = false;
  }

  // ------------------------------------------------------------------
  // 查询
  // ------------------------------------------------------------------

  /// 文件系统安全的 bookKey（供目录命名）。
  static String folderOf(Book book) {
    final key = '${book.sourceTag}|${book.bookUrl}';
    var s = key.replaceAll(RegExp(r'[^\w\u4e00-\u9fa5.-]'), '_');
    return s.length > 80 ? s.substring(0, 80) : s;
  }

  Directory? _bookDir(Book book) =>
      _root == null ? null : Directory('${_root!.path}${Platform.pathSeparator}${folderOf(book)}');

  Directory? _chapterDir(Book book, int index) {
    final d = _bookDir(book);
    return d == null ? null : Directory('${d.path}${Platform.pathSeparator}$index');
  }

  /// 某章是否已离线下载。
  bool isChapterDownloaded(Book book, int index) {
    final dir = _chapterDir(book, index);
    if (dir == null || !dir.existsSync()) return false;
    return _state[book.sourceTag]?[index] ?? false;
  }

  /// 已下载章节索引（升序）。
  List<int> downloadedChapters(Book book) {
    final set = _state[book.sourceTag]?.keys ?? const <int>{};
    final list = <int>[];
    for (final i in set) {
      if (isChapterDownloaded(book, i)) list.add(i);
    }
    list.sort();
    return list;
  }

  /// 某章的本地图片文件（按 0000,0001... 排序）；未下载返回空。
  List<File> offlineChapterImages(Book book, int index) {
    final dir = _chapterDir(book, index);
    if (dir == null || !dir.existsSync()) return const [];
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.img'))
        .toList();
    files.sort((a, b) => a.path.compareTo(b.path));
    return files;
  }

  /// 下载整个章节的图片到缓存。
  ///
  /// [chapter] 用于记录标题；[index] 为章节序号；[urls] 可直接提供解析好的
  /// 图片 URL（为空时不联网解析，直接抓取）；[onProgress] 回调 `(done,total)`。
  /// 已下载且 [force] 为 false 时跳过。任一图片失败即中断并作废全章。
  Future<void> downloadChapter(
    Book book,
    BookChapter chapter,
    int index, {
    bool force = false,
    List<String>? urls,
    void Function(int done, int total)? onProgress,
  }) async {
    if (!_ready || _root == null) return;
    if (isChapterDownloaded(book, index) && !force) return;

    final src = urls ?? await BookService().getContentList(chapter, book);
    if (src.isEmpty) return;
    if (!src.every((u) => u.startsWith('http'))) return;

    final dir = _chapterDir(book, index)!;
    if (dir.existsSync()) await dir.delete(recursive: true);
    await dir.create(recursive: true);

    final seq = <String>[];
    final total = src.length;
    var okAll = true;
    for (var i = 0; i < total; i++) {
      final fname = '${i.toString().padLeft(4, '0')}.img';
      final file = File('${dir.path}${Platform.pathSeparator}$fname');
      final bytes = await _fetch(src[i]);
      onProgress?.call(i + 1, total);
      if (bytes == null || bytes.isEmpty) {
        okAll = false;
        break;
      }
      await file.writeAsBytes(bytes, flush: true);
      seq.add(src[i]);
    }

    if (okAll && seq.isNotEmpty) {
      final meta = {'index': index, 'title': chapter.title, 'urls': seq};
      await File('${dir.path}${Platform.pathSeparator}meta.json')
          .writeAsString(jsonEncode(meta));
      _state.putIfAbsent(book.sourceTag, () => {})[index] = true;
      await _persist();
    }
  }

  Future<List<int>?> _fetch(String url) async {
    if (fetchBytesOverride != null) return fetchBytesOverride!(url);
    final resp = await HttpService.instance.get(url);
    if (!resp.ok) return null;
    return resp.bodyBytes;
  }

  /// 删除某章离线数据。
  Future<void> deleteChapter(Book book, int index) async {
    final dir = _chapterDir(book, index);
    if (dir != null && dir.existsSync()) await dir.delete(recursive: true);
    _state[book.sourceTag]?.remove(index);
    if ((_state[book.sourceTag] ?? {}).isEmpty) {
      _state.remove(book.sourceTag);
    }
    await _persist();
  }

  /// 删除整本书离线数据。
  Future<void> deleteBook(Book book) async {
    final dir = _bookDir(book);
    if (dir != null && dir.existsSync()) await dir.delete(recursive: true);
    _state.remove(book.sourceTag);
    await _persist();
  }
}