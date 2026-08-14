// 搜索页 - 多源聚合搜索
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/book.dart';
import '../../models/book_source.dart';
import '../../services/book_source_service.dart';
import '../../services/reader_service.dart';
import '../../utils/extensions.dart';
import '../../utils/log.dart';
import '../../widgets/book_card.dart';
import '../../widgets/empty_state.dart';
import '../book/book_detail_page.dart';

class _SearchHit {
  final Book book;
  final BookSource source;
  _SearchHit(this.book, this.source);
}

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _keywordController = TextEditingController();
  final _reader = ReaderService();
  final _hits = <_SearchHit>[];
  final _sourceDone = <String>{};
  final Map<String, bool> _sourceLoading = {};
  bool _searching = false;
  String _lastKeyword = '';
  Timer? _debounce;

  @override
  void dispose() {
    _keywordController.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), () {
      if (value.trim() == _lastKeyword) return;
      if (value.trim().isNotEmpty) {
        _search(value.trim());
      } else {
        setState(() {
          _hits.clear();
          _searching = false;
          _sourceDone.clear();
          _sourceLoading.clear();
        });
      }
    });
  }

  Future<void> _search(String keyword) async {
    _lastKeyword = keyword;
    setState(() {
      _hits.clear();
      _searching = true;
      _sourceDone.clear();
      _sourceLoading.clear();
    });

    final sources = context.read<BookSourceService>().enabledSources
        .where((s) => s.searchUrl.isNotEmpty)
        .toList();

    if (sources.isEmpty) {
      setState(() => _searching = false);
      return;
    }

    setState(() {
      for (final s in sources) {
        _sourceLoading[s.id] = true;
      }
    });

    // 并发搜索所有源
    await Future.wait(sources.map((src) async {
      try {
        final result = await _reader.search(src, keyword);
        if (!mounted) return;
        setState(() {
          for (final book in result.books) {
            _hits.add(_SearchHit(book, src));
          }
        });
      } catch (e, st) {
        Log.w('搜索源失败 [${src.bookSourceName}]: $e', stack: st);
      } finally {
        if (mounted) {
          setState(() {
            _sourceLoading[src.id] = false;
            _sourceDone.add(src.id);
            if (_sourceDone.length == sources.length) {
              _searching = false;
            }
          });
        }
      }
    }));

    if (mounted) setState(() => _searching = false);
  }

  @override
  Widget build(BuildContext context) {
    final sources = context.watch<BookSourceService>().enabledSources
        .where((s) => s.searchUrl.isNotEmpty)
        .toList();

    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _keywordController,
          decoration: const InputDecoration(
            hintText: '搜索书名/作者',
            border: InputBorder.none,
          ),
          onChanged: _onChanged,
          onSubmitted: (v) {
            if (v.trim().isNotEmpty) _search(v.trim());
          },
          textInputAction: TextInputAction.search,
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: () {
              final v = _keywordController.text.trim();
              if (v.isNotEmpty) _search(v);
            },
          ),
        ],
      ),
      body: Column(
        children: [
          if (_searching) _buildProgressBar(sources),
          Expanded(
            child: _hits.isEmpty && !_searching
                ? const EmptyState(
                    icon: Icons.search,
                    message: '输入关键词开始搜索',
                    hint: '可同时搜索多个书源，结果自动合并',
                  )
                : _hits.isEmpty && !_searching
                    ? const EmptyState(
                        icon: Icons.search_off,
                        message: '没有找到结果',
                        hint: '尝试更换关键词或更换书源',
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        itemCount: _hits.length,
                        separatorBuilder: (_, __) =>
                            const Divider(height: 1, indent: 80),
                        itemBuilder: (context, i) {
                          final hit = _hits[i];
                          return BookCard(
                            book: hit.book,
                            onTap: () {
                              Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => BookDetailPage(
                                    book: hit.book,
                                    source: hit.source,
                                  ),
                                ),
                              );
                            },
                            subtitle: hit.source.bookSourceName,
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildProgressBar(List<BookSource> sources) {
    final done = _sourceDone.length;
    final total = sources.length;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: context.colors.surfaceContainerHighest,
      child: Row(
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '正在搜索: $done/$total',
              style: context.textStyles.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}
