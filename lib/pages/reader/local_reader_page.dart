// 本地TXT阅读器
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/bookmark.dart';
import '../../models/local_book.dart';
import '../../models/reading_stats.dart';
import '../../services/bookmark_service.dart';
import '../../services/local_book_service.dart';
import '../../services/settings_service.dart';
import '../../services/stats_service.dart';
import '../../widgets/empty_state.dart';
import 'bookmark_list_sheet.dart';
import 'reader_settings_sheet.dart';

class LocalReaderPage extends StatefulWidget {
  final LocalBook book;
  const LocalReaderPage({super.key, required this.book});

  @override
  State<LocalReaderPage> createState() => _LocalReaderPageState();
}

class _LocalReaderPageState extends State<LocalReaderPage> {
  final _scroll = ScrollController();
  List<String> _chapters = [];
  List<String> _titles = [];
  int _currentIndex = 0;
  String _content = '';
  bool _loading = true;
  bool _showChrome = true;
  DateTime _sessionStart = DateTime.now();
  int _initialChars = 0;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.book.lastChapterIndex;
    _sessionStart = DateTime.now();
    _scroll.addListener(() {
      _saveProgress();
    });
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _load();
  }

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _scroll.dispose();
    _recordSession();
    super.dispose();
  }

  Future<void> _load() async {
    final svc = context.read<LocalBookService>();
    final content = await svc.readContent(widget.book);
    if (!mounted) return;
    setState(() {
      _chapters = svc.splitChapters(content);
      _titles =
          _chapters.asMap().entries.map((e) => svc.chapterTitle(e.value, e.key)).toList();
      _loading = false;
    });
    _setCurrent();
  }

  void _setCurrent() {
    if (_chapters.isEmpty) {
      _content = '（空内容）';
      return;
    }
    if (_currentIndex < 0) _currentIndex = 0;
    if (_currentIndex >= _chapters.length) _currentIndex = _chapters.length - 1;
    _content = _chapters[_currentIndex];
    _initialChars = _content.length;
  }

  void _saveProgress() {
    final svc = context.read<LocalBookService>();
    svc.updateProgress(
      widget.book.id,
      _currentIndex,
      _scroll.position.pixels.toInt(),
    );
  }

  void _nextChapter() {
    if (_currentIndex >= _chapters.length - 1) return;
    setState(() {
      _currentIndex++;
      _setCurrent();
    });
    _scroll.jumpTo(widget.book.lastOffset.toDouble());
  }

  void _prevChapter() {
    if (_currentIndex <= 0) return;
    setState(() {
      _currentIndex--;
      _setCurrent();
    });
    _scroll.jumpTo(0);
  }

  void _toggleChrome() {
    setState(() => _showChrome = !_showChrome);
    if (_showChrome) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    } else {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
  }

  void _addBookmark() async {
    if (_chapters.isEmpty) return;
    final offset = _scroll.position.pixels.toInt();
    final snippet = _content.length > 50
        ? _content.substring(0, 50)
        : _content;
    final b = Bookmark(
      bookId: 'local_${widget.book.id}',
      chapterIndex: _currentIndex,
      chapterTitle: _titles[_currentIndex],
      offset: offset,
      snippet: snippet,
    );
    await context.read<BookmarkService>().add(b);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已添加书签'), duration: Duration(seconds: 1)),
    );
  }

  void _recordSession() {
    if (_content.isEmpty) return;
    final delta = _content.length - _initialChars;
    _initialChars = _content.length;
    if (delta <= 0) return;
    final dur = DateTime.now().difference(_sessionStart);
    if (dur.inSeconds < 5) return;
    final session = ReadingSession(
      bookId: 'local_${widget.book.id}',
      date: DateTime.now(),
      duration: dur,
      charsRead: delta,
    );
    context.read<StatsService>().record(session);
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>();
    final bgColor = _parseHexColor(settings.bgColor) ?? const Color(0xFFFFF8E1);
    final textColor = _parseHexColor(settings.textColor) ?? const Color(0xFF3E2723);
    return Scaffold(
      backgroundColor: bgColor,
      body: GestureDetector(
        onTap: _toggleChrome,
        child: SafeArea(
          child: Column(
            children: [
              if (_showChrome) _buildTopBar(textColor),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _chapters.isEmpty
                        ? const EmptyState(
                            icon: Icons.menu_book,
                            message: '未找到章节',
                          )
                        : _buildContent(textColor, settings),
              ),
              if (_showChrome) _buildBottomBar(textColor),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar(Color textColor) {
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
              child: Text(
                widget.book.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
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
                    bookId: 'local_${widget.book.id}',
                    onTap: (b) {
                      Navigator.pop(ctx);
                      if (b.chapterIndex < 0 ||
                          b.chapterIndex >= _chapters.length) {
                        return;
                      }
                      setState(() {
                        _currentIndex = b.chapterIndex;
                        _setCurrent();
                      });
                      _scroll.jumpTo(b.offset.toDouble());
                    },
                  ),
                );
              },
            ),
            IconButton(
              icon: const Icon(Icons.list, size: 22),
              tooltip: '目录',
              onPressed: () => _showChapterList(),
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

  void _showChapterList() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return DraggableScrollableSheet(
          initialChildSize: 0.6,
          minChildSize: 0.3,
          maxChildSize: 0.95,
          expand: false,
          builder: (c, controller) {
            return Column(
              children: [
                Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(top: 8, bottom: 8),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      const Text('目录',
                          style: TextStyle(
                              fontSize: 18, fontWeight: FontWeight.bold)),
                      const Spacer(),
                      Text('共 ${_chapters.length} 章'),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView.builder(
                    controller: controller,
                    itemCount: _chapters.length,
                    itemBuilder: (c, i) {
                      return ListTile(
                        title: Text(_titles[i],
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        trailing: i == _currentIndex
                            ? const Icon(Icons.bookmark, size: 18)
                            : null,
                        onTap: () {
                          Navigator.pop(ctx);
                          setState(() {
                            _currentIndex = i;
                            _setCurrent();
                          });
                          _scroll.jumpTo(0);
                        },
                      );
                    },
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildContent(Color textColor, SettingsService settings) {
    if (_chapters.isEmpty) {
      return const SizedBox.shrink();
    }
    return ListView(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 80),
      children: [
        Text(
          _titles[_currentIndex],
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

  Widget _buildBottomBar(Color textColor) {
    return Container(
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
    );
  }

  Color? _parseHexColor(String hex) {
    if (hex.isEmpty) return null;
    var h = hex.replaceFirst('#', '');
    if (h.length == 6) h = 'FF$h';
    return Color(int.tryParse(h, radix: 16) ?? 0xFF000000);
  }
}
