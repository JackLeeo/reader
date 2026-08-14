// 章节列表页
import 'package:flutter/material.dart';

import '../../models/book.dart';
import '../../models/chapter.dart';
import '../../utils/extensions.dart';
import '../../widgets/empty_state.dart';

class ChapterListPage extends StatefulWidget {
  final Book book;
  final List<Chapter> chapters;
  final void Function(int index) onTapChapter;
  final int? currentIndex;

  const ChapterListPage({
    super.key,
    required this.book,
    required this.chapters,
    required this.onTapChapter,
    this.currentIndex,
  });

  @override
  State<ChapterListPage> createState() => _ChapterListPageState();
}

class _ChapterListPageState extends State<ChapterListPage> {
  bool _reverse = false;
  String _filter = '';

  @override
  Widget build(BuildContext context) {
    var list = widget.chapters;
    if (_filter.isNotEmpty) {
      list = list.where((c) => c.title.contains(_filter)).toList();
    }
    if (_reverse) list = list.reversed.toList();

    return Scaffold(
      appBar: AppBar(
        title: Text('目录 (${widget.chapters.length})'),
        actions: [
          IconButton(
            icon: Icon(_reverse ? Icons.sort_by_alpha : Icons.swap_vert),
            tooltip: '倒序',
            onPressed: () => setState(() => _reverse = !_reverse),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(50),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: TextField(
              decoration: const InputDecoration(
                hintText: '筛选章节',
                prefixIcon: Icon(Icons.search, size: 18),
                border: OutlineInputBorder(),
                isDense: true,
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
              onChanged: (v) => setState(() => _filter = v.trim()),
            ),
          ),
        ),
      ),
      body: list.isEmpty
          ? const EmptyState(icon: Icons.list, message: '没有匹配的章节')
          : ListView.builder(
              itemCount: list.length,
              itemBuilder: (context, i) {
                final ch = list[i];
                final isCurrent = widget.currentIndex == ch.index;
                return ListTile(
                  title: Text(
                    ch.title.isEmpty ? '第${ch.index + 1}章' : ch.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isCurrent ? context.colors.primary : null,
                      fontWeight: isCurrent ? FontWeight.w600 : null,
                    ),
                  ),
                  trailing: isCurrent
                      ? Icon(Icons.bookmark, color: context.colors.primary)
                      : null,
                  onTap: () => widget.onTapChapter(ch.index),
                );
              },
            ),
    );
  }
}
