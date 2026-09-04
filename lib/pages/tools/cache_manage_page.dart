import 'package:flutter/material.dart';

import '../../book_source/models/books.dart';
import '../../book_source/services/book_cache_service.dart';
import '../../book_source/services/comic_offline_service.dart';
import '../../book_source/services/shelf_service.dart';

/// 缓存管理。对应官方 `ui/book/cache`：查看/删除已缓存的文本书与漫画离线章。
class CacheManagePage extends StatefulWidget {
  const CacheManagePage({super.key});

  @override
  State<CacheManagePage> createState() => _CacheManagePageState();
}

class _CacheManagePageState extends State<CacheManagePage> {
  int _totalText = 0;
  int _totalComic = 0;

  @override
  void initState() {
    super.initState();
    _recalc();
  }

  void _recalc() {
    var text = 0;
    var comic = 0;
    for (final shelf in ShelfService.instance.books) {
      final book = _bookOf(shelf);
      text += BookCacheService.instance.cachedChapters(book).length;
      comic += ComicOfflineService.instance.downloadedChapters(book).length;
    }
    _totalText = text;
    _totalComic = comic;
  }

  Book _bookOf(ShelfBook s) => Book(
        name: s.name,
        bookUrl: s.bookUrl,
        origin: s.origin,
        sourceTag: s.sourceTag,
        type: 0,
      );

  @override
  Widget build(BuildContext context) {
    final shelfBooks = ShelfService.instance.books;
    final rows = <_Row>[];
    for (final s in shelfBooks) {
      final book = _bookOf(s);
      final textChapters = BookCacheService.instance.cachedChapters(book);
      final comicChapters = ComicOfflineService.instance.downloadedChapters(book);
      if (textChapters.isEmpty && comicChapters.isEmpty) continue;
      rows.add(_Row(s: s, text: textChapters.length, comic: comicChapters.length));
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('缓存管理'),
        actions: [
          TextButton(
            onPressed: () async {
              await _clearAll();
            },
            child: const Text('清空全部'),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Text(
              '共缓存：文本书 $_totalText 章 · 漫画 $_totalComic 章',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          Expanded(
            child: rows.isEmpty
                ? const Center(
                    child: Text('暂无缓存\n在阅读器里“缓存全本 / 离线下载本章”即可使用'))
                : ListView.builder(
                    itemCount: rows.length,
                    itemBuilder: (_, i) {
                      final r = rows[i];
                      return ListTile(
                        title: Text(r.s.name,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text([
                          if (r.text > 0) '正文已缓存 ${r.text} 章',
                          if (r.comic > 0) '漫画离线 ${r.comic} 章',
                        ].join(' · ')),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => _deleteBook(r.s),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteBook(ShelfBook s) async {
    final book = _bookOf(s);
    await BookCacheService.instance
        .deleteBookAll(book);
    await ComicOfflineService.instance.deleteBook(book);
    setState(_recalc);
  }

  Future<void> _clearAll() async {
    for (final s in ShelfService.instance.books) {
      await _deleteBook(s);
    }
    if (!mounted) return;
    setState(() {});
  }
}

class _Row {
  _Row({required this.s, required this.text, required this.comic});
  final ShelfBook s;
  final int text;
  final int comic;
}