import 'package:flutter/material.dart';

import '../../book_source/models/book_source.dart';
import '../../book_source/models/books.dart';
import '../../book_source/services/book_source_service.dart';
import '../../book_source/services/search_service.dart';
import '../book/book_detail_page.dart';
import '../book_source/book_source_page.dart';
import '../search/search_page.dart';

/// 发现页（对应官方 fragment_explore）。
///
/// 顶部搜索入口 + 分组筛选；主体按书源分组，每个启用“发现地址”的书源
/// 展开后拉取其推荐/分类列表（懒加载、带缓存），点击书籍进入详情。
class ExplorePage extends StatefulWidget {
  const ExplorePage({super.key});

  @override
  State<ExplorePage> createState() => _ExplorePageState();
}

class _ExplorePageState extends State<ExplorePage> {
  String _group = '全部';

  List<BookSource> get _sources {
    final all = BookSourceService.instance.sources
        .where((s) => s.isExploreSource)
        .toList();
    if (_group == '全部') return all;
    return all.where((s) => s.groups.contains(_group)).toList();
  }

  List<String> get _groups {
    final set = <String>{};
    for (final s in BookSourceService.instance.sources) {
      if (!s.isExploreSource) continue;
      set.addAll(s.groups);
    }
    return ['全部', ...set];
  }

  void _openSearch() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const SearchPage()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('发现'),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: '搜索',
            onPressed: _openSearch,
          ),
        ],
      ),
      body: Column(
        children: [
          _searchEntry(context),
          _groupBar(),
          Expanded(child: _buildBody(context)),
        ],
      ),
    );
  }

  Widget _searchEntry(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Card(
        child: ListTile(
          leading: const Icon(Icons.search),
          title: const Text('搜索书籍'),
          subtitle: const Text('跨启用书源聚合搜索'),
          trailing: const Icon(Icons.chevron_right),
          onTap: _openSearch,
        ),
      ),
    );
  }

  Widget _groupBar() {
    final groups = _groups;
    if (groups.length <= 1) return const SizedBox.shrink();
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        children: [
          for (final g in groups)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(g),
                selected: _group == g,
                onSelected: (_) => setState(() => _group = g),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final sources = _sources;
    if (sources.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.explore_outlined, size: 64),
            const SizedBox(height: 12),
            const Text('暂无可发现的书源\n请先导入启用书源'),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const BookSourcePage()),
              ),
              icon: const Icon(Icons.collections_bookmark_outlined),
              label: const Text('去导入书源'),
            ),
          ],
        ),
      );
    }
    // 官方样式：书源分组 + 懒加载书列表。
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 16),
      itemCount: sources.length,
      itemBuilder: (_, i) => _ExploreSection(source: sources[i]),
    );
  }
}

/// 单个书源的发现内容（懒加载 + 缓存 + 失败重试）。
class _ExploreSection extends StatefulWidget {
  const _ExploreSection({required this.source});

  final BookSource source;

  @override
  State<_ExploreSection> createState() => _ExploreSectionState();
}

class _ExploreSectionState extends State<_ExploreSection> {
  List<SearchBook>? _books;
  List<ExploreKind> _kinds = const [];
  bool _loading = false;
  bool _loadingKind = false;
  String? _error;

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _books = null;
      _kinds = const [];
    });
    try {
      final outcome = await SearchService.instance.explore(widget.source);
      if (!mounted) return;
      setState(() {
        if (outcome.hasKinds) {
          _kinds = outcome.kinds;
          _books = null;
        } else {
          _books = outcome.books;
        }
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '加载失败：$e';
      });
    }
  }

  Future<void> _openKind(ExploreKind kind) async {
    setState(() {
      _loadingKind = true;
      _error = null;
      _books = kind == _selectedKind ? null : _books;
    });
    try {
      final list =
          await SearchService.instance.exploreAt(widget.source, kind.url);
      if (!mounted) return;
      setState(() {
        _books = list;
        _loadingKind = false;
        _selectedKind = kind;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingKind = false;
        _error = '加载失败：$e';
      });
    }
  }

  ExploreKind? _selectedKind;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          dense: true,
          leading: const Icon(Icons.rss_feed, size: 20),
          title: Text(widget.source.bookSourceName,
              style: theme.textTheme.titleSmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
          trailing: _loading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : IconButton(
                  icon: const Icon(Icons.refresh, size: 20),
                  tooltip: '刷新',
                  onPressed: _load,
                ),
          onTap: _load,
        ),
        const Divider(height: 1),
        _buildKindsBar(context),
        _buildContent(context),
      ],
    );
  }

  Widget _buildKindsBar(BuildContext context) {
    if (_kinds.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        children: [
          for (final k in _kinds)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(k.title,
                    style: Theme.of(context).textTheme.bodySmall),
                selected: _selectedKind == k,
                onSelected: (_) => _openKind(k),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    final books = _books;
    // 加载中 / 正在加载某个子分类
    if ((_loading && books == null) || (_loadingKind && books == null)) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (books == null) {
      // 尚未点击展开；仅当没有子分类时才提示点击展开
      final hint = _kinds.isNotEmpty
          ? '选择上方分类浏览内容'
          : (_error ?? '点击书源展开推荐内容');
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
        child: Row(
          children: [
            Expanded(
              child: Text(
                hint,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            if (_error != null)
              TextButton(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }
    if (books.isEmpty) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(16, 4, 16, 12),
        child: Text('该源暂无发现内容'),
      );
    }
    return SizedBox(
      height: 176,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        itemCount: books.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (_, i) => _BookCard(book: books[i]),
      ),
    );
  }
}

/// 横向书籍卡片（封面 + 书名）。
class _BookCard extends StatelessWidget {
  const _BookCard({required this.book});

  final SearchBook book;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.surfaceContainerHighest;
    return InkWell(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => BookDetailPage(flow: book)),
      ),
      child: SizedBox(
        width: 96,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: SizedBox(
                width: 96,
                height: 132,
                child: book.coverUrl == null || book.coverUrl!.isEmpty
                    ? Container(
                        color: color,
                        child: const Icon(Icons.menu_book_outlined),
                      )
                    : Image.network(
                        book.coverUrl!,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => Container(
                          color: color,
                          child: const Icon(Icons.menu_book_outlined),
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              book.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
