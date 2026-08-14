// 发现页 - 浏览书源分类
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/book_source.dart';
import '../../services/book_source_service.dart';
import '../../services/reader_service.dart';
import '../../utils/extensions.dart';
import '../../widgets/book_card.dart';
import '../../widgets/empty_state.dart';
import '../book/book_detail_page.dart';

class ExplorePage extends StatefulWidget {
  const ExplorePage({super.key});

  @override
  State<ExplorePage> createState() => _ExplorePageState();
}

class _ExplorePageState extends State<ExplorePage> {
  final _reader = ReaderService();

  BookSource? _currentSource;
  ExploreCategory? _currentCategory;
  bool _loading = false;
  String? _error;
  List _books = [];
  int _page = 1;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _autoSelect());
  }

  void _autoSelect() {
    final sources = context.read<BookSourceService>().enabledSources;
    if (sources.isEmpty) return;
    final first = sources.first;
    final cats = first.exploreCategories;
    if (cats.isEmpty) return;
    setState(() {
      _currentSource = first;
      _currentCategory = cats.first;
    });
    _load();
  }

  Future<void> _load({bool reset = true}) async {
    if (_currentSource == null || _currentCategory == null) return;
    setState(() {
      _loading = true;
      _error = null;
      if (reset) {
        _books = [];
        _page = 1;
      }
    });
    try {
      final result = await _reader.explore(
        _currentSource!,
        _currentCategory!.url,
        page: _page,
      );
      if (!mounted) return;
      setState(() {
        _books = result.books;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('发现'),
        centerTitle: false,
        bottom: _buildSelectorBar(context),
      ),
      body: _buildBody(),
    );
  }

  PreferredSizeWidget? _buildSelectorBar(BuildContext context) {
    return PreferredSize(
      preferredSize: const Size.fromHeight(96),
      child: Consumer<BookSourceService>(
        builder: (context, svc, _) {
          if (svc.enabledSources.isEmpty) {
            return const SizedBox.shrink();
          }
          return Container(
            color: context.colors.surface,
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final src in svc.enabledSources)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: ChoiceChip(
                            label: Text(src.bookSourceName),
                            selected: _currentSource?.id == src.id,
                            onSelected: (v) {
                              if (!v) return;
                              setState(() {
                                _currentSource = src;
                                _currentCategory = src.exploreCategories.isNotEmpty
                                    ? src.exploreCategories.first
                                    : null;
                              });
                              _load();
                            },
                          ),
                        ),
                    ],
                  ),
                ),
                if (_currentSource != null && _currentSource!.exploreCategories.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final cat in _currentSource!.exploreCategories)
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: FilterChip(
                              label: Text(cat.title),
                              selected: _currentCategory?.url == cat.url,
                              onSelected: (v) {
                                if (!v) return;
                                setState(() => _currentCategory = cat);
                                _load();
                              },
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildBody() {
    if (_currentSource == null) {
      return const EmptyState(
        icon: Icons.source_outlined,
        message: '暂无可用书源',
        hint: '请到「书源」页启用书源',
      );
    }
    if (_currentSource!.exploreCategories.isEmpty) {
      return const EmptyState(
        icon: Icons.category_outlined,
        message: '当前书源未配置发现页',
        hint: '可到搜索页手动搜索',
      );
    }
    if (_loading && _books.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _books.isEmpty) {
      return EmptyState(
        icon: Icons.error_outline,
        message: '加载失败',
        hint: _error,
        action: FilledButton.tonal(
          onPressed: () => _load(),
          child: const Text('重试'),
        ),
      );
    }
    if (_books.isEmpty) {
      return const EmptyState(
        icon: Icons.search_off,
        message: '该分类暂无书籍',
      );
    }
    return RefreshIndicator(
      onRefresh: () => _load(),
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: _books.length,
        separatorBuilder: (_, __) => const Divider(height: 1, indent: 80),
        itemBuilder: (context, i) {
          final book = _books[i];
          return BookCard(
            book: book,
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => BookDetailPage(book: book),
                ),
              );
            },
            subtitle: book.lastChapter.isNotEmpty
                ? '${book.lastChapter} · ${book.sourceName}'
                : book.sourceName,
          );
        },
      ),
    );
  }
}
