import 'package:flutter/foundation.dart';

import '../models/books.dart';
import 'book_service.dart';
import 'shelf_service.dart';

/// 书架章节更新检测（对应官方「书架更新」）。
///
/// 对每本非本地书重新拉取目录，与书架记录的 `lastChapter` 比较；新章节存在时
/// 记录最新章节标题并视为「有更新」。检测结果仅保存在内存（不持久化），
/// 供书架封面叠加「新版」角标。并发限流避免请求风暴。
class ShelfUpdateService {
  ShelfUpdateService._();
  static final ShelfUpdateService instance = ShelfUpdateService._();

  final Set<String> _updated = {};
  final Map<String, String> _latest = {};
  final BookService _bookService = BookService();

  /// 变更信号，供 UI 监听刷新。
  final ValueNotifier<int> version = ValueNotifier<int>(0);

  bool isUpdated(String key) => _updated.contains(key);

  String? latestChapter(String key) => _latest[key];

  void clear(String key) {
    _updated.remove(key);
    _latest.remove(key);
    version.value++;
  }

  bool _hasNew(String? old, String? latest) {
    if (latest == null || latest.isEmpty) return false;
    if (old == null || old.isEmpty) return true;
    if (old == latest) return false;
    // 最新标题包含旧的（或反之）多为主页变化，不视为新章。
    if (latest.contains(old) || old.contains(latest)) return false;
    return true;
  }

  /// 检测单本书是否有新章节；异常/无法解析视为无更新。
  Future<bool> checkBook(ShelfBook b) async {
    if (b.isLocal) {
      _updated.remove(b.key);
      _latest.remove(b.key);
      return false;
    }
    final book = Book(
      name: b.name,
      author: b.author,
      bookUrl: b.bookUrl,
      origin: b.origin,
      sourceTag: b.sourceTag,
      type: 0,
    );
    try {
      final chapters = await _bookService.getToc(book);
      final latest =
          chapters.isEmpty ? null : chapters.last.title.trim();
      final hasNew = _hasNew(b.lastChapter, latest);
      if (hasNew) {
        _updated.add(b.key);
        if (latest != null) _latest[b.key] = latest;
      } else {
        _updated.remove(b.key);
        _latest.remove(b.key);
      }
      version.value++;
      return hasNew;
    } catch (_) {
      return false;
    }
  }

  /// 批量检测：[books] 中逐个检测，最多 [concurrency] 个并发。
  /// 返回「有更新」的书数量。
  Future<int> checkAll(List<ShelfBook> books, {int concurrency = 3}) async {
    if (books.isEmpty) return 0;
    var found = 0;
    var index = 0;
    final n = books.length;
    final workers = concurrency.clamp(1, n);
    Future<void> worker() async {
      while (true) {
        final i = index++;
        if (i >= n) break;
        final ok = await checkBook(books[i]);
        if (ok) found++;
      }
    }

    await Future.wait(List.generate(workers, (_) => worker()));
    return found;
  }
}