import 'package:flutter/material.dart';

import '../../book_source/models/books.dart';
import '../../book_source/services/bookmark_service.dart';
import '../../book_source/services/shelf_service.dart';
import '../book/book_detail_page.dart';

/// 全部书签管理页（对齐官方「书签」菜单：查看/删除全部书签）。
///
/// 按书分组展示，点击章节书签跳转到书籍详情；支持删除单条与清空全部。
class BookmarkManagePage extends StatefulWidget {
  const BookmarkManagePage({super.key});

  @override
  State<BookmarkManagePage> createState() => _BookmarkManagePageState();
}

class _BookmarkManagePageState extends State<BookmarkManagePage> {
  @override
  void initState() {
    super.initState();
    BookmarkService.instance.init();
  }

  String _bookName(String bookKey) {
    final shelf = ShelfService.instance.findByKey(bookKey);
    return shelf?.name ?? _shortKey(bookKey);
  }

  String _shortKey(String bookKey) {
    var s = bookKey;
    final idx = s.indexOf('|');
    if (idx >= 0 && idx + 1 < s.length) s = s.substring(idx + 1);
    return s.length > 24 ? '${s.substring(0, 24)}…' : s;
  }

  Future<void> _delete(String bookKey, int chapterIndex) async {
    BookmarkService.instance.remove(bookKey, chapterIndex);
    setState(() {});
  }

  Future<void> _clearAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空全部书签'),
        content: const Text('确定删除所有书签吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final service = BookmarkService.instance;
    for (final key in service.bookKeys) {
      for (final bm in service.forBook(key)) {
        service.remove(key, bm.chapterIndex);
      }
    }
    setState(() {});
  }

  void _openBook(String bookKey) {
    final shelf = ShelfService.instance.findByKey(bookKey);
    if (shelf == null) return;
    final flow = SearchBook(
      name: shelf.name,
      author: shelf.author,
      coverUrl: shelf.coverUrl,
      bookUrl: shelf.bookUrl,
      origin: shelf.origin,
    );
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => BookDetailPage(flow: flow)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final service = BookmarkService.instance;
    final bookKeys = service.bookKeys;
    return Scaffold(
      appBar: AppBar(
        title: const Text('书签管理'),
        actions: [
          if (bookKeys.isNotEmpty)
            TextButton(
              onPressed: _clearAll,
              child: const Text('清空全部'),
            ),
        ],
      ),
      body: bookKeys.isEmpty
          ? const Center(child: Text('暂无书签\n在阅读时点顶部书签图标即可添加'))
          : ListView(
              children: [
                for (final key in bookKeys) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            _bookName(key),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style:
                                Theme.of(context).textTheme.titleSmall?.copyWith(
                                      color:
                                          Theme.of(context).colorScheme.primary,
                                    ),
                          ),
                        ),
                        Text(
                          '${service.forBook(key).length} 处',
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                      ],
                    ),
                  ),
                  for (final bm in service.forBook(key))
                    ListTile(
                      leading: const Icon(Icons.bookmark_outline),
                      title: Text(bm.chapterTitle,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                        bm.addTime > 0
                            ? _fmtTime(bm.addTime)
                            : '第 ${bm.chapterIndex + 1} 章',
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => _delete(key, bm.chapterIndex),
                      ),
                      onTap: () => _openBook(key),
                    ),
                ],
              ],
            ),
    );
  }

  String _fmtTime(int ms) {
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}';
  }
}