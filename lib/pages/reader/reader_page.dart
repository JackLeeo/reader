// 阅读器页面 - 核心阅读界面（增强版）
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/book.dart';
import '../../models/bookmark.dart';
import '../../models/chapter.dart';
import '../../models/history_item.dart';
import '../../models/shelf_book.dart';
import '../../services/book_source_service.dart';
import '../../services/bookmark_service.dart';
import '../../services/chapter_cache_service.dart';
import '../../services/history_service.dart';
import '../../services/reader_service.dart';
import '../../services/settings_service.dart';
import '../../services/shelf_service.dart';
import '../../services/source_switch_service.dart';
import '../../services/stats_service.dart';
import '../../utils/extensions.dart';
import '../../utils/log.dart';
import '../../widgets/empty_state.dart';
import '../book/chapter_list_page.dart';
import 'reader_settings_sheet.dart';
import 'local_reader_page.dart';
import 'bookmark_list_sheet.dart';
import 'source_switch_sheet.dart';

class ReaderPage extends StatefulWidget {
  final Book book;
  final List<Chapter>? chapters;
  final int startChapter;

  const ReaderPage({
    super.key,
    required this.book,
    this.chapters,
    this.startChapter = 0,
  });

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> {
  late final ReaderService _reader;
  final _scrollController = ScrollController();

  List<Chapter> _chapters = [];
  int _currentIndex = 0;
  String _content = '';
  bool _loading = false;
  String? _error;
  bool _showChrome = true;
  String? _currentSourceId; // 当前生效的源（支持换源）
  int _startOffset = 0; // 入口进度（从shelf恢复）
  DateTime _sessionStart = DateTime.now();
  int _initialCharsRead = 0;
  PageController? _pageController;
  int _pageCount = 0;

  @override
  void initState() {
    super.initState();
    _reader = ReaderService(
      chapterCache: context.read<ChapterCacheService>(),
    );
    _currentIndex = widget.startChapter;
    _currentSourceId = widget.book.sourceId;
    _sessionStart = DateTime.now();
    _initialCharsRead = 0;
    if (widget.chapters != null && widget.chapters!.isNotEmpty) {
      _chapters = widget.chapters!;
      _loadCurrent();
    } else {
      _loadChapters();
    }
    _scrollController.addListener(_onScroll);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _pageController?.dispose();
    _recordSession();
    super.dispose();
  }

  Future<void> _loadChapters() async {
    final src = _findSource();
    if (src == null) {
      setState(() => _error = '书源不可用');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final chs = await _reader.getToc(src, widget.book);
      if (!mounted) return;
      setState(() {
        _chapters = chs;
        _loading = false;
        if (chs.isEmpty) {
          _error = '目录为空';
        } else {
          _loadCurrent();
        }
      });
    } catch (e, st) {
      Log.e('加载目录失败', error: e, stack: st);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _loadCurrent() async {
    if (_chapters.isEmpty ||
        _currentIndex < 0 ||
        _currentIndex >= _chapters.length) {
      return;
    }
    final src = _findSource();
    if (src == null) return;

    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final ch = _chapters[_currentIndex];
      final content = await _reader.getContent(
        src,
        ch.url,
        bookId: widget.book.id,
        chapterIndex: _currentIndex,
      );
      if (!mounted) return;
      setState(() {
        _content = content.isEmpty ? '(本章无内容)' : content;
        _loading = false;
        _pageController?.dispose();
        _pageController = null;
        _pageCount = 0;
      });
      _scrollController.jumpTo(_startOffset.toDouble());
      _startOffset = 0;
      _recordHistory(ch);
    } catch (e, st) {
      Log.e('加载章节内容失败', error: e, stack: st);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  dynamic _findSource() {
    final id = _currentSourceId ?? widget.book.sourceId;
    return context.read<BookSourceService>().findById(id);
  }

  void _recordHistory(Chapter ch) {
    final history = context.read<HistoryService>();
    history.add(HistoryItem(
      book: widget.book,
      readTime: DateTime.now(),
      chapterIndex: _currentIndex,
      chapterCount: _chapters.length,
      chapterTitle: ch.title.isEmpty ? '第${_currentIndex + 1}章' : ch.title,
    ));
  }

  void _onScroll() {
    final pos = _scrollController.position;
    if (pos.pixels > pos.maxScrollExtent - 200) {
      _autoLoadNext();
    }
    _saveProgress();
  }

  bool _autoLoading = false;
  Future<void> _autoLoadNext() async {
    if (_autoLoading) return;
    if (_currentIndex >= _chapters.length - 1) return;
    _autoLoading = true;
    await Future.delayed(const Duration(milliseconds: 300));
    _autoLoading = false;
    if (!mounted) return;
    if (_currentIndex >= _chapters.length - 1) return;
    final pos = _scrollController.position;
    if (pos.pixels > pos.maxScrollExtent - 100) {
      _nextChapter();
    }
  }

  void _saveProgress() {
    final shelf = context.read<ShelfService>();
    if (shelf.contains(widget.book.id)) {
      shelf.updateProgress(
        widget.book.id,
        chapterIndex: _currentIndex,
        offset: _scrollController.position.pixels.toInt(),
        totalChapters: _chapters.length,
      );
    }
  }

  void _nextChapter() {
    if (_currentIndex >= _chapters.length - 1) return;
    setState(() => _currentIndex++);
    _loadCurrent();
  }

  void _prevChapter() {
    if (_currentIndex <= 0) return;
    setState(() => _currentIndex--);
    _loadCurrent();
  }

  void _toggleChrome() {
    setState(() => _showChrome = !_showChrome);
    if (_showChrome) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    } else {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
  }

  /// 添加书签
  Future<void> _addBookmark() async {
    if (_chapters.isEmpty) return;
    final ch = _chapters[_currentIndex];
    final offset = _scrollController.position.pixels.toInt();
    final snippet = _content.length > 50
        ? _content.substring(0, 50)
        : _content;
    final b = Bookmark(
      bookId: widget.book.id,
      chapterIndex: _currentIndex,
      chapterTitle: ch.title,
      offset: offset,
      snippet: snippet,
    );
    await context.read<BookmarkService>().add(b);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已添加书签'), duration: Duration(seconds: 1)),
    );
  }

  /// 跳转书签
  void _gotoBookmark(Bookmark b) {
    if (b.chapterIndex < 0 || b.chapterIndex >= _chapters.length) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('书签对应章节已不存在')),
      );
      return;
    }
    setState(() {
      _currentIndex = b.chapterIndex;
      _startOffset = b.offset;
    });
    _loadCurrent();
  }

  /// 换源
  Future<void> _switchSource() async {
    final sw = SourceSwitchService(context.read<BookSourceService>());
    final candidates =
        await sw.searchAcrossSources(widget.book.name);
    if (!mounted) return;
    if (candidates.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('未找到其它书源')),
      );
      return;
    }
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SourceSwitchSheet(
        book: widget.book,
        candidates: candidates,
        onSwitch: (book) async {
          Navigator.pop(ctx);
          setState(() {
            _currentSourceId = book.sourceId;
            _chapters = [];
            _content = '';
            _currentIndex = 0;
          });
          // 替换当前书的来源
          widget.book.sourceId = book.sourceId;
          widget.book.sourceName = book.sourceName;
          widget.book.bookUrl = book.bookUrl;
          widget.book.tocUrl = book.tocUrl;
          await _loadChapters();
        },
      ),
    );
  }

  /// 记录阅读 session
  void _recordSession() {
    if (_content.isEmpty) return;
    final newChars = _content.length;
    final delta = newChars - _initialCharsRead;
    _initialCharsRead = newChars;
    if (delta <= 0) return;
    final duration = DateTime.now().difference(_sessionStart);
    if (duration.inSeconds < 5) return; // 太短不算
    final session = ReadingSession(
      bookId: widget.book.id,
      date: DateTime.now(),
      duration: duration,
      charsRead: delta,
    );
    context.read<StatsService>().record(session);
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>();
    final bgColor = _parseHexColor(settings.bgColor) ?? const Color(0xFFFFF8E1);
    final textColor =
        _parseHexColor(settings.textColor) ?? const Color(0xFF3E2723);

    // 保持屏幕常亮
    if (settings.keepScreenOn) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }

    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _saveProgress();
      },
      child: Scaffold(
        backgroundColor: bgColor,
        body: GestureDetector(
          onTap: _toggleChrome,
          child: SafeArea(
            child: Column(
              children: [
                if (_showChrome) _buildTopBar(),
                Expanded(
                  child: _buildContent(bgColor, textColor, settings),
                ),
                if (_showChrome) _buildBottomBar(bgColor, textColor),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.05),
          border: Border(
            bottom: BorderSide(color: Colors.black.withValues(alpha: 0.08)),
          ),
        ),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back_ios_new, size: 20),
              onPressed: () {
                _saveProgress();
                Navigator.pop(context);
              },
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.book.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  if (widget.book.sourceName.isNotEmpty)
                    Text(
                      '源: ${widget.book.sourceName}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.grey.shade600,
                      ),
                    ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.bookmark_add_outlined, size: 22),
              tooltip: '添加书签',
              onPressed: _addBookmark,
            ),
            IconButton(
              icon: const Icon(Icons.bookmarks_outlined, size: 22),
              tooltip: '书签列表',
              onPressed: () {
                showModalBottomSheet(
                  context: context,
                  isScrollControlled: true,
                  builder: (ctx) => BookmarkListSheet(
                    bookId: widget.book.id,
                    onTap: (b) {
                      Navigator.pop(ctx);
                      _gotoBookmark(b);
                    },
                  ),
                );
              },
            ),
            IconButton(
              icon: const Icon(Icons.swap_horiz, size: 22),
              tooltip: '换源',
              onPressed: _switchSource,
            ),
            IconButton(
              icon: const Icon(Icons.list, size: 22),
              tooltip: '目录',
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ChapterListPage(
                      book: widget.book,
                      chapters: _chapters,
                      currentIndex: _currentIndex,
                      onTapChapter: (idx) {
                        Navigator.pop(context);
                        setState(() => _currentIndex = idx);
                        _loadCurrent();
                      },
                    ),
                  ),
                );
              },
            ),
            IconButton(
              icon: const Icon(Icons.format_color_fill, size: 22),
              tooltip: '设置',
              onPressed: () => showReaderSettings(context),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent(
      Color bgColor, Color textColor, SettingsService settings) {
    if (_loading && _content.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _content.isEmpty) {
      return EmptyState(
        icon: Icons.error_outline,
        message: '加载失败',
        hint: _error,
        action: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            FilledButton.tonal(
              onPressed: _loadCurrent,
              child: const Text('重试'),
            ),
            const SizedBox(width: 12),
            OutlinedButton(
              onPressed: () {
                setState(() => _currentIndex = 0);
                _loadCurrent();
              },
              child: const Text('第一章'),
            ),
          ],
        ),
      );
    }
    final chapter = _chapters.isNotEmpty ? _chapters[_currentIndex] : null;
    final mode = settings.pageTurn;
    if (mode == 'slide') {
      return _buildScrollContent(chapter, textColor, settings);
    } else if (mode == 'curl') {
      return _buildCurlContent(chapter, textColor, settings);
    } else {
      return _buildPlainContent(chapter, textColor, settings);
    }
  }

  Widget _buildScrollContent(
      Chapter? chapter, Color textColor, SettingsService settings) {
    return ListView(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 80),
      children: [
        Text(
          chapter?.title.isNotEmpty == true
              ? chapter!.title
              : '第${_currentIndex + 1}章',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: settings.fontSize + 4,
            fontWeight: FontWeight.w700,
            color: textColor,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 16),
        SelectableText(
          _content,
          style: TextStyle(
            fontSize: settings.fontSize,
            height: settings.lineHeight,
            color: textColor,
          ),
        ),
        const SizedBox(height: 32),
        if (_currentIndex < _chapters.length - 1)
          Center(
            child: Text(
              '— 继续下拉加载下一章 —',
              style: TextStyle(
                fontSize: settings.fontSize - 2,
                color: textColor.withValues(alpha: 0.5),
              ),
            ),
          )
        else
          Center(
            child: Text(
              '— 已读完本书 —',
              style: TextStyle(
                fontSize: settings.fontSize - 2,
                color: textColor.withValues(alpha: 0.5),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildPlainContent(
      Chapter? chapter, Color textColor, SettingsService settings) {
    // 单页模式：屏幕左右区域点击翻页
    return Stack(
      children: [
        Positioned.fill(
          child: SingleChildScrollView(
            controller: _scrollController,
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 80),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  chapter?.title.isNotEmpty == true
                      ? chapter!.title
                      : '第${_currentIndex + 1}章',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: settings.fontSize + 4,
                    fontWeight: FontWeight.w700,
                    color: textColor,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 16),
                SelectableText(
                  _content,
                  style: TextStyle(
                    fontSize: settings.fontSize,
                    height: settings.lineHeight,
                    color: textColor,
                  ),
                ),
                const SizedBox(height: 32),
                if (_currentIndex < _chapters.length - 1)
                  Center(
                    child: Text(
                      '— 继续下拉加载下一章 —',
                      style: TextStyle(
                        fontSize: settings.fontSize - 2,
                        color: textColor.withValues(alpha: 0.5),
                      ),
                    ),
                  )
                else
                  Center(
                    child: Text(
                      '— 已读完本书 —',
                      style: TextStyle(
                        fontSize: settings.fontSize - 2,
                        color: textColor.withValues(alpha: 0.5),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        // 左右翻页热区
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: 64,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _prevChapter,
          ),
        ),
        Positioned(
          right: 0,
          top: 0,
          bottom: 0,
          width: 64,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _nextChapter,
          ),
        ),
      ],
    );
  }

  Widget _buildCurlContent(
      Chapter? chapter, Color textColor, SettingsService settings) {
    // 仿真翻页：使用 PageView 提供水平滑动
    if (_pageController == null) {
      _pageController = PageController();
    }
    return PageView.builder(
      controller: _pageController,
      itemCount: 1,
      itemBuilder: (ctx, i) {
        return SingleChildScrollView(
          controller: _scrollController,
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 80),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                chapter?.title.isNotEmpty == true
                    ? chapter!.title
                    : '第${_currentIndex + 1}章',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: settings.fontSize + 4,
                  fontWeight: FontWeight.w700,
                  color: textColor,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 16),
              SelectableText(
                _content,
                style: TextStyle(
                  fontSize: settings.fontSize,
                  height: settings.lineHeight,
                  color: textColor,
                ),
              ),
              const SizedBox(height: 32),
            ],
          ),
        );
      },
    );
  }

  Widget _buildBottomBar(Color bgColor, Color textColor) {
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.05),
          border: Border(
            top: BorderSide(color: Colors.black.withValues(alpha: 0.08)),
          ),
        ),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.chevron_left, size: 28),
              onPressed: _currentIndex > 0 ? _prevChapter : null,
            ),
            Expanded(
              child: Center(
                child: Text(
                  '第 ${_currentIndex + 1} / ${_chapters.length} 章',
                  style: TextStyle(color: textColor),
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.chevron_right, size: 28),
              onPressed:
                  _currentIndex < _chapters.length - 1 ? _nextChapter : null,
            ),
          ],
        ),
      ),
    );
  }

  Color? _parseHexColor(String hex) {
    if (hex.isEmpty) return null;
    var h = hex.replaceFirst('#', '');
    if (h.length == 6) h = 'FF$h';
    return Color(int.tryParse(h, radix: 16));
  }
}
