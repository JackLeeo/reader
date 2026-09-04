import 'package:flutter/material.dart';

import '../../book_source/models/books.dart';
import '../../book_source/services/search_service.dart';
import '../book/book_detail_page.dart';

/// 聚合搜索页。
///
/// 输入关键字后对全部启用的文本书源串行搜索，结果流式合并上屏。
class SearchPage extends StatefulWidget {
  const SearchPage({super.key, this.initialText});

  /// 初始关键字（打开即搜索，如划词跳转）。
  final String? initialText;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final TextEditingController _controller = TextEditingController();
  List<SearchBook> _books = [];
  final Set<String> _origins = {};
  bool _searching = false;
  int _done = 0;
  int _total = 0;
  String _keyword = '';

  @override
  void initState() {
    super.initState();
    final t = widget.initialText?.trim() ?? '';
    if (t.isNotEmpty) {
      _controller.text = t;
      WidgetsBinding.instance.addPostFrameCallback((_) => _search());
    }
  }

  Future<void> _search() async {
    final keyword = _controller.text.trim();
    if (keyword.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _searching = true;
      _books = [];
      _origins.clear();
      _done = 0;
      _total = 0;
      _keyword = keyword;
    });
    await SearchService.instance.searchAll(keyword,
        onResult: (origin, books, done, total) {
      if (!mounted) return;
      _origins.add(origin);
      _done = done;
      _total = total;
      final merged = SearchService.mergeResults(_books, books, keyword);
      setState(() => _books = merged);
    });
    if (!mounted) return;
    setState(() => _searching = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => _search(),
          decoration: InputDecoration(
            hintText: '搜索书名/作者',
            border: InputBorder.none,
            suffixIcon: IconButton(
              icon: Icon(_searching ? Icons.hourglass_top : Icons.search),
              onPressed: _searching ? null : _search,
            ),
          ),
        ),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_searching && _books.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_books.isEmpty) {
      return Center(
        child: Text(_searching ? '正在搜索…' : '输入关键字开始搜索'),
      );
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(
            children: [
              Text(
                '“$_keyword” 共 ${_books.length} 条 · ${_origins.length} 个书源'
                '${_searching && _total > 0 ? '（已搜 $_done/$_total）' : ''}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (_searching && _total > 0) ...[
                const SizedBox(width: 8),
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    value: _total == 0 ? null : (_done / _total),
                  ),
                ),
              ],
            ],
          ),
        ),
        if (_searching && _total > 0)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
            child: LinearProgressIndicator(
              value: _done / _total,
              minHeight: 2,
            ),
          ),
        Expanded(
          child: ListView.builder(
            itemCount: _books.length,
            itemBuilder: (_, i) {
              final b = _books[i];
              return _SearchResultTile(
                book: b,
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => BookDetailPage(flow: b)),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _SearchResultTile extends StatelessWidget {
  const _SearchResultTile({required this.book, required this.onTap});

  final SearchBook book;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: _Cover(
        url: book.coverUrl,
        fallback: const Icon(Icons.menu_book_outlined),
      ),
      title: Text(book.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (book.author != null)
            Text('作者：${book.author}', maxLines: 1, overflow: TextOverflow.ellipsis),
          Text(
            '来源：${book.origin}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
      onTap: onTap,
    );
  }
}

/// 封面占位（跨平台版封面网络加载阶段3接入，此处先显示图标）。
class _Cover extends StatelessWidget {
  const _Cover({required this.url, required this.fallback});

  final String? url;
  final Widget fallback;

  @override
  Widget build(BuildContext context) {
    final colored = IconTheme(
      data: const IconThemeData(size: 40),
      child: fallback,
    );
    return Container(
      width: 48,
      height: 64,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: colored,
    );
  }
}