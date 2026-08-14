// 换源弹层 - 展示其它源同名候选
import 'package:flutter/material.dart';

import '../../models/book.dart';
import '../../widgets/book_cover.dart';
import '../../widgets/empty_state.dart';

class SourceSwitchSheet extends StatelessWidget {
  final Book book;
  final List<Book> candidates;
  final void Function(Book) onSwitch;
  const SourceSwitchSheet({
    super.key,
    required this.book,
    required this.candidates,
    required this.onSwitch,
  });

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.3,
      maxChildSize: 0.95,
      expand: false,
      builder: (ctx, controller) {
        return Column(
          children: [
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(top: 8, bottom: 8),
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  const Text(
                    '换源',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  Text('找到 ${candidates.length} 个源'),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text(
                '选择后将从该源重新加载目录和章节',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: candidates.isEmpty
                  ? const EmptyState(
                      icon: Icons.search_off,
                      message: '未找到其它源',
                    )
                  : ListView.separated(
                      controller: controller,
                      itemCount: candidates.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (ctx, i) {
                        final b = candidates[i];
                        final isCurrent = b.sourceId == book.sourceId;
                        return ListTile(
                          leading: BookCover(
                            title: b.name,
                            author: b.author,
                            width: 44,
                            height: 60,
                          ),
                          title: Text(
                            b.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '源: ${b.sourceName}',
                                style: const TextStyle(fontSize: 12),
                              ),
                              if (b.lastChapter.isNotEmpty)
                                Text(
                                  '最新: ${b.lastChapter}',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: Colors.grey,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                            ],
                          ),
                          trailing: isCurrent
                              ? const Chip(
                                  label: Text('当前'),
                                  padding: EdgeInsets.zero,
                                )
                              : const Icon(Icons.chevron_right),
                          onTap: isCurrent ? null : () => onSwitch(b),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }
}
