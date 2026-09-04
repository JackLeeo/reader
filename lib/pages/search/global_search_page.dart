import 'package:flutter/material.dart';

import '../../book_source/models/books.dart';
import '../../book_source/services/book_cache_service.dart';
import '../../book_source/services/shelf_service.dart';
import '../../local/local_book.dart';
import '../../local/local_book_store.dart';
import '../reader/reader_page.dart';

/// 跨书全文搜索结果。
class GlobalSearchHit {
  GlobalSearchHit({
    required this.book,
    required this.title,
    required this.snippet,
    required this.chapterIndex,
    this.localBook,
  });
  final Book book;
  final String title;
  final String snippet;
  final int chapterIndex;
  final LocalBook? localBook;
}

/// 应用内跨书全文搜索。
///
/// 在【本地书库】与【已缓存正文的可联网书】中检索关键字，结果点击可跳转阅读。
class GlobalSearchPage extends StatefulWidget {
  const GlobalSearchPage({super.key});

  @override
  State<GlobalSearchPage> createState() => _GlobalSearchPageState();
}

class _GlobalSearchPageState extends State<GlobalSearchPage> {
  final TextEditingController _controller = TextEditingController();

  /// 范围：0=全部本地书, 1=仅已缓存正文的网络书, 2=本地书+缓存网络书。
  int _scope = 0;
  bool _searching = false;
  bool _searched = false;
  final List<GlobalSearchHit> _hits = [];

  static const List<String> kScopeNames = ['本地书', '缓存网络书', '本地书+缓存'];

  void _updateScope(int v) {
    setState(() => _scope = v);
    if (_controller.text.trim().isNotEmpty) _run();
  }

  Future<void> _run() async {
    final kw = _controller.text.trim().toLowerCase();
    if (kw.isEmpty) return;
    setState(() {
      _searching = true;
      _hits.clear();
    });

    final results = <GlobalSearchHit>[];
    final scope = _scope;

    // ① 本地书
    if (scope != 1) {
      final locals = await LocalBookStore.instance.loadAll();
      for (final lb in locals) {
        if (lb.name.toLowerCase().contains(kw)) {
          // 书名命中：列出前几章作为入口。
          for (var i = 0; i < lb.chapters.length && i < 5; i++) {
            results.add(GlobalSearchHit(
              book: Book(
                  name: lb.name,
                  author: lb.author,
                  bookUrl: lb.key,
                  origin: '本地',
                  sourceTag: 'local',
                  type: 0),
              title: lb.chapters[i].title.isEmpty
                  ? '第 ${i + 1} 章'
                  : lb.chapters[i].title,
              snippet: '· 书名匹配',
              chapterIndex: i,
              localBook: lb,
            ));
            if (results.length >= 200) break;
          }
        }
        for (var i = 0; i < lb.chapters.length; i++) {
          final c = lb.chapters[i];
          final idx = c.content.toLowerCase().indexOf(kw);
          if (idx < 0) continue;
          final start = idx < 12 ? 0 : idx - 12;
          final end = (start + 60) > c.content.length
              ? c.content.length
              : start + 60;
          results.add(GlobalSearchHit(
            book: Book(
                name: lb.name,
                author: lb.author,
                bookUrl: lb.key,
                origin: '本地',
                sourceTag: 'local',
                type: 0),
            title: c.title.isEmpty ? '第 ${i + 1} 章' : c.title,
            snippet: c.content.substring(start, end),
            chapterIndex: i,
            localBook: lb,
          ));
          if (results.length >= 500) break;
        }
        if (results.length >= 500) break;
      }
    }

    // ② 已缓存正文的网络书
    if (scope != 0) {
      final cache = BookCacheService.instance;
      for (final shelf in ShelfService.instance.books) {
        if (shelf.isLocal) continue;
        final book = Book(
          name: shelf.name,
          author: shelf.author,
          bookUrl: shelf.bookUrl,
          origin: shelf.origin,
          sourceTag: shelf.sourceTag,
          type: 0,
        );
        final ids = cache.cachedChapters(book);
        for (final i in ids) {
          final content = await cache
              .getChapter(book, i, '第 ${i + 1} 章');
          if (content == null || content.body.isEmpty) continue;
          if (content.title.toLowerCase().contains(kw) ||
              content.body.toLowerCase().contains(kw)) {
            final p = content.body.toLowerCase().indexOf(kw);
            final start = p < 12 ? 0 : p - 12;
            final end = (start + 60) > content.body.length
                ? content.body.length
                : start + 60;
            results.add(GlobalSearchHit(
              book: book,
              title: content.title.isEmpty ? '第 ${i + 1} 章' : content.title,
              snippet: content.body.substring(start, end),
              chapterIndex: i,
            ));
            if (results.length >= 500) break;
          }
        }
        if (results.length >= 500) break;
      }
    }

    if (!mounted) return;
    setState(() {
      _searching = false;
      _searched = true;
      _hits.addAll(results);
    });
  }

  void _openHit(GlobalSearchHit h) {
    if (h.localBook != null) {
      final chapters = <BookChapter>[
        for (var i = 0; i < h.localBook!.chapters.length; i++)
          BookChapter(
              title: h.localBook!.chapters[i].title, url: 'local://$i'),
      ];
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ReaderPage(
            book: h.book,
            chapters: chapters,
            initialIndex: h.chapterIndex,
            localBook: h.localBook,
          ),
        ),
      );
      return;
    }
    // 网络书：跳到详情页续读（其内从缓存/网络正文读取）。
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('请在详情页打开该书继续阅读')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('全文搜索'),
        actions: [
          IconButton(
            tooltip: '搜索',
            onPressed: _run,
            icon: const Icon(Icons.search),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    decoration: const InputDecoration(
                      hintText: '搜索书名 / 章节 / 正文内容',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _run(),
                  ),
                ),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                for (var i = 0; i < kScopeNames.length; i++)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: ChoiceChip(
                      label: Text(kScopeNames[i]),
                      selected: _scope == i,
                      onSelected: (_) => _updateScope(i),
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(child: _buildResults()),
        ],
      ),
    );
  }

  Widget _buildResults() {
    if (_searching) return const Center(child: CircularProgressIndicator());
    if (!_searched && _hits.isEmpty) {
      return const Center(child: Text('输入关键字进行跨书全文搜索'));
    }
    if (_hits.isEmpty) return const Center(child: Text('没有匹配到结果'));
    return ListView.separated(
      itemCount: _hits.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final h = _hits[i];
        return ListTile(
          leading: const Icon(Icons.chat_bubble_outline),
          title: Text('${h.book.name} · ${h.title}',
              maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(h.snippet,
              maxLines: 2, overflow: TextOverflow.ellipsis),
          onTap: () => _openHit(h),
        );
      },
    );
  }
}