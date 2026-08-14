// 书签列表底部弹层
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/bookmark.dart';
import '../../services/bookmark_service.dart';
import '../../widgets/empty_state.dart';

class BookmarkListSheet extends StatelessWidget {
  final String bookId;
  final void Function(Bookmark) onTap;
  const BookmarkListSheet({
    super.key,
    required this.bookId,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<BookmarkService>();
    final list = svc.forBook(bookId);
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
                    '书签',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  Text('共 ${list.length} 个'),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: list.isEmpty
                  ? const EmptyState(
                      icon: Icons.bookmark_border,
                      message: '还没有书签',
                    )
                  : ListView.separated(
                      controller: controller,
                      itemCount: list.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (ctx, i) {
                        final b = list[i];
                        return ListTile(
                          leading: const Icon(Icons.bookmark, size: 20),
                          title: Text(
                            b.chapterTitle.isNotEmpty
                                ? b.chapterTitle
                                : '第${b.chapterIndex + 1}章',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            b.snippet,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () =>
                                svc.remove(b.key),
                          ),
                          onTap: () => onTap(b),
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
