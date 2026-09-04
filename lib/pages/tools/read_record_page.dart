import 'package:flutter/material.dart';

import '../../book_source/models/books.dart';
import '../../book_source/services/read_stat_service.dart';
import '../../book_source/services/shelf_service.dart';
import '../book/book_detail_page.dart';

/// 阅读记录页（对齐官方「阅读记录」：按书查看阅读时长并可续读）。
class ReadRecordPage extends StatefulWidget {
  const ReadRecordPage({super.key});

  @override
  State<ReadRecordPage> createState() => _ReadRecordPageState();
}

class _ReadRecordPageState extends State<ReadRecordPage> {
  @override
  void initState() {
    super.initState();
    ReadStatService.instance.init();
  }

  static String _fmt(int seconds) {
    if (seconds < 60) return '$seconds 秒';
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    if (h > 0) return '$h 小时 $m 分';
    return '$m 分钟';
  }

  void _open(String bookKey, String title) {
    final shelf = ShelfService.instance.findByKey(bookKey);
    if (shelf == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('「$title」不在书架中，无法续读')),
      );
      return;
    }
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
    final stat = ReadStatService.instance;
    final books = stat.topBooks;
    return Scaffold(
      appBar: AppBar(
        title: const Text('阅读记录'),
        actions: [
          TextButton(
            onPressed: () {
              stat.clear();
              stat.save();
              setState(() {});
            },
            child: const Text('清空'),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Row(
              children: [
                Text(
                  '累计 ${_fmt(stat.totalSeconds)} · 今日 ${_fmt(stat.todaySeconds)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const Spacer(),
                Text('共 ${books.length} 本',
                    style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: books.isEmpty
                ? const Center(child: Text('还没有阅读记录，去读几章吧。'))
                : ListView.builder(
                    itemCount: books.length,
                    itemBuilder: (_, i) {
                      final b = books[i];
                      return ListTile(
                        leading: Text('${i + 1}',
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium
                                ?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .primary)),
                        title: Text(b.title.isEmpty ? '(未命名)' : b.title,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        trailing: Text(_fmt(b.seconds)),
                        onTap: () => _open(b.bookKey, b.title),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}