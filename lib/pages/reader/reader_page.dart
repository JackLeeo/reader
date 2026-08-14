// 阅读器页面 - 核心阅读界面
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/book.dart';
import '../../models/chapter.dart';
import '../../models/history_item.dart';
import '../../models/shelf_book.dart';
import '../../services/book_source_service.dart';
import '../../services/history_service.dart';
import '../../services/reader_service.dart';
import '../../services/settings_service.dart';
import '../../services/shelf_service.dart';
import '../../utils/extensions.dart';
import '../../utils/log.dart';
import '../../widgets/empty_state.dart';
import '../book/chapter_list_page.dart';
import 'reader_settings_sheet.dart';

class ReaderPage extends StatefulWidget {
  final Book book;
  final List<Chapter>? chapters; // 可选：已加载的章节列表
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
  final _reader = ReaderService();
  final _scrollController = ScrollController();

  List<Chapter> _chapters = [];
  int _currentIndex = 0;
  String _content = '';
  bool _loading = false;
  String? _error;

  bool _showChrome = true;
  bool _nextChapterLoading = false;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.startChapter;
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
    super.dispose();
  }

  Future<void> _loadChapters() async {
    final src = context.read<BookSourceService>().findById(widget.book.sourceId);
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
    if (_chapters.isEmpty || _currentIndex < 0 || _currentIndex >= _chapters.length) {
      return;
    }
    final src = context.read<BookSourceService>().findById(widget.book.sourceId);
    if (src == null) return;

    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final ch = _chapters[_currentIndex];
      final content = await _reader.getContent(src, ch.url);
      if (!mounted) return;
      setState(() {
        _content = content.isEmpty ? '(本章无内容)' : content;
        _loading = false;
      });
      _scrollController.jumpTo(0);
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
    // 接近底部时自动加载下一章
    if (pos.pixels > pos.maxScrollExtent - 200) {
      _autoLoadNext();
    }
    // 记录滚动位置
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

  Future<bool> _onWillPop() async {
    _saveProgress();
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>();
    final bgColor = _parseHexColor(settings.bgColor) ?? const Color(0xFFFFF8E1);
    final textColor = _parseHexColor(settings.textColor) ?? const Color(0xFF3E2723);

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
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
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
              child: Text(
                widget.book.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
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

  Widget _buildContent(Color bgColor, Color textColor, SettingsService settings) {
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
