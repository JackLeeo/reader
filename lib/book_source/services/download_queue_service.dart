import 'package:flutter/foundation.dart';

import '../models/books.dart';
import 'book_cache_service.dart';
import 'book_service.dart';

/// 下载任务状态。
enum DownloadStatus { waiting, downloading, paused, done, error }

/// 章节批量下载队列里的一项（通常是整本书）。
class DownloadTask {
  DownloadTask({required this.book, required this.chapters})
      : status = DownloadStatus.waiting;
  final Book book;
  final List<BookChapter> chapters;
  DownloadStatus status;
  int done = 0;
  int total = 0;

  /// 任务章节在整本目录中的起始序号（用于写盘换算回原 index）。
  int originStart = 0;
  String? error;

  int get totalCount => chapters.length;

  bool get isFinished =>
      status == DownloadStatus.done || status == DownloadStatus.error;
}

/// 全局下载队列（对应官方「下载中心 / DownloadTask」）。
///
/// 多本缓存/下载串行排队执行：逐章下载到 [BookCacheService]，
/// 支持 暂停/恢复/移除/清空。进度经 [ChangeNotifier] 通知 UI。
class DownloadQueueService extends ChangeNotifier {
  DownloadQueueService._();
  static final DownloadQueueService instance = DownloadQueueService._();

  final List<DownloadTask> _all = [];
  bool _active = false;

  List<DownloadTask> get items => List.unmodifiable(_all);

  bool get hasWork => _all.any((t) => !t.isFinished);

  /// 入队一本书（去除已存在同书源同书的任务）。
  DownloadTask enqueue(Book book, List<BookChapter> chapters) {
    final exist = _all.where((t) => t.book.bookUrl == book.bookUrl &&
        t.book.sourceTag == book.sourceTag);
    if (exist.isNotEmpty) return exist.first;
    final task = DownloadTask(book: book, chapters: chapters);
    _all.add(task);
    notifyListeners();
    _pump();
    return task;
  }

  /// 仅缓存未缓存章节（从首个空正文段开始到末尾），返回任务或已缓存完为 null。
  Future<DownloadTask?> enqueueUncached(Book book, List<BookChapter> chapters) async {
    final exist = _all.where((t) => t.book.bookUrl == book.bookUrl &&
        t.book.sourceTag == book.sourceTag);
    if (exist.isNotEmpty) return exist.first;

    // 计算未缓存章节范围（只缓存空正文区间，找到一个非空则其后全列入，保证连续）。
    var start = 0;
    for (var i = 0; i < chapters.length; i++) {
      if (!BookCacheService.instance.isChapterCached(book, i)) {
        start = i;
        break;
      }
      if (i == chapters.length - 1) start = chapters.length; // 全已缓存
    }
    if (start >= chapters.length) return null;
    final pending = <BookChapter>[
      for (var i = start; i < chapters.length; i++) chapters[i],
    ];
    final task = DownloadTask(book: book, chapters: pending);
    // 记录真实原始起点以便写入对应 index。
    task.originStart = start;
    _all.add(task);
    notifyListeners();
    _pump();
    return task;
  }

  void pause(DownloadTask task) {
    if (task.status == DownloadStatus.downloading) {
      task.status = DownloadStatus.paused;
      notifyListeners();
    }
  }

  void resume(DownloadTask task) {
    if (task.status == DownloadStatus.paused ||
        task.status == DownloadStatus.waiting) {
      task.status = DownloadStatus.waiting;
      notifyListeners();
      _pump();
    }
  }

  void remove(DownloadTask task) {
    _all.remove(task);
    notifyListeners();
    _pump();
  }

  void clearFinished() {
    _all.removeWhere((t) => t.isFinished);
    notifyListeners();
  }

  /// 后台串行泵：同一时刻只下载一个任务。
  Future<void> _pump() async {
    if (_active) return;
    _active = true;
    try {
      while (true) {
        final next = _all.where((t) => t.status == DownloadStatus.waiting)
            .toList();
        if (next.isEmpty) break;
        final task = next.first;
        task.status = DownloadStatus.downloading;
        task.done = 0;
        task.total = task.totalCount;
        task.error = null;
        notifyListeners();
        try {
          await _runTask(task);
          if (task.status != DownloadStatus.paused) {
            task.status = DownloadStatus.done;
          }
        } catch (e) {
          task.status = DownloadStatus.error;
          task.error = '$e';
        }
        notifyListeners();
      }
    } finally {
      _active = false;
    }
  }

  Future<void> _runTask(DownloadTask task) async {
    final cache = BookCacheService.instance;
    final svc = BookService();
    final originStart = task.originStart;
    for (var off = 0; off < task.chapters.length; off++) {
      if (task.status == DownloadStatus.paused) return;
      final index = originStart + off;
      final chapter = task.chapters[off];
      if (cache.isChapterCached(task.book, index)) {
        task.done++;
        notifyListeners();
        continue;
      }
      final content = await svc.getContent(chapter, task.book);
      if (content.body.trim().isNotEmpty) {
        await cache.putChapter(task.book, index, content);
      }
      task.done++;
      notifyListeners();
    }
  }
}