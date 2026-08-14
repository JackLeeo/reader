// 书籍详情页
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/book.dart';
import '../../models/book_source.dart';
import '../../models/chapter.dart';
import '../../models/shelf_book.dart';
import '../../services/book_source_service.dart';
import '../../services/reader_service.dart';
import '../../services/shelf_service.dart';
import '../../utils/extensions.dart';
import '../../utils/log.dart';
import '../../widgets/book_cover.dart';
import '../../widgets/empty_state.dart';
import 'chapter_list_page.dart';
import '../reader/reader_page.dart';

class BookDetailPage extends StatefulWidget {
  final Book book;
  final BookSource? source; // 来自搜索结果时可能未传
  final bool fromShelf;

  const BookDetailPage({
    super.key,
    required this.book,
    this.source,
    this.fromShelf = false,
  });

  @override
  State<BookDetailPage> createState() => _BookDetailPageState();
}

class _BookDetailPageState extends State<BookDetailPage> {
  final _reader = ReaderService();

  Book? _book;
  List<Chapter> _chapters = [];
  bool _loading = false;
  bool _loadingToc = false;
  String? _error;

  BookSource? _source;

  @override
  void initState() {
    super.initState();
    _book = widget.book;
    _source = widget.source ?? _findSource();
    _load();
  }

  BookSource? _findSource() {
    final svc = context.read<BookSourceService>();
    return svc.findById(widget.book.sourceId);
  }

  Future<void> _load() async {
    if (_source == null) {
      setState(() => _error = '书源不可用');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final info = await _reader.getBookInfo(_source!, widget.book);
      if (!mounted) return;
      setState(() {
        _book = info;
        _loading = false;
      });
      _loadToc();
    } catch (e, st) {
      Log.e('加载详情失败', error: e, stack: st);
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _loadToc() async {
    if (_source == null || _book == null) return;
    setState(() {
      _loadingToc = true;
    });
    try {
      final chapters = await _reader.getToc(_source!, _book!);
      if (!mounted) return;
      setState(() {
        _chapters = chapters;
        _loadingToc = false;
      });
    } catch (e, st) {
      Log.e('加载目录失败', error: e, stack: st);
      if (!mounted) return;
      setState(() {
        _loadingToc = false;
      });
    }
  }

  Future<void> _startReading({int chapterIndex = 0}) async {
    if (_book == null) return;
    if (_chapters.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('目录尚未加载完成，请稍候')),
      );
      return;
    }

    // 添加到书架
    final shelf = context.read<ShelfService>();
    if (!shelf.contains(_book!.id)) {
      await shelf.add(ShelfBook(
        book: _book!,
        totalChapters: _chapters.length,
      ));
    }

    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => ReaderPage(
          book: _book!,
          chapters: _chapters,
          startChapter: chapterIndex,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final book = _book;
    if (book == null) {
      return Scaffold(
        appBar: AppBar(),
        body: _error != null
            ? EmptyState(
                icon: Icons.error_outline,
                message: '加载失败',
                hint: _error,
                action: FilledButton(onPressed: _load, child: const Text('重试')),
              )
            : const Center(child: CircularProgressIndicator()),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(book.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            icon: const Icon(Icons.menu_book),
            tooltip: '章节目录',
            onPressed: _chapters.isEmpty
                ? null
                : () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ChapterListPage(
                          book: book,
                          chapters: _chapters,
                          onTapChapter: (idx) {
                            Navigator.pop(context);
                            _startReading(chapterIndex: idx);
                          },
                        ),
                      ),
                    );
                  },
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      BookCover(
                        coverUrl: book.coverUrl,
                        title: book.name,
                        author: book.author,
                        width: 100,
                        height: 140,
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              book.name,
                              style: context.textStyles.titleLarge?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                            ),
                            const SizedBox(height: 8),
                            if (book.author.isNotEmpty)
                              Text('作者: ${book.author}',
                                  style: context.textStyles.bodyMedium),
                            if (book.kind.isNotEmpty)
                              Text('类型: ${book.kind}',
                                  style: context.textStyles.bodySmall,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis),
                            if (book.wordCount.isNotEmpty)
                              Text('字数: ${book.wordCount}',
                                  style: context.textStyles.bodySmall),
                            const SizedBox(height: 6),
                            Text('来源: ${book.sourceName}',
                                style: context.textStyles.bodySmall),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (book.lastChapter.isNotEmpty)
                    Text('最新: ${book.lastChapter}',
                        style: context.textStyles.bodyMedium),
                  const SizedBox(height: 16),
                  Text('简介',
                      style: context.textStyles.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  Text(
                    book.intro.isEmpty ? '暂无简介' : book.intro,
                    style: context.textStyles.bodyMedium?.copyWith(height: 1.6),
                  ),
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _loadingToc ? null : () => _startReading(),
                          icon: const Icon(Icons.play_arrow),
                          label: Text(_loadingToc ? '加载目录中…' : '开始阅读'),
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton.filledTonal(
                        onPressed: () => _addToShelf(),
                        icon: const Icon(Icons.bookmark_add_outlined),
                        tooltip: '加入书架',
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (_loadingToc)
                    const Center(
                      child: Padding(
                        padding: EdgeInsets.all(16),
                        child: CircularProgressIndicator(),
                      ),
                    )
                  else if (_chapters.isNotEmpty)
                    Text('共 ${_chapters.length} 章',
                        style: context.textStyles.bodySmall),
                ],
              ),
            ),
    );
  }

  Future<void> _addToShelf() async {
    if (_book == null) return;
    final shelf = context.read<ShelfService>();
    if (shelf.contains(_book!.id)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已在书架中')),
      );
      return;
    }
    await shelf.add(ShelfBook(
      book: _book!,
      totalChapters: _chapters.length,
    ));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已加入书架')),
    );
  }
}
