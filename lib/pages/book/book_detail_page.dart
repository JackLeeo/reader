import 'dart:math';

import 'package:flutter/material.dart';

import '../../book_source/models/books.dart';
import '../../book_source/services/book_service.dart';
import '../../book_source/services/cover_service.dart';
import '../../book_source/services/shelf_service.dart';
import '../../book_source/services/switch_source_service.dart';
import '../../widgets/change_cover_dialog.dart';
import '../../widgets/cover_image.dart';
import '../reader/reader_page.dart';
import 'book_edit_page.dart';

/// 书籍详情页。
///
/// 加载书籍详情与目录，展示简介，提供“开始阅读 / 目录”入口。
class BookDetailPage extends StatefulWidget {
  const BookDetailPage({super.key, required this.flow});

  final SearchBook flow;

  @override
  State<BookDetailPage> createState() => _BookDetailPageState();
}

class _BookDetailPageState extends State<BookDetailPage> {
  static final BookService _service = BookService();

  Book? _book;
  List<BookChapter>? _chapters;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final book = await _service.getBook(widget.flow);
      if (!mounted) return;
      if (book == null) {
        setState(() {
          _loading = false;
          _error = '书籍详情解析失败，可能是书源规则不完整或页面结构变化';
        });
        return;
      }
      book.tocUrl ??= book.bookUrl;
      final chapters = await _service.getToc(book);
      if (!mounted) return;
      setState(() {
        _book = book;
        _chapters = chapters;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '加载出错：$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.flow.name),
        actions: [
          IconButton(
            icon: const Icon(Icons.update_outlined),
            tooltip: '检查更新',
            onPressed: _book == null ? null : _checkUpdate,
          ),
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            tooltip: '编辑书籍',
            onPressed: _book == null ? null : _openEdit,
          ),
          IconButton(
            icon: const Icon(Icons.swap_horiz),
            tooltip: '换源',
            onPressed: _book == null ? null : _showSwitchSource,
          ),
          IconButton(
            icon: const Icon(Icons.bookmark_add_outlined),
            tooltip: '收藏到书架',
            onPressed: _book == null ? null : _addToShelf,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  /// 编辑书籍：需先收藏到书架（本地元数据编辑，官方 `ui/book/info/edit`）。
  void _openEdit() {
    final book = _book!;
    final shelf = ShelfService.instance
        .findByKey('${book.sourceTag}|${book.bookUrl}');
    if (shelf == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先收藏到书架后再编辑')),
      );
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => BookEditPage(book: shelf),
      ),
    ).then((edited) {
      if (edited == true && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已保存书籍信息')),
        );
      }
    });
  }

  /// 换源：搜索同名书籍供切换。
  Future<void> _showSwitchSource() async {
    final book = _book!;
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
            ListTile(
              leading: const Icon(Icons.casino_outlined),
              title: const Text('随机换源'),
              subtitle: Text('随机抽一个 ${candidates.length} 源之一',
                  style: Theme.of(ctx).textTheme.bodySmall),
              onTap: () => Navigator.pop(ctx,
                  candidates[Random().nextInt(candidates.length)]),
            ),
            for (final c in candidates)
              ListTile(
                leading: const Icon(Icons.menu_book_outlined),
                title: Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text('来源：${c.origin}',
                    style: Theme.of(ctx).textTheme.bodySmall),
                onTap: () => Navigator.pop(ctx, c),
              ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    // 切到新源打开其详情页
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => BookDetailPage(flow: picked)),
    );
  }

  /// 检查最新目录，判断是否已更新到最新章节。
  Future<void> _checkUpdate() async {
    final book = _book!;
    final before = book.lastChapter;
    try {
      final chapters = await _service.getToc(book);
      if (!mounted) return;
      if (chapters.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('检查更新失败（未解析到目录）')),
        );
        return;
      }
      // 更新目录展示
      setState(() {
        _chapters = chapters;
        book.lastChapter = chapters.last.title;
      });
      final latest = chapters.last.title;
      if (before == null ||
          before.isEmpty ||
          before == latest ||
          latest.contains(before)) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已是最新（共 ${chapters.length} 章）')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('检测到更新：$latest')),
        );
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('检查更新失败')),
      );
    }
  }

  /// 收藏到书架（保留阅读进度入口）。
  void _addToShelf() {
    final book = _book!;
    final key = '${book.sourceTag}|${book.bookUrl}';
    final existing = ShelfService.instance.findByKey(key);
    ShelfService.instance.addBook(ShelfBook(
      name: book.name,
      author: book.author,
      coverUrl: book.coverUrl,
      bookUrl: book.bookUrl,
      origin: book.origin,
      sourceTag: book.sourceTag,
      intro: book.intro,
      lastChapter: book.lastChapter,
      lastReadIndex: existing?.lastReadIndex ?? 0,
      lastReadChapter: existing?.lastReadChapter ?? '',
      readingProgress: existing?.readingProgress ?? 0,
      addTime: existing?.addTime ?? DateTime.now().millisecondsSinceEpoch,
    ));
    ShelfService.instance.save();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已加入书架')),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(onPressed: _load, child: const Text('重试')),
            ],
          ),
        ),
      );
    }
    final book = _book!;
    final chapters = _chapters ?? const <BookChapter>[];
    final hasToc = chapters.isNotEmpty;

    return Column(
      children: [
        Expanded(
          child: ListView(
            children: [
              _InfoCard(
                book: book,
                bookKey: '${book.sourceTag}|${book.bookUrl}',
                onCoverChanged: () => setState(() {}),
              ),
              if (book.intro != null && book.intro!.trim().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('简介', style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 8),
                      Text(book.intro!),
                    ],
                  ),
                ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Text('目录', style: Theme.of(context).textTheme.titleMedium),
                    const Spacer(),
                    if (hasToc)
                      Text('共 ${chapters.length} 章',
                          style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
              if (hasToc)
                ...chapters.take(20).map(
                      (c) => ListTile(
                        dense: true,
                        title: Text(c.title,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        onTap: () => _openReader(chapters, chapters.indexOf(c)),
                      ),
                    ),
              if (hasToc && chapters.length > 20)
                TextButton.icon(
                  onPressed: () => _showFullToc(chapters),
                  icon: const Icon(Icons.list),
                  label: Text('查看全部目录（${chapters.length} 章）'),
                ),
              if (!hasToc)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text('未获取到目录，可能是书源目录规则不匹配',
                      style: Theme.of(context).textTheme.bodySmall),
                ),
            ],
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: hasToc && chapters.isNotEmpty
                    ? () => _openReader(chapters, 0)
                    : null,
                icon: const Icon(Icons.play_arrow),
                label: Text(hasToc ? '开始阅读' : '目录为空，暂时无法阅读'),
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _openReader(List<BookChapter> chapters, int index) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ReaderPage(
          book: _book!,
          chapters: chapters,
          initialIndex: index,
        ),
      ),
    );
  }

  /// 展示完整目录：卷标题(加粗分隔)、VIP/付费章节(锁标)，点击跳转阅读。
  void _showFullToc(List<BookChapter> chapters) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.7,
          maxChildSize: 0.92,
          builder: (_, scroll) => Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text('目录（共 ${chapters.length} 项）',
                    style: Theme.of(ctx).textTheme.titleMedium),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.builder(
                  controller: scroll,
                  itemCount: chapters.length,
                  itemBuilder: (_, i) {
                    final c = chapters[i];
                    if (c.isVolume) {
                      return ListTile(
                        dense: true,
                        selected: true,
                        title: Text(c.title,
                            maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: Theme.of(ctx).textTheme.titleSmall
                                ?.copyWith(fontWeight: FontWeight.bold)),
                      );
                    }
                    final locked = c.isVip || c.isPay;
                    return ListTile(
                      dense: true,
                      leading: locked
                          ? const Icon(Icons.lock_outline, size: 18)
                          : null,
                      title: Text(c.title,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      onTap: () {
                        Navigator.pop(ctx);
                        _openReader(chapters, i);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InfoCard extends StatefulWidget {
  const _InfoCard({
    required this.book,
    required this.bookKey,
    required this.onCoverChanged,
  });

  final Book book;
  final String bookKey;
  final VoidCallback onCoverChanged;

  @override
  State<_InfoCard> createState() => _InfoCardState();
}

class _InfoCardState extends State<_InfoCard> {
  @override
  Widget build(BuildContext context) {
    final book = widget.book;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Stack(
            children: [
              CoverImage(
                bookKey: widget.bookKey,
                fallbackUrl: book.coverUrl,
              ),
              Positioned(
                right: 0,
                bottom: 0,
                child: GestureDetector(
                  onTap: _changeCover,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.85),
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(4),
                      ),
                    ),
                    child: const Icon(Icons.edit_outlined, size: 16),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(book.name,
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                if (book.author != null) Text('作者：${book.author}'),
                if (book.lastChapter != null)
                  Text('最近更新：${book.lastChapter}',
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 4),
                Text('来源：${book.origin}',
                    style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _changeCover() async {
    final result = await showChangeCoverDialog(context);
    if (result == null || !mounted) return;
    await CoverService.instance.setCover(
      widget.bookKey,
      result.remove ? null : result.uri,
    );
    widget.onCoverChanged();
  }
}