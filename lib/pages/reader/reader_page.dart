import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../../book_source/help/audio_engine.dart';
import '../../book_source/help/content_processor.dart';
import '../../book_source/help/source_callback.dart';
import '../../book_source/help/tts_speaker.dart';
import '../../book_source/models/book_source.dart';
import '../../book_source/models/books.dart';
import '../../book_source/services/book_service.dart';
import 'highlight_edit_dialog.dart';
import '../../book_source/services/book_cache_service.dart';
import '../../book_source/services/book_source_service.dart';
import '../../book_source/services/chapter_source_service.dart';
import '../../book_source/services/dict_service.dart';
import '../../book_source/services/highlight_service.dart';
import '../../book_source/services/bookmark_service.dart';
import '../../book_source/services/note_service.dart';
import '../../book_source/services/comic_offline_service.dart';
import '../../book_source/services/content_search_service.dart';
import '../../book_source/services/web_js_service.dart';
import '../../book_source/services/download_queue_service.dart';
import '../../book_source/services/read_stat_service.dart';
import '../../book_source/services/shelf_service.dart';
import '../../book_source/services/switch_source_service.dart';
import '../../book_source/services/tts_service.dart';
import '../../book_source/utils/book_exporter.dart';
import '../../core/reading_pref.dart';
import '../../local/local_book.dart';
import '../book/book_detail_page.dart';
import '../tools/download_center_page.dart';
import 'audio_reader_view.dart';
import 'comic_reader_view.dart';
import 'video_reader_view.dart';
import 'paged_text_view.dart';
import 'webview_source_page.dart';

/// 阅读器页。
///
/// 阶段3对齐官方：字号/行距/页边距/背景主题/翻页模式 均可调，
/// 支持换源阅读与目录抽屉。进度随翻页写入书架。
/// 传入 [localBook] 时进入本地书模式：正文直接从内存章节取，不联网。
class ReaderPage extends StatefulWidget {
  const ReaderPage({
    super.key,
    required this.book,
    required this.chapters,
    this.initialIndex = 0,
    this.initialPage = 0,
    this.localBook,
  });

  final Book book;
  final List<BookChapter> chapters;
  final int initialIndex;
  final int initialPage;
  final LocalBook? localBook;

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> {
  static final BookService _service = BookService();
  late final ReadingPref _pref = ReadingPref.instance;

  late int _index;
  BookContent? _content;
  List<String> _mediaUrls = const [];
  bool _offline = false;
  bool _downloadingChapter = false;
  bool _cachingBook = false;
  bool _loading = true;
  String? _error;
  bool _showChrome = false;
  late List<BookChapter> _chapters = List.of(widget.chapters);

  // ---- 自动翻页 ----
  final ScrollController _scrollCtrl = ScrollController();
  Timer? _autoTimer;
  bool _autoPlaying = false;

  // ---- 分页正文 ----
  final GlobalKey<PagedTextViewState> _pagedKey = GlobalKey();
  int _pageIndex = 0;

  // ---- 底部进度条 ----
  double _tocProgress = 0.0; // 章节级当前进度（0..1）
  double? _tocDrag;

  // ---- 朗读(TTS) ----
  TtsSpeaker? _speaker;
  bool _ttsPlaying = false;
  StreamSubscription<void>? _ttsCompleteSub;
  Timer? _aloudTimer;
  int _aloudRemainSec = 0;
  bool _ttsContinueFlag = false;

  // ---- 阅读时长统计 ----
  Timer? _statTimer;
  int _statTick = 0;

  String get _bookKey => '${widget.book.sourceTag}|${widget.book.bookUrl}';

  /// 当前书籍对应的书源（本地书无书源）。
  BookSource? get _bookSource {
    if (widget.localBook != null) return null;
    for (final s in BookSourceService.instance.sources) {
      if (s.bookSourceUrl == widget.book.sourceTag) return s;
    }
    return null;
  }

  /// 当前章节对象（事件回调上下文用）。
  BookChapter? get _currentChapter =>
      (_index >= 0 && _index < _chapters.length) ? _chapters[_index] : null;

  /// 分发书源事件（官方 `SourceCallBack`）。
  void _dispatchSourceEvent(String event, {String? result}) {
    SourceCallback.event(
      source: _bookSource,
      event: event,
      book: widget.book,
      chapter: _currentChapter,
      result: result,
    );
  }

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, _chapters.length - 1);
    _pageIndex = widget.initialPage;
    _initTts();
    DictService.instance.init();
    HighlightService.instance.init();
    _loadChapter(_index);
    _dispatchSourceEvent('startRead');
    // 媒体键控制朗读（硬件播放/暂停/停止/上下章）。
    HardwareKeyboard.instance.addHandler(_handleMediaKey);
    // 前台阅读期间每 30 秒落盘一次（本地缓存 1 秒计数）。
    _statTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _statTick++;
      if (_statTick >= 30) {
        _statTick = 0;
        ReadStatService.instance.addSeconds(
          _bookKey,
          title: widget.book.name,
          seconds: 30,
        );
      }
    });
  }

  @override
  void dispose() {
    _autoTimer?.cancel();
    _statTimer?.cancel();
    _aloudTimer?.cancel();
    _ttsCompleteSub?.cancel();
    // 退出前把不足 30 秒的余量结算。
    if (_statTick > 0) {
      ReadStatService.instance.addSeconds(
        _bookKey,
        title: widget.book.name,
        seconds: _statTick,
      );
    }
    _speaker?.stop();
    _speaker?.dispose();
    HardwareKeyboard.instance.removeHandler(_handleMediaKey);
    _scrollCtrl.dispose();
    _dispatchSourceEvent('endRead');
    super.dispose();
  }

  /// 媒体键处理：播放/暂停、停止、上下章。
  /// 返回值 true 表示已消费该键（阻止继续向上传递）。
  bool _handleMediaKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    final p = event.physicalKey;
    if (p == PhysicalKeyboardKey.mediaPlayPause) {
      _toggleTts();
      return true;
    } else if (p == PhysicalKeyboardKey.mediaStop) {
      _stopTts();
      return true;
    } else if (p == PhysicalKeyboardKey.mediaTrackNext) {
      if (_ttsPlaying) _skipChapter(delta: 1, readAloud: true);
      return true;
    } else if (p == PhysicalKeyboardKey.mediaTrackPrevious) {
      if (_ttsPlaying) _skipChapter(delta: -1, readAloud: true);
      return true;
    }
    return false;
  }

  /// 朗读时切换章节：跳到 [delta] 章并（若朗读中）继续朗读该章。
  /// [readAloud] 仅在朗读中生效；否则仅跳章。
  void _skipChapter({required int delta, bool readAloud = false}) {
    var target = _index + delta;
    // 找下一个非卷标记章节。
    while (target >= 0 &&
        target < _chapters.length &&
        _chapters[target].isVolume) {
      target += delta;
    }
    if (target < 0 || target >= _chapters.length) return;
    final nextIndex = target;
    if (readAloud && _ttsPlaying && _speaker != null) {
      _speaker!.stop();
      _ttsContinueFlag = true;
    }
    _loadChapter(nextIndex);
    // 朗读模式下由“本章读完后自动进下一章”机制续读。
  }

  Future<void> _initTts() async {
    // 优先使用已启用的 HTTP 网络 TTS 引擎；否则回退系统 TTS。
    await TtsEngineService.instance.init();
    final engine = TtsEngineService.instance.enabledEngine;
    if (engine != null) {
      _speaker = HttpTtsSpeaker(engine);
    } else {
      _speaker = await SystemTtsSpeaker.create();
    }
    // 应用朗读配置（语速/音量）。
    await _speaker?.setParams(
      speechRate: _pref.ttsSpeechRate,
      volume: _pref.ttsVolume,
    );
    // 连续朗读：本章读完自动进下一章继续读。
    _ttsCompleteSub?.cancel();
    _ttsCompleteSub = _speaker?.onComplete.listen((_) {
      if (!mounted || !_ttsPlaying) return;
      _readNextChapterForTts();
    });
  }

  /// 连续朗读：读完当前章后进入下一章并继续朗读。
  void _readNextChapterForTts() {
    var next = -1;
    for (var j = _index + 1; j < _chapters.length; j++) {
      if (!_chapters[j].isVolume) {
        next = j;
        break;
      }
    }
    if (next < 0) {
      // 全书读完
      _stopTts();
      if (mounted) _toast('全书朗读完毕');
      return;
    }
    _ttsContinueFlag = true;
    _loadChapter(next);
  }

  void _stopTts() {
    _speaker?.stop();
    _aloudTimer?.cancel();
    _aloudTimer = null;
    _aloudRemainSec = 0;
    _ttsContinueFlag = false;
    if (mounted) setState(() => _ttsPlaying = false);
  }

  /// 开启朗读定时停止（分钟）。
  void _startAloudTimer(int minutes) {
    _aloudTimer?.cancel();
    if (minutes <= 0) {
      _aloudRemainSec = 0;
      return;
    }
    _aloudRemainSec = minutes * 60;
    _aloudTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || !_ttsPlaying) return;
      _aloudRemainSec--;
      if (_aloudRemainSec <= 0) {
        _aloudTimer?.cancel();
        _aloudTimer = null;
        _aloudRemainSec = 0;
        _stopTts();
        if (mounted) _toast('定时朗读已到点停止');
      } else if (mounted) {
        setState(() {});
      }
    });
  }

  /// 单章临时换源：chapterIndex -> 已选章节源（null 表示用原源）。
  final Map<int, BookSource> _chapterSources = {};

  Future<void> _loadChapter(int index) async {
    if (index < 0 || index >= _chapters.length) return;
    _saveProgressSilent();
    setState(() {
      _index = index;
      _loading = true;
      _error = null;
      _content = null;
      _mediaUrls = const [];
    });
    try {
      if (widget.localBook != null) {
        // 本地书模式：正文来自内存章节，不联网。
        final lb = widget.localBook!;
        final processor = ContentProcessor(
          sourceName: 'local',
          replaceRules:
              ContentProcessor.hooksFrom(sourceUrl: 'local', forTitle: false),
          convertType: _pref.convertType,
        );
        _content = BookContent(
          body: processor.clean(
            index < lb.chapters.length ? lb.chapters[index].content : '',
            title: lb.chapters[index].title,
          ),
          title: lb.chapters[index].title,
          succeed: true,
        );
        if (!mounted) return;
        setState(() {
          _loading = false;
          _error = null;
          _pageIndex = index == widget.initialIndex ? widget.initialPage : 0;
        });
      } else if (widget.book.isMediaSource) {
        // 图片/漫画/听书：按章节提取素材 URL 列表。
        _offline = false;
        if (widget.book.isImageSource) {
          final off = ComicOfflineService.instance;
          if (off.ready && off.isChapterDownloaded(widget.book, index)) {
            final files = off.offlineChapterImages(widget.book, index);
            if (files.isNotEmpty) {
              _offline = true;
              if (!mounted) return;
              setState(() {
                _mediaUrls = [for (final f in files) f.path];
                _loading = false;
              });
              _afterLoad();
              _saveProgressSilent();
              return;
            }
          }
        }
        final urls = await _service.getContentList(_chapters[index], widget.book);
        if (!mounted) return;
        setState(() {
          // 音频源：构造带请求头/Cookie 的可播放地址；图片源保留原样。
          _mediaUrls = widget.book.isAudioSource
              ? [for (final u in urls) AudioEngine.buildBookPlayableUrl(u, widget.book)]
              : urls;
          _loading = false;
          if (urls.isEmpty) _error = '本章未解析出素材';
        });
      } else {
        BookContent content;
        final cache = BookCacheService.instance;
        // 优先缓存：已缓存章节读本地，避免重复联网。
        final cached = cache.ready
            ? await cache.getChapter(widget.book, index, _chapters[index].title)
            : null;
        if (cached != null && cached.body.trim().isNotEmpty) {
          content = cached;
        } else {
          final overrideSource = _chapterSources[index];
          content = await _service.getContent(_chapters[index], widget.book,
              source: overrideSource);
          // 成功则写入缓存（临时换源不落库，避免污染原源缓存）。
          if (cache.ready &&
              content.body.trim().isNotEmpty &&
              overrideSource == null) {
            unawaited(cache.putChapter(widget.book, index, content));
          }
        }
        if (!mounted) return;
        // 正文净化（对标官方 ContentProcessor）：去重复标题 / 归一分段 / 替换规则 / 简繁。
        final processor = ContentProcessor(
          sourceName: widget.book.sourceTag,
          replaceRules: ContentProcessor.hooksFrom(
              sourceUrl: widget.book.sourceTag, forTitle: false),
          convertType: _pref.convertType,
        );
        content.body =
            processor.clean(content.body, title: _chapters[index].title);
        if (content.body.trim().isEmpty && cache.ready) {
          // 网络/规则失败空文时，回退已缓存内容（走净化前的原始缓存）。
          final fb = await cache.getChapter(widget.book, index, _chapters[index].title);
          if (fb != null && fb.body.trim().isNotEmpty) {
            fb.body = processor.clean(fb.body, title: _chapters[index].title);
            content = fb;
          }
        }
        // 原源加载失败且书未锁定来源时，自动用其它启用源读取本章（源锁定联动）。
        if (content.body.trim().isEmpty && !_isSourceLocked) {
          final fallback = await _tryChapterFallback(index);
          if (fallback != null) {
            content = fallback;
            final altName = _chapterSources[index]?.bookSourceName ?? '';
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text('当前源加载失败，已自动切换到《$altName》读本章'),
                duration: const Duration(seconds: 3),
              ));
            }
          }
        }
        setState(() {
          _content = content;
          _loading = false;
          _pageIndex = index == widget.initialIndex ? widget.initialPage : 0;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '章节加载失败：$e';
      });
    }
    _saveProgressSilent();
    _afterLoad();
  }

  /// 是否锁定来源：源锁定（ShelfBook.locked）的书籍不参与失败自动换源。
  bool get _isSourceLocked {
    if (widget.localBook != null) return true;
    final key = '${widget.book.sourceTag}|${widget.book.bookUrl}';
    return ShelfService.instance.findByKey(key)?.locked ?? false;
  }

  /// 原源读取失败时，用其它启用源读取本章；无候选或仍失败返回 null。
  Future<BookContent?> _tryChapterFallback(int index) async {
    final chapter = _chapters[index];
    final svc = ChapterSourceService();
    final cands = await svc.findCandidates(
      widget.book,
      chapter.title,
      excludeOrigin: widget.book.origin,
    );
    if (cands.isEmpty) return null;
    final best = cands.first;
    final content = await svc.loadContent(widget.book, best);
    if (content.succeed && content.body.trim().isNotEmpty) {
      _chapterSources[index] = best.source;
      return content;
    }
    return null;
  }

  void _saveProgressSilent() {
    final book = widget.book;
    final key = '${book.sourceTag}|${book.bookUrl}';
    if (ShelfService.instance.findByKey(key) == null) return;
    ShelfService.instance.updateProgress(
      key,
      lastReadIndex: _index,
      lastReadChapter: _index < _chapters.length
          ? _chapters[_index].title
          : '',
      lastReadPage: _pageIndex,
      readingProgress:
          _chapters.isEmpty ? 0 : (_index + 1) / _chapters.length,
    );
    ShelfService.instance.save();
  }

  void _next() {
    _applyTtsPageTurnPolicy();
    for (var j = _index + 1; j < _chapters.length; j++) {
      if (!_chapters[j].isVolume) {
        _loadChapter(j);
        return;
      }
    }
  }

  void _prev() {
    _applyTtsPageTurnPolicy();
    for (var j = _index - 1; j >= 0; j--) {
      if (!_chapters[j].isVolume) {
        _loadChapter(j);
        return;
      }
    }
  }

  /// 朗读期间手动翻章时的策略：0 停止朗读, 1 忽略(继续读)。
  void _applyTtsPageTurnPolicy() {
    if (!_ttsPlaying) return;
    if (_pref.aloudOnPageTurn == 0) {
      // 停止朗读，并取消连续朗读续章。
      _aloudTimer?.cancel();
      _aloudTimer = null;
      _ttsContinueFlag = false;
      _speaker?.stop();
      setState(() => _ttsPlaying = false);
    }
    // policy 1：不打断，继续朗读。
  }

  // ---- 自动翻页 ----
  void _toggleAutoPlay() {
    if (_autoPlaying) {
      _autoTimer?.cancel();
      setState(() => _autoPlaying = false);
      return;
    }
    setState(() {
      _autoPlaying = true;
      _autoTimer?.cancel();
      _autoTimer = Timer.periodic(
        Duration(milliseconds: (_pref.autoReadInterval * 1000).round()),
        (_) => _autoTick(),
      );
    });
  }

  /// 按当前设置重启自动翻页定时器（改间隔后调用）。
  void _restartAutoPlay() {
    if (!_autoPlaying) return;
    _autoTimer?.cancel();
    _autoTimer = Timer.periodic(
      Duration(milliseconds: (_pref.autoReadInterval * 1000).round()),
      (_) => _autoTick(),
    );
  }

  void _autoTick() {
    // 分页模式：跳到下一页，到底则翻章。
    if (_pref.pageMode != 2) {
      final goNext = _pagedKey.currentState?.goNextPage();
      if (goNext != null && !goNext) {
        _next();
      }
      return;
    }
    // 滚动模式：定时下滚，到底翻章。
    if (!_scrollCtrl.hasClients) return;
    if (_scrollCtrl.position.maxScrollExtent <= 0) {
      _next();
      return;
    }
    final target = _scrollCtrl.position.pixels +
        _scrollCtrl.position.viewportDimension * 0.9;
    if (target >= _scrollCtrl.position.maxScrollExtent) {
      _next();
    } else {
      _scrollCtrl.animateTo(
        target,
        duration: const Duration(milliseconds: 450),
        curve: Curves.easeOut,
      );
    }
  }

  /// 分页模式页码变化：记录页级进度并持久化。
  void _onPageChanged(int page, int total) {
    _pageIndex = page;
    final book = widget.book;
    final key = '${book.sourceTag}|${book.bookUrl}';
    if (ShelfService.instance.findByKey(key) == null) return;
    ShelfService.instance.updateProgress(
      key,
      lastReadIndex: _index,
      lastReadChapter: _index < _chapters.length
          ? _chapters[_index].title
          : '',
      lastReadPage: page,
      readingProgress: _chapters.isEmpty
          ? 0
          : (_index + (page + 1) / (total == 0 ? 1 : total)) /
              _chapters.length,
    );
    ShelfService.instance.save();
    // 进度落盘 → 向书源分发 saveRead 事件（getEvent 由 canReceive 内部守卫）。
    _dispatchSourceEvent('saveRead');
  }

  void _afterLoad() {
    // 切章或起始加载后，滚动回到顶部。
    if (_scrollCtrl.hasClients) {
      _scrollCtrl.jumpTo(0);
    }
    // 同步底部进度条当前章节进度。
    _tocProgress =
        _chapters.length <= 1 ? 0.0 : (_index / (_chapters.length - 1));
    // 连续朗读：切章完成后读新章正文。
    if (_ttsContinueFlag && _ttsPlaying && _content != null && !_loading) {
      _ttsContinueFlag = false;
      final body = _content!.body.isEmpty ? '' : _content!.body;
      if (body.isNotEmpty) {
        _speaker?.speak(body);
      }
    }
  }

  /// 底部进度条拖动后定位到对应章节（跳过卷标记）。
  void _jumpToProgress(double v) {
    if (_chapters.isEmpty) return;
    var idx = (v * _chapters.length).floor().clamp(0, _chapters.length - 1);
    while (idx >= 0 && idx < _chapters.length && _chapters[idx].isVolume) {
      idx++;
    }
    if (idx < 0 || idx >= _chapters.length) return;
    _loadChapter(idx);
  }

  // ---- 朗读(TTS) ----
  Future<void> _toggleTts() async {
    if (_speaker == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('本设备暂不支持朗读（未配置可用 TTS 引擎）')),
      );
      return;
    }
    final text = (_loading || _content == null)
        ? ''
        : (_content!.body.isEmpty ? '' : _content!.body);
    if (_ttsPlaying) {
      _aloudTimer?.cancel();
      _aloudTimer = null;
      _aloudRemainSec = 0;
      await _speaker!.stop();
      setState(() => _ttsPlaying = false);
      return;
    }
    if (text.isEmpty) return;
    _ttsContinueFlag = false;
    await _speaker!.speak(text);
    setState(() => _ttsPlaying = true);
    // 定时停止
    if (_pref.aloudTimeout > 0) _startAloudTimer(_pref.aloudTimeout);
  }

  // ---- 文本下载：加入下载中心队列 ----
  Future<void> _cacheWholeBook() async {
    final cache = BookCacheService.instance;
    if (!cache.ready) {
      _toast('缓存存储尚未就绪');
      return;
    }
    if (_cachingBook) {
      _openDownloadCenter();
      return;
    }
    setState(() => _cachingBook = true);
    final task = await DownloadQueueService.instance
        .enqueueUncached(widget.book, _chapters);
    if (!mounted) return;
    if (task == null) {
      _toast('本章节已全部缓存');
    } else {
      _toast('已加入下载队列：${widget.book.name}');
      _openDownloadCenter();
    }
    if (mounted) setState(() => _cachingBook = false);
  }

  void _openDownloadCenter() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const DownloadCenterPage()),
    );
  }

// ---- 漫画离线下载 ----
  bool _isChapterOffline() {
    if (!widget.book.isImageSource) return false;
    final off = ComicOfflineService.instance;
    return off.ready && off.isChapterDownloaded(widget.book, _index);
  }

  Future<void> _downloadChapterOffline() async {
    if (_downloadingChapter) return;
    final off = ComicOfflineService.instance;
    if (!off.ready) {
      _toast('离线存储尚未就绪');
      return;
    }
    setState(() => _downloadingChapter = true);
    try {
      await off.downloadChapter(
        widget.book,
        _chapters[_index],
        _index,
        force: _isChapterOffline(),
      );
      if (!mounted) return;
      if (_isChapterOffline()) {
        _toast('本章已离线下载');
        _reloadCurrentChapter();
      } else {
        _toast('本章下载失败（未解析到图片或抓取中断）');
      }
    } finally {
      if (mounted) setState(() => _downloadingChapter = false);
    }
  }

  Future<void> _deleteChapterOffline() async {
    final off = ComicOfflineService.instance;
    await off.deleteChapter(widget.book, _index);
    if (_offline) _offline = false;
    setState(() {});
    _toast('已删除本章离线缓存');
  }

// ---- 书签 ----
  void _toggleBookmark() {
    final key = _currentBookKey();
    final marked = BookmarkService.instance.contains(key, _index);
    if (marked) {
      BookmarkService.instance.remove(key, _index);
      _toast('已移除书签');
    } else {
      BookmarkService.instance.add(Bookmark(
        bookKey: key,
        chapterIndex: _index,
        chapterTitle: _chapters[_index].title,
        addTime: DateTime.now().millisecondsSinceEpoch,
      ));
      _toast('已添加书签');
    }
    setState(() {});
  }

  String _currentBookKey() =>
      widget.localBook != null ? 'local|${widget.localBook!.key}' : '${widget.book.sourceTag}|${widget.book.bookUrl}';

  void _showBookmarks() {
    final key = _currentBookKey();
    final bms = BookmarkService.instance.forBook(key);
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text('书签（${bms.length}）',
                  style: Theme.of(ctx).textTheme.titleMedium),
            ),
            if (bms.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text('暂无书签，阅读时点顶部书签图标即可添加'),
              ),
            for (final bm in bms)
              ListTile(
                dense: true,
                leading: const Icon(Icons.bookmark_outline),
                title: Text(bm.chapterTitle,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text('第 ${bm.chapterIndex + 1} 章'),
                onTap: () {
                  Navigator.pop(ctx);
                  _loadChapter(bm.chapterIndex);
                },
              ),
          ],
        ),
      ),
    );
  }

  /// 编辑/查看本章笔记（官方“本章笔记”）。无则新建，有则覆盖。
  Future<void> _editCurrentNote() async {
    final key = _currentBookKey();
    final title = _chapters[_index].title;
    final existing = NoteService.instance.forChapter(key, _index);
    final controller =
        TextEditingController(text: existing?.text ?? '');
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(existing == null ? '本章笔记' : '编辑本章笔记'),
        content: TextField(
          controller: controller,
          autofocus: true,
          minLines: 4,
          maxLines: 8,
          decoration: const InputDecoration(hintText: '写下本章的笔记…'),
        ),
        actions: [
          if (existing != null)
            TextButton(
              onPressed: () {
                NoteService.instance.removeNote(key, _index);
                Navigator.pop(ctx, true);
              },
              child: Text('删除',
                  style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
            ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    final text = controller.text.trim();
    controller.dispose();
    if (saved == true && mounted) {
      if (text.isNotEmpty) {
        await NoteService.instance.saveNote(ReadingNote(
          bookKey: key,
          bookName: widget.book.name,
          chapterIndex: _index,
          chapterTitle: title,
          text: text,
          time: DateTime.now().millisecondsSinceEpoch,
        ));
        _toast('笔记已保存');
      } else {
        await NoteService.instance.removeNote(key, _index);
        _toast('已删除本章笔记');
      }
    }
  }

  /// 本书全部笔记列表（点选跳章、删除）。
  void _showNotes() {
    final key = _currentBookKey();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final list = NoteService.instance.forBook(key);
          return DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.7,
            maxChildSize: 0.9,
            builder: (_, controller) => Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text('本书笔记（${list.length}）',
                      style: Theme.of(ctx).textTheme.titleMedium),
                ),
                if (list.isEmpty)
                  const Expanded(
                    child: Center(child: Text('暂无笔记，顶部菜单可添加本章笔记')),
                  )
                else
                  Expanded(
                    child: ListView.builder(
                      controller: controller,
                      itemCount: list.length,
                      itemBuilder: (_, i) {
                        final n = list[i];
                        return Dismissible(
                          key: ValueKey('${n.bookKey}_${n.chapterIndex}'),
                          direction: DismissDirection.endToStart,
                          onDismissed: (_) {
                            NoteService.instance.removeNote(n.bookKey, n.chapterIndex);
                            setSheet(() {});
                          },
                          background: Container(
                            color: Theme.of(ctx).colorScheme.error,
                            alignment: Alignment.centerRight,
                            padding: const EdgeInsets.only(right: 16),
                            child: const Icon(Icons.delete_outline,
                                color: Colors.white),
                          ),
                          child: ListTile(
                            dense: true,
                            title: Text(n.chapterTitle,
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Text(n.text,
                                maxLines: 3, overflow: TextOverflow.ellipsis),
                            leading: const Icon(Icons.sticky_note_2_outlined),
                            onTap: () {
                              Navigator.pop(ctx);
                              _loadChapter(n.chapterIndex);
                            },
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// 导出当前章节为 txt。
  Future<void> _exportCurrentChapter() async {
    final title = _chapters[_index].title;
    final body = _content?.body ?? '';
    if (body.trim().isEmpty) {
      _toast('本章正文为空，无法导出');
      return;
    }
    final path = await BookExporter.exportText(
      fileName: '${widget.book.name}-$title',
      chapters: [(title, body)],
    );
    if (mounted) {
      _toast(path == null ? '导出失败' : '已导出到 $path');
    }
  }

  /// 导出已缓存章节为整本 txt。
  Future<void> _exportCachedBook() async {
    final book = widget.book;
    final cache = BookCacheService.instance;
    final entries = <(String, String)>[];
    if (widget.localBook != null) {
      final lb = widget.localBook!;
      for (var i = 0; i < lb.chapters.length; i++) {
        entries.add((lb.chapters[i].title, lb.chapters[i].content));
      }
    } else if (cache.ready) {
      final ids = cache.cachedChapters(book);
      for (final i in ids) {
        final c = await cache.getChapter(book, i, '第 ${i + 1} 章');
        if (c == null || c.body.trim().isEmpty) continue;
        entries.add((c.title.isEmpty ? '第 ${i + 1} 章' : c.title, c.body));
      }
    }
    if (entries.isEmpty) {
      _toast('尚未缓存任何章节，无法导出全书');
      return;
    }
    final path = await BookExporter.exportText(
      fileName: '${book.name}-全文',
      chapters: entries,
    );
    if (mounted) {
      _toast(path == null ? '导出失败' : '已导出 $path（${entries.length} 章）');
    }
  }

  /// 分享当前章节标题与地址（系统分享面板，跨端可用）。
  Future<void> _shareCurrentChapter() async {
    final url = _currentChapter?.url ?? '';
    final head = '《${widget.book.name}》 ${_chapters[_index].title}';
    final text = url.trim().isNotEmpty ? '$head\n$url' : head;
    try {
      await SharePlus.instance.share(ShareParams(
        text: text,
        subject: widget.book.name,
      ));
    } catch (_) {
      _toast('暂无法分享');
    }
  }

  /// 用网页(WebView)打开当前章节（正文需 JS 渲染的书源）。
  Future<void> _openWebViewSource() async {
    if (widget.localBook != null) {
      _toast('本地书未配置网页地址');
      return;
    }
    final url = _currentChapter?.url ?? '';
    if (url.trim().isEmpty) {
      _toast('当前章节无网页地址');
      return;
    }
    String? selector;
    try {
      selector = _bookSource?.ruleContent?.content?.trim();
    } catch (_) {
      selector = null;
    }
    // `js:` 书源：预下载书源源码，供 WebView 页内调用其 content 函数（书源级往返）。
    String? jsCode;
    final src = _bookSource;
    if (src != null && WebJsService.instance.isJsSource(src)) {
      jsCode = await WebJsService.instance.getCode(src);
    }
    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => WebViewSourcePage(
          url: url,
          title: _chapters[_index].title,
          contentSelector: selector,
          jsCode: jsCode,
        ),
      ),
    );
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      duration: const Duration(milliseconds: 900),
    ));
  }

  /// 重新加载当前章节（简繁/替换规则变化后刷新正文）。
  void _reloadCurrentChapter() => _loadChapter(_index);

  /// 拉取最新目录（官方“更新目录”），成功后刷新章列表并保留当前章。
  Future<void> _refreshToc() async {
    if (widget.localBook != null) {
      _toast('本地书无需更新目录');
      return;
    }
    final current = _index;
    try {
      final chapters = await _service.getToc(widget.book);
      if (!mounted) return;
      if (chapters.isEmpty) {
        _toast('更新目录失败（未解析到章节）');
        return;
      }
      setState(() {
        _chapters = chapters;
        _index = current.clamp(0, chapters.length - 1);
      });
      _toast('目录已更新（${chapters.length} 章）');
    } catch (_) {
      if (!mounted) return;
      _toast('更新目录失败');
    }
  }

  /// 书中搜索：按章流式抓取正文，列出命中章节；点击跳转到该章。
  /// 为避免一次拉取全书造成的漫长等待，逐个章节获取；命中足够多或到达上限即停。
  Future<void> _showInBookSearch() async {
    final controller = TextEditingController();
    final kw = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('书中搜索'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(hintText: '输入全书要搜索的文字'),
          onSubmitted: (_) => Navigator.pop(ctx, controller.text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('搜索'),
          ),
        ],
      ),
    );
    controller.dispose();
    final keyword = kw?.trim();
    if (keyword == null || keyword.isEmpty || !mounted) return;

    final hits = <ContentHit>[];
    // 逐章拉取，最多抓 maxScan 章；每抓到一章立即搜索并入列，命中即有反馈。
    const maxScan = 60;
    final scan = _chapters.length < maxScan ? _chapters.length : maxScan;
    for (var i = 0; i < scan; i++) {
      final title = _chapters[i].title;
      String body;
      if (widget.localBook != null) {
        body = i < widget.localBook!.chapters.length
            ? widget.localBook!.chapters[i].content
            : '';
      } else {
        final cache = BookCacheService.instance;
        var content = cache.ready
            ? await cache.getChapter(widget.book, i, title)
            : null;
        if (content == null || content.body.trim().isEmpty) {
          try {
            content = await _service.getContent(_chapters[i], widget.book);
          } catch (_) {}
        }
        body = content?.body ?? '';
      }
      if (!mounted) return;
      if (body.trim().isEmpty) continue;
      hits.addAll(ContentSearchService.instance.search(
        chapters: [
          (title: title, content: body),
        ],
        keyword: keyword,
      ));
      if (hits.length >= 200) break; // 命中足够，停止继续扫描。
    }
    if (!mounted) return;
    if (hits.isEmpty) {
      _toast('全书前 $scan 章未找到「$keyword」');
      return;
    }
    // 去重：同一「章节+位置」只留一次，按章聚合展示。
    hits.sort((a, b) {
      if (a.chapterIndex != b.chapterIndex) return a.chapterIndex.compareTo(b.chapterIndex);
      return a.position.compareTo(b.position);
    });
    final byChapter = <int, List<ContentHit>>{};
    for (final h in hits) {
      byChapter.putIfAbsent(h.chapterIndex, () => []).add(h);
    }
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.72,
          builder: (_, controller) => Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text('「$keyword」命中 ${hits.length} 处 · ${byChapter.length} 章',
                    style: Theme.of(ctx).textTheme.titleMedium),
              ),
              Expanded(
                child: ListView(
                  controller: controller,
                  children: [
                    for (final e in byChapter.entries) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                        child: Text(
                          _chapters[e.key].title,
                          style: Theme.of(ctx).textTheme.titleSmall?.copyWith(
                                color: Theme.of(ctx).colorScheme.primary,
                              ),
                        ),
                      ),
                      for (final h in e.value)
                        ListTile(
                          dense: true,
                          title: Text(
                            h.snippet.replaceAll('\n', ' '),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () {
                            Navigator.pop(ctx);
                            _loadChapter(h.chapterIndex);
                            _toast('已跳转到第 ${h.chapterIndex + 1} 章');
                          },
                        ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showChapterSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 1,
        builder: (_, controller) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child:
                  Text('目录', style: Theme.of(context).textTheme.titleMedium),
            ),
            Expanded(
              child: ListView.builder(
                controller: controller,
                itemCount: _chapters.length,
                itemBuilder: (_, i) {
                  final entry = _tocEntryAt(i);
                  // 卷/分卷标记：渲染为分组标题。
                  if (entry.isVolume) {
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: Text(
                        entry.chapter.title,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              color: Theme.of(context).colorScheme.primary,
                            ),
                      ),
                    );
                  }
                  final selected = entry.index == _index;
                  return ListTile(
                    dense: true,
                    selected: selected,
                    title: Text(entry.chapter.title,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    onTap: () {
                      Navigator.pop(context);
                      _loadChapter(entry.index);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 目录扁平条目：把「卷标记」与「普通章节」区分开，用于分组显示。
  _TocEntry _tocEntryAt(int i) {
    final c = _chapters[i];
    return _TocEntry(chapter: c, index: i, isVolume: c.isVolume);
  }

  // 换源：搜索同名书籍，找到则跳到其详情。
  Future<void> _switchSource() async {
    final book = widget.book;
    final candidates = await SwitchSourceService().findSameBook(
      book,
      excludeOrigin: book.origin,
    );
    if (!mounted) return;
    if (candidates.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('未找到其它书源的同名书籍')),
      );
      return;
    }
    final picked = await showModalBottomSheet<SearchBook>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          children: [
            ListTile(
              title: Text('换源（${candidates.length} 个候选）',
                  style: Theme.of(ctx).textTheme.titleMedium),
            ),
            for (final c in candidates)
              ListTile(
                leading: const Icon(Icons.menu_book_outlined),
                title: Text(c.name,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text('来源：${c.origin}',
                    style: Theme.of(ctx).textTheme.bodySmall),
                onTap: () => Navigator.pop(ctx, c),
              ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    // 跳到新源详情页（其内目录/正文用新源规则解析）。
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => BookDetailPage(flow: picked)),
    );
  }

  /// 随机换源：随机抽取一个启用源碰运气匹配，命中则跳转。
  Future<void> _randomSource() async {
    final book = widget.book;
    final snack = ScaffoldMessenger.of(context);
    snack.showSnackBar(const SnackBar(content: Text('随机换源中…')));
    final picked = await SwitchSourceService().randomSource(
      book,
      excludeOrigin: book.origin,
    );
    if (!mounted) return;
    snack.hideCurrentSnackBar();
    if (picked == null) {
      snack.showSnackBar(const SnackBar(content: Text('未找到其它书源的同名书籍')));
      return;
    }
    snack.showSnackBar(SnackBar(
      content: Text('已跳转来源：${picked.origin}'),
      duration: const Duration(seconds: 1),
    ));
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => BookDetailPage(flow: picked)),
    );
  }

  /// 本章换源：在其它启用源中匹配当前章节并切换到该源加载正文。
  Future<void> _switchChapterSource() async {
    final book = widget.book;
    final index = _index;
    final chapter = _currentChapter;
    if (chapter == null) return;

    final candidates = await const ChapterSourceService().findCandidates(
      book,
      chapter.title,
      excludeOrigin: book.origin,
    );
    if (!mounted) return;

    // 存在当前章节已临时换源时，给出「恢复原源」入口。
    final hasOverride = _chapterSources.containsKey(index);
    final picked = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          children: [
            ListTile(
              title: Text('本章换源（${candidates.length} 个候选）',
                  style: Theme.of(ctx).textTheme.titleMedium),
              subtitle: Text('「${chapter.title}」',
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(ctx).textTheme.bodySmall),
            ),
            for (final c in candidates)
              ListTile(
                leading: const Icon(Icons.menu_book_outlined),
                title: Text(c.origin,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text('章节：${c.chapter.title}',
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(ctx).textTheme.bodySmall),
                onTap: () => Navigator.pop(ctx, 'use|${c.origin}'),
              ),
            if (hasOverride)
              ListTile(
                leading: const Icon(Icons.settings_backup_restore),
                title: const Text('恢复原源'),
                onTap: () => Navigator.pop(ctx, 'reset'),
              ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    if (picked == 'reset') {
      _chapterSources.remove(index);
      _toast('已恢复原源');
      unawaited(_loadChapter(index));
      return;
    }
    final origin = picked.substring(4);
    final cand =
        candidates.where((c) => c.origin == origin).firstOrNull;
    if (cand == null) return;
    final content =
        await _service.getContent(chapter, book, source: cand.source);
    if (!mounted) return;
    setState(() {
      _chapterSources[index] = cand.source;
      _content = content;
      _loading = false;
    });
    if (content.body.trim().isNotEmpty) {
      _toast('本章已切换为「$origin」');
    } else {
      _toast('「$origin」未解析出正文');
    }
  }

  /// 朗读配置对话框：调整语速/音量并实时应用到当前扬声器。
  Future<void> _showReadAloudConfig() async {
    await showDialog<void>(
      context: context,
      builder: (dctx) => StatefulBuilder(
        builder: (dctx, setDialog) => AlertDialog(
          title: const Text('朗读配置'),
          content: SingleChildScrollView(
            child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('语速'),
                trailing: SizedBox(width: 160, child: Slider(
                  value: _pref.ttsSpeechRate,
                  min: 0.1,
                  max: 1.0,
                  divisions: 9,
                  label: _pref.ttsSpeechRate.toStringAsFixed(1),
                  onChanged: (v) {
                    _pref.setTtsSpeechRate(v);
                    setDialog(() {});
                    _applyTtsParams();
                  },
                )),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('音量'),
                trailing: SizedBox(width: 160, child: Slider(
                  value: _pref.ttsVolume,
                  min: 0.0,
                  max: 1.0,
                  divisions: 10,
                  label: '${(_pref.ttsVolume * 100).round()}%',
                  onChanged: (v) {
                    _pref.setTtsVolume(v);
                    setDialog(() {});
                    _applyTtsParams();
                  },
                )),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('定时停止'),
                subtitle: Text(_pref.aloudTimeout == 0
                    ? '不限时'
                    : '${_pref.aloudTimeout} 分钟后自动停止'),
                trailing: DropdownButton<int>(
                  value: _pref.aloudTimeout,
                  items: [
                    for (final min in const [0, 5, 10, 15, 30, 60])
                      DropdownMenuItem(
                          value: min,
                          child: Text(min == 0 ? '不限时' : '$min 分钟')),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    _pref.setAloudTimeout(v);
                    setDialog(() {});
                    // 朗读中立即以新定时重置。
                    if (_ttsPlaying) _startAloudTimer(v);
                  },
                ),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('阅读时翻页'),
                subtitle: const Text('朗读过程中手动翻章的处理方式'),
                trailing: DropdownButton<int>(
                  value: _pref.aloudOnPageTurn,
                  items: const [
                    DropdownMenuItem(value: 0, child: Text('停止朗读')),
                    DropdownMenuItem(value: 1, child: Text('忽略(继续)')),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    _pref.setAloudOnPageTurn(v);
                    setDialog(() {});
                  },
                ),
              ),
              if (_ttsPlaying && _aloudRemainSec > 0)
                Text(
                  '已开启定时，剩余 ${(_aloudRemainSec ~/ 60).toString().padLeft(2, '0')}:${(_aloudRemainSec % 60).toString().padLeft(2, '0')}',
                  style: TextStyle(
                      fontSize: 12, color: Theme.of(dctx).colorScheme.primary),
                ),
              const Text(
                '以系统TTS引擎时语速/音量直接生效；HTTP网络TTS引擎语速由其连接URL决定，仅音量生效。',
                style: TextStyle(fontSize: 12),
              ),
            ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dctx),
              child: const Text('完成'),
            ),
          ],
        ),
      ),
    );
  }

  /// 把当前朗读配置应用到扬声器（若在朗读中重启会以新参数续播）。
  void _applyTtsParams() {
    _speaker?.setParams(
      speechRate: _pref.ttsSpeechRate,
      volume: _pref.ttsVolume,
    );
  }

  Future<void> _showSettings() async {
    await _pref.load();
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.55,
          maxChildSize: 0.85,
          builder: (_, controller) {
            final theme = _pref.theme;
            return Container(
              color: Color.alphaBlend(theme.bg, Colors.black12),
              child: ListView(
                controller: controller,
                padding: const EdgeInsets.all(16),
                children: [
                  Text('阅读设置', style: Theme.of(ctx).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  // 字号
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('字号'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.text_decrease),
                          onPressed: _fontSize(indexAdjust: -2),
                        ),
                        Text('${_pref.fontSize}'),
                        IconButton(
                          icon: const Icon(Icons.text_increase),
                          onPressed: _fontSize(indexAdjust: 2),
                        ),
                      ],
                    ),
                  ),
                  // 行距
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('字体粗细'),
                    trailing: DropdownButton<int>(
                      value: _pref.fontWeight,
                      items: const [
                        DropdownMenuItem(value: 0, child: Text('标准')),
                        DropdownMenuItem(value: 1, child: Text('中等')),
                        DropdownMenuItem(value: 2, child: Text('加粗')),
                      ],
                      onChanged: (v) {
                        if (v == null) return;
                        _pref.setFontWeight(v);
                        setSheet(() {});
                        setState(() {});
                      },
                    ),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('下划线'),
                    value: _pref.fontUnderline,
                    onChanged: (v) {
                      _pref.setFontUnderline(v);
                      setSheet(() {});
                      setState(() {});
                    },
                  ),
                  // 行距
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('行距'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.remove_circle_outline),
                          onPressed: _lineHeight(delta: -0.1),
                        ),
                        Text(_pref.lineHeight.toStringAsFixed(1)),
                        IconButton(
                          icon: const Icon(Icons.add_circle_outline),
                          onPressed: _lineHeight(delta: 0.1),
                        ),
                      ],
                    ),
                  ),
                  // 字距（调节到 setSheet 刷新）
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('字距'),
                    trailing: SizedBox(
                      width: 160,
                      child: Slider(
                        value: _pref.letterSpacing,
                        min: 0,
                        max: 2,
                        divisions: 20,
                        label: _pref.letterSpacing.toStringAsFixed(1),
                        onChanged: (v) {
                          _pref.setLetterSpacing(v);
                          setSheet(() {});
                        },
                      ),
                    ),
                  ),
                  // 段距
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('段距'),
                    trailing: SizedBox(
                      width: 160,
                      child: Slider(
                        value: _pref.paragraphSpacing,
                        min: 0,
                        max: 40,
                        divisions: 16,
                        label: _pref.paragraphSpacing.toStringAsFixed(0),
                        onChanged: (v) {
                          _pref.setParagraphSpacing(v);
                          setSheet(() {});
                        },
                      ),
                    ),
                  ),
                  // 简繁转换
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('简繁'),
                    trailing: DropdownButton<int>(
                      value: _pref.convertType,
                      items: const [
                        DropdownMenuItem(value: 0, child: Text('不转换')),
                        DropdownMenuItem(value: 1, child: Text('简体→繁体')),
                        DropdownMenuItem(value: 2, child: Text('繁体→简体')),
                      ],
                      onChanged: (v) {
                        if (v == null) return;
                        _pref.setConvertType(v);
                        setSheet(() {});
                        setState(() => _reloadCurrentChapter());
                      },
                    ),
                  ),
                  // 正文反转（倒序阅读）
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('正文反转'),
                    subtitle: const Text('整章段落倒序，从结尾往回读'),
                    value: _pref.reverseOrder,
                    onChanged: (v) {
                      _pref.setReverseOrder(v);
                      setSheet(() {});
                      setState(() {});
                    },
                  ),
                  // 图片样式（仅漫画源生效）
                  if (widget.book.isImageSource)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('图片样式'),
                      trailing: DropdownButton<int>(
                        value: _pref.imageFit,
                        items: const [
                          DropdownMenuItem(value: 0, child: Text('铺满')),
                          DropdownMenuItem(value: 1, child: Text('适应宽度')),
                        ],
                        onChanged: (v) {
                          if (v == null) return;
                          _pref.setImageFit(v);
                          setSheet(() {});
                          setState(() {});
                        },
                      ),
                    ),
                  // 漫画显示调节（亮度/对比度/饱和度/滤镜/双页）
                  if (widget.book.isImageSource)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.tune),
                      title: const Text('漫画显示'),
                      subtitle: const Text('亮度/对比度/饱和度 · 滤镜 · 双页'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () {
                        Navigator.pop(ctx);
                        _openComicSettings();
                      },
                    ),
                  // 听书设置（跳过片头 / 倍速）
                  if (widget.book.isAudioSource) ...[
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('跳过片头'),
                      trailing: SizedBox(
                        width: 160,
                        child: Slider(
                          value: _pref.audioSkipIntro,
                          min: 0,
                          max: 60,
                          divisions: 12,
                          label: '${_pref.audioSkipIntro.round()} 秒',
                          onChanged: (v) {
                            _pref.setAudioSkipIntro(v);
                            setSheet(() {});
                          },
                        ),
                      ),
                      subtitle: Text('${_pref.audioSkipIntro.round()} 秒'),
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('播放倍速'),
                      trailing: SizedBox(
                        width: 160,
                        child: Slider(
                          value: _pref.audioSpeed,
                          min: 0.5,
                          max: 3.0,
                          divisions: 10,
                          label: '${_pref.audioSpeed.toStringAsFixed(1)}x',
                          onChanged: (v) {
                            _pref.setAudioSpeed(v);
                            setSheet(() {});
                            setState(() {});
                          },
                        ),
                      ),
                      subtitle: Text('${_pref.audioSpeed.toStringAsFixed(1)}x'),
                    ),
                  ],
                  // 背景主题
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 4),
                    child: Text('背景主题'),
                  ),
                  SizedBox(
                    height: 40,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: [
                        for (var i = 0; i < ReadingPref.kThemes.length; i++)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ChoiceChip(
                              label: Text(ReadingPref.kThemes[i].name),
                              selected: _pref.themeIndex == i,
                              onSelected: (_) => _setThemeIndex(ctx, setSheet, i),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  // 翻页模式
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('翻页模式'),
                    trailing: DropdownButton<int>(
                      value: _pref.pageMode,
                      items: [
                        for (var i = 0; i < ReadingPref.kPageModeNames.length; i++)
                          DropdownMenuItem(
                            value: i,
                            child: Text(ReadingPref.kPageModeNames[i]),
                          ),
                      ],
                      onChanged: (v) {
                        if (v == null) return;
                        _pref.setPageMode(v);
                        setSheet(() {});
                      },
                    ),
                  ),
                  // 点击区域翻页
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('点击区域翻页'),
                    subtitle: const Text('左右两侧翻页，中间唤出菜单'),
                    value: _pref.tapZone,
                    onChanged: (v) {
                      _pref.setTapZone(v);
                      setSheet(() {});
                    },
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('首行缩进'),
                    subtitle: const Text('滚动模式段首缩进两个全角空格'),
                    value: _pref.paragraphIndent,
                    onChanged: (v) {
                      _pref.setParagraphIndent(v);
                      setSheet(() {});
                      setState(() {});
                    },
                  ),
                  // 自动翻页间隔
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('自动翻页间隔'),
                    subtitle: Text('${_pref.autoReadInterval.toStringAsFixed(1)} 秒'),
                    trailing: SizedBox(
                      width: 160,
                      child: Slider(
                        value: _pref.autoReadInterval,
                        min: 0.5,
                        max: 30,
                        divisions: 30,
                        label: '${_pref.autoReadInterval.toStringAsFixed(1)}s',
                        onChanged: (v) {
                          _pref.setAutoReadInterval(v);
                          setSheet(() {});
                          _restartAutoPlay();
                        },
                      ),
                    ),
                  ),
                  // 应用内亮度
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('亮度'),
                    subtitle: Text(
                      _pref.brightness < 1.0
                          ? '当前：${_pref.brightness.toStringAsFixed(1)}（偏暗）'
                          : (_pref.brightness > 1.0
                              ? '当前：${_pref.brightness.toStringAsFixed(1)}（偏亮）'
                              : '当前：标准'),
                    ),
                    trailing: SizedBox(
                      width: 160,
                      child: Slider(
                        value: _pref.brightness,
                        min: 0.3,
                        max: 1.8,
                        divisions: 15,
                        label: _pref.brightness.toStringAsFixed(1),
                        onChanged: (v) {
                          _pref.setBrightness(v);
                          setSheet(() {});
                          setState(() {});
                        },
                      ),
                    ),
                  ),
                  // 朗读配置（语速/音量）
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.settings_voice_outlined),
                    title: const Text('朗读配置'),
                    subtitle: Text(
                      '语速 ${_pref.ttsSpeechRate.toStringAsFixed(1)} · 音量 ${(_pref.ttsVolume * 100).round()}%',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
                      Navigator.pop(ctx);
                      _showReadAloudConfig();
                    },
                  ),
                  // 换源
                  if (widget.localBook == null)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.swap_horiz),
                      title: const Text('换源阅读'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () {
                        Navigator.pop(ctx);
                        _switchSource();
                      },
                    ),
                  // 随机换源
                  if (widget.localBook == null)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.casino_outlined),
                      title: const Text('随机换源'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () {
                        Navigator.pop(ctx);
                        unawaited(_randomSource());
                      },
                    ),
                  // 本章换源
                  if (widget.localBook == null)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.swap_calls),
                      title: const Text('本章换源'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () {
                        Navigator.pop(ctx);
                        unawaited(_switchChapterSource());
                      },
                    ),
                  // 页边距滑块
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('页边距'),
                    trailing: SizedBox(
                      width: 140,
                      child: Slider(
                        value: _pref.pagePadding.toDouble(),
                        min: 8,
                        max: 40,
                        divisions: 8,
                        label: '${_pref.pagePadding}',
                        onChanged: (v) {
                          _pref.setPagePadding(v.round());
                          setSheet(() {});
                        },
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  /// 漫画显示调节面板：亮度/对比度/饱和度/滤镜/双页（实时预览）。
  Future<void> _openComicSettings() async {
    var brightness = _pref.comicBrightness;
    var contrast = _pref.comicContrast;
    var saturation = _pref.comicSaturation;
    var filter = _pref.comicFilter;
    var doublePage = _pref.comicDoublePage;
    var scrollMode = _pref.comicScroll;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('漫画显示',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                const SizedBox(height: 4),
                _comicSlider(
                  ctx,
                  label: '亮度',
                  value: brightness,
                  min: 0.3,
                  max: 1.8,
                  onChanged: (v) {
                    brightness = v;
                    setSheet(() {});
                  },
                  onLive: (v) {
                    _pref.setComicBrightness(v);
                    setState(() {});
                  },
                ),
                _comicSlider(
                  ctx,
                  label: '对比度',
                  value: contrast,
                  min: 0.5,
                  max: 2.0,
                  onChanged: (v) {
                    contrast = v;
                    setSheet(() {});
                  },
                  onLive: (v) {
                    _pref.setComicContrast(v);
                    setState(() {});
                  },
                ),
                _comicSlider(
                  ctx,
                  label: '饱和度',
                  value: saturation,
                  min: 0.0,
                  max: 2.0,
                  onChanged: (v) {
                    saturation = v;
                    setSheet(() {});
                  },
                  onLive: (v) {
                    _pref.setComicSaturation(v);
                    setState(() {});
                  },
                ),
                const SizedBox(height: 8),
                Text('色彩滤镜', style: Theme.of(ctx).textTheme.labelLarge),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final f in ComicFilter.values)
                      ChoiceChip(
                        label: Text(f.label),
                        selected: filter == f,
                        onSelected: (_) {
                          filter = f;
                          _pref.setComicFilter(f);
                          setSheet(() {});
                          setState(() {});
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('双页平铺'),
                  subtitle: const Text('横屏时一屏两页'),
                  value: doublePage,
                  onChanged: (v) {
                    doublePage = v;
                    _pref.setComicDoublePage(v);
                    setSheet(() {});
                    setState(() {});
                    _toast(v ? '已开启双页' : '已关闭双页');
                  },
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('拼接 / 连续滚动'),
                  subtitle: const Text('一列纵向浏览全部图片'),
                  value: scrollMode,
                  onChanged: (v) {
                    scrollMode = v;
                    _pref.setComicScroll(v);
                    setSheet(() {});
                    setState(() {});
                    _toast(v ? '已开启拼接模式' : '已关闭拼接模式');
                  },
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('只显示大图'),
                  subtitle: const Text('过滤过小的占位/缩略图'),
                  value: _pref.comicOnlyLarge,
                  onChanged: (v) {
                    _pref.setComicOnlyLarge(v);
                    setSheet(() {});
                    setState(() {});
                    _toast(v ? '已开启只显示大图' : '已关闭只显示大图');
                  },
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('深色反色'),
                  subtitle: const Text('夜间阅读反转明暗'),
                  value: _pref.comicInvert,
                  onChanged: (v) {
                    _pref.setComicInvert(v);
                    setSheet(() {});
                    setState(() {});
                    _toast(v ? '已开启反色' : '已关闭反色');
                  },
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('锁定视图'),
                  subtitle: const Text('禁用缩放与平移'),
                  value: _pref.comicLock,
                  onChanged: (v) {
                    _pref.setComicLock(v);
                    setSheet(() {});
                    setState(() {});
                    _toast(v ? '已锁定视图' : '已解锁视图');
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _comicSlider(
    BuildContext ctx, {
    required String label,
    required double value,
    required double min,
    required double max,
    required ValueChanged<double> onChanged,
    required ValueChanged<double> onLive,
  }) {
    return Row(
      children: [
        SizedBox(width: 56, child: Text(label)),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: max == 2.0 ? 20 : 15,
            label: value.toStringAsFixed(2),
            onChangeEnd: onLive,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 44,
          child: Text(value.toStringAsFixed(2), textAlign: TextAlign.end),
        ),
      ],
    );
  }

  VoidCallback _fontSize({required int indexAdjust}) => () {
        final idx = ReadingPref.kFontSizes.indexOf(_pref.fontSize);
        final ni = (idx + indexAdjust).clamp(0, ReadingPref.kFontSizes.length - 1);
        _pref.setFontSize(ReadingPref.kFontSizes[ni]);
        setState(() {});
      };

  VoidCallback _lineHeight({required double delta}) => () {
        final nv = (_pref.lineHeight + delta).clamp(1.2, 2.5);
        _pref.setLineHeight(nv);
        setState(() {});
      };

  void _setThemeIndex(BuildContext ctx, StateSetter setSheet, int i) {
    _pref.setThemeIndex(i);
    setSheet(() {});
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final chapter = _chapters[_index];
    final theme = _pref.theme;
    return Scaffold(
      backgroundColor: theme.bg,
      appBar: _showChrome
          ? AppBar(
              backgroundColor: theme.bg,
              foregroundColor: theme.fg,
              title: Text(chapter.title,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              actions: [
                IconButton(
                  icon: Icon(_ttsPlaying ? Icons.stop_circle_outlined : Icons.record_voice_over_outlined),
                  tooltip: _ttsPlaying ? '停止朗读' : '朗读本章',
                  onPressed: _toggleTts,
                ),
                IconButton(
                  icon: Icon(_autoPlaying ? Icons.pause_circle_outline : Icons.play_circle_outline),
                  tooltip: _autoPlaying ? '停止自动翻页' : '自动翻页',
                  onPressed: _toggleAutoPlay,
                ),
                IconButton(
                  icon: Icon(BookmarkService.instance.contains(_currentBookKey(), _index)
                      ? Icons.bookmark
                      : Icons.bookmark_border),
                  tooltip: '添加/移除书签',
                  onPressed: _toggleBookmark,
                ),
                IconButton(
                  icon: const Icon(Icons.bookmarks_outlined),
                  tooltip: '书签列表',
                  onPressed: _showBookmarks,
                ),
                IconButton(
                  icon: const Icon(Icons.manage_search_outlined),
                  tooltip: '书中搜索',
                  onPressed: _showInBookSearch,
                ),
                IconButton(
                  icon: const Icon(Icons.chrome_reader_mode_outlined),
                  onPressed: _showChapterSheet,
                ),
                if (widget.localBook == null &&
                    _bookSource?.customButton == true)
                  IconButton(
                    icon: const Icon(Icons.extension),
                    tooltip: '自定义按钮（书源）',
                    onPressed: () {
                      _dispatchSourceEvent('clickCustomButton');
                      _toast('已触发书源自定义按钮回调');
                    },
                  ),
                if (widget.book.isImageSource)
                  _downloadingChapter
                      ? const Padding(
                          padding: EdgeInsets.only(right: 12),
                          child: Center(
                            child: SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                        )
                      : IconButton(
                          icon: Icon(_isChapterOffline()
                              ? Icons.offline_pin
                              : Icons.download_for_offline_outlined),
                          tooltip: _isChapterOffline()
                              ? '删除本章离线缓存'
                              : '离线下载本章',
                          onPressed: _isChapterOffline()
                              ? _deleteChapterOffline
                              : _downloadChapterOffline,
                        ),
                if (widget.localBook == null && !widget.book.isMediaSource)
                  _cachingBook
                      ? const Padding(
                          padding: EdgeInsets.only(right: 12),
                          child: Center(
                            child: SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                        )
                      : IconButton(
                          icon: const Icon(Icons.file_download_outlined),
                          tooltip: '缓存全本（离线阅读）',
                          onPressed: _cacheWholeBook,
                        ),
                if (widget.localBook == null)
                  IconButton(
                    icon: const Icon(Icons.sync),
                    tooltip: '更新目录',
                    onPressed: _refreshToc,
                  ),
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert),
                  tooltip: '更多',
                  onSelected: (v) {
                    if (v == 'writeNote') {
                      _editCurrentNote();
                    } else if (v == 'notes') {
                      _showNotes();
                    } else if (v == 'exportChapter') {
                      _exportCurrentChapter();
                    } else if (v == 'exportBook') {
                      _exportCachedBook();
                    } else if (v == 'webView') {
                      _openWebViewSource();
                    } else if (v == 'shareChapter') {
                      _shareCurrentChapter();
                    }
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                        value: 'writeNote',
                        child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(Icons.note_add_outlined),
                            title: Text('写/看本章笔记'))),
                    const PopupMenuItem(
                        value: 'notes',
                        child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(Icons.sticky_note_2_outlined),
                            title: Text('本书笔记列表'))),
                    const PopupMenuItem(
                        value: 'exportChapter',
                        child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(Icons.ios_share),
                            title: Text('导出本章 (txt)'))),
                    const PopupMenuItem(
                        value: 'exportBook',
                        child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(Icons.file_download_outlined),
                            title: Text('导出全书 (txt, 已缓存)'))),
                    const PopupMenuItem(
                        value: 'webView',
                        child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(Icons.language),
                            title: Text('用网页(WebView)打开本章'))),
                    const PopupMenuItem(
                        value: 'shareChapter',
                        child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(Icons.share_outlined),
                            title: Text('分享本章'))),
                  ],
                ),
                IconButton(
                  icon: const Icon(Icons.settings_outlined),
                  onPressed: _showSettings,
                ),
              ],
            )
          : null,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: widget.book.isMediaSource
                  ? _buildReader(theme)
                  // 分页模式下由 PagedTextView 处理翻页/点按；滚动模式沿用原手势。
                  // 文本统一交给 _buildReader 按当前翻页模式分支。
                  : (_pref.pageMode == 2
                      ? GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTapUp: (d) => _handleScrollTap(d),
                          onHorizontalDragEnd: (d) {
                            if (d.primaryVelocity != null && d.primaryVelocity! < -300) {
                              _next();
                            } else if (d.primaryVelocity != null && d.primaryVelocity! > 300) {
                              _prev();
                            }
                          },
                          child: _buildReader(theme),
                        )
                      : _buildReader(theme)),
            ),
            // 应用内亮度滤镜：<1 压暗（黑罩），>1 提亮（白罩）。
            if (_pref.brightness != 1.0)
              Positioned.fill(
                child: IgnorePointer(
                  child: Container(
                    color: _pref.brightness < 1.0
                        ? Colors.black.withValues(alpha: (1.0 - _pref.brightness) * 0.8)
                        : Colors.white.withValues(alpha: (_pref.brightness - 1.0) * 0.5),
                  ),
                ),
              ),
            // 底部进度条：唤出菜单时显示，可拖动快速定位章节。
            if (_showChrome)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  color: theme.bg.withValues(alpha: 0.92),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    children: [
                      Text('第${_index + 1}章',
                          style: TextStyle(fontSize: 11, color: theme.fg)),
                      Expanded(
                        child: Slider(
                          value: _tocDrag ?? _tocProgress,
                          onChanged: (v) => setState(() => _tocDrag = v),
                          onChangeStart: (_) => setState(() {}),
                          onChangeEnd: (v) {
                            setState(() => _tocDrag = null);
                            _jumpToProgress(v);
                          },
                        ),
                      ),
                      Text('${_chapters.length}章',
                          style: TextStyle(fontSize: 11, color: theme.fg)),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildReader(({String name, Color fg, Color bg}) theme) {
    if (_loading) {
      return Center(child: CircularProgressIndicator(color: theme.fg));
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error!, textAlign: TextAlign.center,
              style: TextStyle(color: theme.fg)),
        ),
      );
    }
    // 媒体源（图片/漫画/听书）：交给专用视图渲染素材。
    if (widget.book.isMediaSource) {
      if (widget.book.isImageSource) {
        return ComicReaderView(
          imageUrls: _mediaUrls,
          chapterIndex: _index,
          chapterCount: _chapters.length,
          chapterTitle: _chapters[_index].title,
          fg: theme.fg,
          bg: theme.bg,
          onToggleChrome: () => setState(() => _showChrome = !_showChrome),
          onNextChapter: _next,
          onPrevChapter: _prev,
          imageFit: _pref.imageFit,
          offline: _offline,
          brightness: _pref.comicBrightness,
          contrast: _pref.comicContrast,
          saturation: _pref.comicSaturation,
          filter: _pref.comicFilter,
          doublePage: _pref.comicDoublePage,
          scrollMode: _pref.comicScroll,
          onlyLarge: _pref.comicOnlyLarge,
          invert: _pref.comicInvert,
          locked: _pref.comicLock,
        );
      }
      if (widget.book.isAudioSource) {
        return AudioReaderView(
          urls: _mediaUrls,
          title: _chapters[_index].title,
          fg: theme.fg,
          skipIntro: _pref.audioSkipIntro,
          speed: _pref.audioSpeed,
          onFinish: _next,
        );
      }
      if (widget.book.isVideoSource) {
        return VideoReaderView(
          urls: _mediaUrls,
          title: _chapters[_index].title,
          fg: theme.fg,
          bg: theme.bg,
          onNextChapter: _next,
          onPrevChapter: _prev,
        );
      }
    }
    final content = _content!;
    final style = TextStyle(
      fontSize: _pref.fontSize.toDouble(),
      height: _pref.lineHeight,
      letterSpacing: _pref.letterSpacing,
      color: theme.fg,
      fontWeight: _pref.fontWeightValue,
      decoration: _pref.fontUnderline ? TextDecoration.underline : null,
      fontFamily: _pref.fontFamily.isEmpty ? null : _pref.fontFamily,
    );
    final body = _orderedBody(content.body);
    // 滚动模式：保留原有滚动排版（段间距 + 首行缩进）。
    if (_pref.pageMode == 2) {
      return SingleChildScrollView(
        controller: _scrollCtrl,
        padding: EdgeInsets.all(_pref.pagePadding.toDouble()),
        child: _buildParagraphs(body, style),
      );
    }
    // 仿真/覆盖/纵向：分页真实换页。
    return PagedTextView(
      key: _pagedKey,
      body: body,
      style: style,
      pageMode: _pref.pageMode,
      padding: _pref.pagePadding.toDouble(),
      initialPage: _pageIndex,
      onTap: () => setState(() => _showChrome = !_showChrome),
      onZoneTap: _handleZoneTap,
      onPageChanged: _onPageChanged,
      highlightBuilder: (pageText) =>
          HighlightService.instance.apply(pageText),
      onDictQuery: _showDictFor,
      onAddHighlight: _addHighlightFor,
    );
  }

  /// 滚动模式的点击区域动作：左右逐步滚动一屏，中间唤菜单。
  void _handleScrollTap(TapUpDetails d) {
    if (!_scrollCtrl.hasClients) {
      setState(() => _showChrome = !_showChrome);
      return;
    }
    final width = MediaQuery.of(context).size.width;
    final zone = d.localPosition.dx < width / 3
        ? PageTapZone.left
        : (d.localPosition.dx > width * 2 / 3
            ? PageTapZone.right
            : PageTapZone.middle);
    if (!_pref.tapZone || zone == PageTapZone.middle) {
      setState(() => _showChrome = !_showChrome);
      return;
    }
    final max = _scrollCtrl.position.maxScrollExtent;
    final step = _scrollCtrl.position.viewportDimension * 0.9;
    final target = zone == PageTapZone.right
        ? (max <= 0 ? 0.0 : _scrollCtrl.position.pixels + step)
        : _scrollCtrl.position.pixels - step;
    if (zone == PageTapZone.right && max > 0 && target >= max) {
      _next();
      return;
    }
    if (zone == PageTapZone.left &&
        _scrollCtrl.position.pixels <= _scrollCtrl.position.minScrollExtent) {
      _prev();
      return;
    }
    _scrollCtrl.animateTo(
      target.clamp(_scrollCtrl.position.minScrollExtent, max),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  /// 分页模式的点击区域动作：
  /// 左/右两侧翻上一/下一页（章内到头则翻章），中间唤菜单。
  /// 未启用「点击区域翻页」时三种区域都等于切换菜单。
  void _handleZoneTap(PageTapZone zone) {
    if (!_pref.tapZone) {
      setState(() => _showChrome = !_showChrome);
      return;
    }
    switch (zone) {
      case PageTapZone.left:
        final prev = _pagedKey.currentState?.goPrevPage();
        if (prev == null || !prev) _prev();
        break;
      case PageTapZone.middle:
        setState(() => _showChrome = !_showChrome);
        break;
      case PageTapZone.right:
        final next = _pagedKey.currentState?.goNextPage();
        if (next == null || !next) _next();
        break;
    }
  }

  /// 划词查词典：聚合启用词典源结果并底部弹出。
  void _showDictFor(String word) {
    if (word.isEmpty) return;
    DictService.instance.query(word).then((defs) {
      if (!mounted) return;
      if (defs.isEmpty) {
        _toast('未查找到「$word」的释义');
        return;
      }
      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        builder: (_) => SafeArea(
          child: DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.6,
            builder: (_, controller) => Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text('词典：$word',
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                Expanded(
                  child: ListView.builder(
                    controller: controller,
                    itemCount: defs.length,
                    itemBuilder: (_, i) => Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(defs[i]),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    });
  }

  /// 划词添加高亮（对齐官方：弹样式对话框选颜色/样式/笔记后保存）。
  Future<void> _addHighlightFor(String word) async {
    if (word.isEmpty) return;
    await HighlightService.instance.init();
    if (!mounted) return;
    final rule = await showHighlightEditDialog(context, keyword: word);
    if (rule == null) return;
    HighlightService.instance.addRule(rule);
    if (!mounted) return;
    setState(() {});
    _toast('已为「$word」添加高亮');
  }

  /// 正文反转：把整章段落逆序（从结尾往回读）。官方“倒序阅读”。
  String _orderedBody(String body) {
    if (!_pref.reverseOrder) return body;
    final paras = _splitParagraphs(body);
    return paras.reversed.join('\n\n');
  }

  /// 按空行切分段落。
  List<String> _splitParagraphs(String body) {
    final paragraphs = <String>[];
    var buf = <String>[];
    for (final line in body.split('\n')) {
      if (line.trim().isEmpty) {
        if (buf.isNotEmpty) {
          paragraphs.add(buf.join('\n'));
          buf = [];
        }
      } else {
        buf.add(line);
      }
    }
    if (buf.isNotEmpty) paragraphs.add(buf.join('\n'));
    if (paragraphs.isEmpty && body.trim().isNotEmpty) paragraphs.add(body);
    return paragraphs;
  }

  /// 按空行切分段落，段间加间距；开启时段首两全角空格缩进。
  Widget _buildParagraphs(String body, TextStyle style) {
    final paragraphs = _splitParagraphs(body);
    final prefix = _pref.paragraphIndent ? '\u3000\u3000' : '';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < paragraphs.length; i++) ...[
          if (i > 0) SizedBox(height: _pref.paragraphSpacing),
          Text('$prefix${paragraphs[i]}', style: style),
        ],
      ],
    );
  }
}

/// 目录扁平条目，用于区分「卷标记」与「普通章节」。
class _TocEntry {
  const _TocEntry({
    required this.chapter,
    required this.index,
    required this.isVolume,
  });

  final BookChapter chapter;
  final int index;
  final bool isVolume;
}