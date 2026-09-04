import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../book_source/models/books.dart';
import '../../book_source/services/shelf_service.dart';
import '../../book_source/services/shelf_update_service.dart';
import '../../core/shelf_badge_store.dart';
import '../../local/local_book_store.dart';
import '../../widgets/cover_image.dart';
import '../book/book_detail_page.dart';
import '../reader/reader_page.dart';
import '../search/search_page.dart';
import '../search/global_search_page.dart';
import 'local_library_page.dart';

/// 书库（书架）。对应官方 fragment_books。
///
/// 展示已收藏书籍（封面/进度/续读），提供搜索入口。
class BookshelfPage extends StatefulWidget {
  const BookshelfPage({super.key});

  @override
  State<BookshelfPage> createState() => _BookshelfPageState();
}

class _BookshelfPageState extends State<BookshelfPage> {
  String _group = '默认';
  bool _listView = false;

  /// 排序方式：0 添加时间 | 1 最近阅读 | 2 书名 | 3 作者 | 4 阅读进度。
  int _sort = 0;
  static const List<String> _sortNames = [
    '添加时间', '最近阅读', '书名', '作者', '阅读进度',
  ];

  /// 是否正在批量检测更新。
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    _group = ShelfService.instance.groups.first; // 首个分组（默认）
  }

  /// 枚举值映射。
  SortMode get _sortMode {
    switch (_sort) {
      case 1: return SortMode.recentRead;
      case 2: return SortMode.name;
      case 3: return SortMode.author;
      case 4: return SortMode.progress;
      default: return SortMode.addTime;
    }
  }

  /// 导出书架（复制 JSON 到剪贴板，对应官方 导出书架）。
  Future<void> _exportShelf() async {
    final json = jsonEncode(
        ShelfService.instance.books.map((b) => b.toJson()).toList());
    await Clipboard.setData(ClipboardData(text: json));
    if (!mounted) return;
    final n = _shelfCount();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已复制书架数据（$n 本）')),
    );
  }

  int _shelfCount() => ShelfService.instance.books.length;

  /// 批量检测当前分组的网络书最新章节，结果为有更新的数量。
  Future<void> _checkUpdate() async {
    if (_checking) return;
    final books = ShelfService.instance
        .booksInGroup(_group)
        .where((b) => !b.isLocal)
        .toList();
    if (books.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('当前分组没有可检测的网络书')),
      );
      return;
    }
    setState(() => _checking = true);
    final count =
        await ShelfUpdateService.instance.checkAll(books);
    if (!mounted) return;
    setState(() => _checking = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('检测完成：$count 本有更新')),
    );
  }

  /// 导入书架（粘贴 JSON，对应官方 导入书架）。
  Future<void> _importShelf() async {
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导入书架'),
        content: TextField(
          controller: controller,
          maxLines: 8,
          decoration: const InputDecoration(
            hintText: '粘贴书架 JSON（数组，每项含 name/author/bookUrl/origin/sourceTag）',
            border: OutlineInputBorder(),
            alignLabelWithHint: true,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    if (text == null || text.trim().isEmpty) return;
    try {
      final list = jsonDecode(text) as List;
      final svc = ShelfService.instance;
      var added = 0;
      for (final e in list) {
        final m = e as Map<String, dynamic>;
        final ok = svc.addBook(ShelfBook(
          name: (m['name'] ?? '') as String,
          author: m['author'] as String?,
          coverUrl: m['coverUrl'] as String?,
          bookUrl: (m['bookUrl'] ?? '') as String,
          origin: (m['origin'] ?? '') as String,
          sourceTag: (m['sourceTag'] ?? '') as String,
          isLocal: (m['isLocal'] ?? false) as bool,
        ));
        if (ok) added++;
      }
      if (added > 0) await svc.save();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('导入完成，新增 $added 本')));
      setState(() {});
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('导入失败：JSON 格式不正确')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final groups = ShelfService.instance.groups;
    final books =
        ShelfBook.sortShelf(ShelfService.instance.booksInGroup(_group), _sortMode);
    return Scaffold(
      appBar: AppBar(
        title: const Text('书库'),
        actions: [
          IconButton(
            icon: Icon(_listView ? Icons.grid_view : Icons.view_list),
            tooltip: _listView ? '网格视图' : '列表视图',
            onPressed: () => setState(() => _listView = !_listView),
          ),
          PopupMenuButton<String>(
            tooltip: '书架菜单',
            onSelected: (v) {
              switch (v) {
                case 'export':
                  _exportShelf();
                case 'import':
                  _importShelf();
                case 'search':
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const GlobalSearchPage()),
                  );
              }
              if (v.startsWith('sort:')) {
                setState(() => _sort = int.parse(v.split(':')[1]));
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'export', child: Text('导出书架（复制 JSON）')),
              const PopupMenuItem(value: 'import', child: Text('导入书架（粘贴 JSON）')),
              const PopupMenuItem(value: 'search', child: Text('全文搜索（跨书）')),
              const PopupMenuDivider(),
              for (var i = 0; i < _sortNames.length; i++)
                PopupMenuItem(
                  value: 'sort:$i',
                  child: Row(
                    children: [
                      Icon(
                        _sort == i
                            ? Icons.radio_button_checked
                            : Icons.radio_button_off,
                        size: 18,
                        color: _sort == i
                            ? Theme.of(context).colorScheme.primary
                            : null,
                      ),
                      const SizedBox(width: 8),
                      Text(_sortNames[i]),
                    ],
                  ),
                ),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.local_library_outlined),
            tooltip: '本地书',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const LocalLibraryPage()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.update),
            tooltip: '检测最新章节',
            onPressed: _checking ? null : _checkUpdate,
          ),
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: '搜索',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SearchPage()),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          // 分组横滑筛选（对应官方 group）
          SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              children: [
                for (final g in groups)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      label: Text(g),
                      selected: _group == g,
                      onSelected: (_) => setState(() => _group = g),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            // 监听检测更新信号，有更新时刷新封面角标。
            child: ValueListenableBuilder<int>(
              valueListenable: ShelfUpdateService.instance.version,
              builder: (_, _, _) => books.isEmpty
                  ? _buildEmpty(context)
                  : (_listView
                      ? ListView.separated(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          itemCount: books.length,
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (_, i) => _ShelfCard(
                            book: books[i],
                            onGroupChanged: () => setState(() {}),
                            listMode: true,
                          ),
                        )
                      : GridView.builder(
                          padding: const EdgeInsets.all(8),
                          gridDelegate:
                              const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 130,
                            childAspectRatio: 0.62,
                            crossAxisSpacing: 8,
                            mainAxisSpacing: 8,
                          ),
                          itemCount: books.length,
                          itemBuilder: (_, i) => _ShelfCard(
                            book: books[i],
                            onGroupChanged: () => setState(() {}),
                          ),
                        )),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.collections_bookmark_outlined, size: 64),
            const SizedBox(height: 12),
            const Text('书架空空如也\n去搜索并收藏一本书吧'),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SearchPage()),
              ),
              icon: const Icon(Icons.search),
              label: const Text('去搜索'),
            ),
          ],
        ),
      );
}

class _ShelfCard extends StatelessWidget {
  const _ShelfCard({
    required this.book,
    required this.onGroupChanged,
    this.listMode = false,
  });

  final ShelfBook book;
  final VoidCallback onGroupChanged;
  final bool listMode;

  Future<void> _resume(BuildContext context) async {
    if (book.isLocal) {
      final lb = await LocalBookStore.instance.loadByName(book.bookUrl);
      if (lb == null || !context.mounted) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('本地书数据缺失，请重新导入')),
          );
        }
        return;
      }
      // 直接进阅读器续读（复用 shell 的图章逻辑）。
      final b = Book(
        name: lb.name,
        author: lb.author,
        bookUrl: lb.key,
        origin: '本地',
        sourceTag: 'local',
        type: 0,
      );
      final chapters = <BookChapter>[
        for (var i = 0; i < lb.chapters.length; i++)
          BookChapter(title: lb.chapters[i].title, url: 'local://$i'),
      ];
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ReaderPage(
            book: b,
            chapters: chapters,
            initialIndex: book.lastReadIndex,
            initialPage: book.lastReadPage,
            localBook: lb,
          ),
        ),
      );
      return;
    }
    // 网络书：打开详情页（内部拉目录），用户点目录续读。
    final flow = SearchBook(
      name: book.name,
      author: book.author,
      coverUrl: book.coverUrl,
      bookUrl: book.bookUrl,
      origin: book.origin,
    );
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => BookDetailPage(flow: flow)),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (listMode) return _buildListTile(context);
    return GestureDetector(
      onTap: () => _resume(context),
      onLongPress: () => _showMenu(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Center(
              child: ValueListenableBuilder<int>(
                valueListenable: ShelfBadgeController.instance.mode,
                builder: (_, badgeMode, _) => _buildCover(context, badgeMode),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(book.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall),
          Text(
            book.lastReadChapter.isEmpty
                ? '未开始阅读'
                : '读到：${book.lastReadChapter}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context)
                .textTheme
                .labelSmall
                ?.copyWith(color: Theme.of(context).colorScheme.primary),
          ),
        ],
      ),
    );
  }

  /// 封面：可叠加进度角标和底部进度条（书架角标设置）。
  Widget _buildCover(BuildContext ctx, int badgeMode) {
    final cover = CoverImage(
      bookKey: book.key,
      fallbackUrl: book.coverUrl,
      width: 92,
      height: 128,
    );
    final stack = <Widget>[cover];

    // 新版角标（书架更新检测后有新章节）。
    if (ShelfUpdateService.instance.isUpdated(book.key)) {
      stack.add(Positioned(
        top: 4,
        left: 4,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: Colors.redAccent,
            borderRadius: BorderRadius.circular(8),
            boxShadow: const [
              BoxShadow(color: Colors.black26, blurRadius: 3),
            ],
          ),
          child: const Text(
            '更新',
            style: TextStyle(
              fontSize: 10,
              color: Colors.white,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ));
    }

    if (badgeMode == 0) return Stack(clipBehavior: Clip.none, children: stack);
    final percent = (book.readingProgress * 100).clamp(0, 100);
    final pct = (percent * 1).toInt();
    if (badgeMode == 2) {
      // 底部进度条
      stack.add(Positioned(
        left: 3,
        right: 3,
        bottom: 3,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: SizedBox(
            height: 4,
            child: LinearProgressIndicator(
              value: book.readingProgress,
              backgroundColor: Colors.black26,
              color: Theme.of(ctx).colorScheme.primary,
            ),
          ),
        ),
      ));
    }
    if (percent > 0) {
      stack.add(Positioned(
        top: 4,
        right: 4,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
          decoration: BoxDecoration(
            color: Theme.of(ctx).colorScheme.primary,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            '$pct%',
            style: const TextStyle(
              fontSize: 10,
              color: Colors.white,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ));
    }
    return Stack(clipBehavior: Clip.none, children: stack);
  }

  void _showMenu(BuildContext context) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(title: Text(book.name)),
            ListTile(
              leading: Icon(book.locked
                  ? Icons.lock_outline
                  : Icons.lock_open_outlined),
              title: Text(book.locked ? '解锁来源' : '源锁定'),
              subtitle: Text(book.locked
                  ? '已锁定为《${book.origin}》，阅读时不再提示换源'
                  : '锁定该书的来源书源'),
              trailing: Switch(
                value: book.locked,
                onChanged: (_) {
                  Navigator.pop(ctx);
                  ShelfService.instance.setLocked(book.key, !book.locked);
                  ShelfService.instance.save();
                  onGroupChanged();
                },
              ),
            ),
            ListTile(
              leading: const Icon(Icons.drive_file_move_outlined),
              title: const Text('移至分组'),
              onTap: () {
                Navigator.pop(ctx);
                _showGroupPicker(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('从书架移除'),
              onTap: () {
                Navigator.pop(ctx);
                ShelfService.instance.removeBook(book);
                ShelfService.instance.save();
                onGroupChanged();
                if (book.isLocal) LocalBookStore.instance.remove(book.bookUrl);
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 选择/新建分组，把当前书移过去。
  void _showGroupPicker(BuildContext context) {
    final groups = ShelfService.instance.groups;
    final controller = TextEditingController();
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: TextField(
                controller: controller,
                decoration: const InputDecoration(
                  labelText: '新建分组（留空为默认分组）',
                  isDense: true,
                ),
              ),
            ),
            for (final g in groups)
              ListTile(
                dense: true,
                leading: const Icon(Icons.folder_outlined),
                title: Text('移到「$g」'),
                onTap: () {
                  Navigator.pop(ctx);
                  ShelfService.instance.setGroup(book, g);
                  ShelfService.instance.save();
                  onGroupChanged();
                },
              ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.add),
              title: const Text('新建并移动'),
              onTap: () {
                final g = controller.text.trim();
                Navigator.pop(ctx);
                ShelfService.instance.setGroup(book, g.isEmpty ? '' : g);
                ShelfService.instance.save();
                onGroupChanged();
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildListTile(BuildContext context) {
    return ListTile(
      leading: Container(
        width: 42,
        height: 56,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(4),
        ),
        child: const Icon(Icons.menu_book_outlined, size: 28),
      ),
      title: Text(book.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        book.lastReadChapter.isEmpty
            ? '未开始阅读'
            : '读到：${book.lastReadChapter}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: IconButton(
        icon: const Icon(Icons.more_vert),
        onPressed: () => _showMenu(context),
      ),
      onTap: () => _resume(context),
      onLongPress: () => _showMenu(context),
    );
  }
}