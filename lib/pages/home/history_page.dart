// 历史记录页
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/history_service.dart';
import '../../utils/extensions.dart';
import '../../widgets/book_card.dart';
import '../../widgets/empty_state.dart';
import '../book/book_detail_page.dart';

class HistoryPage extends StatelessWidget {
  const HistoryPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('阅读历史'),
        centerTitle: false,
        actions: [
          Consumer<HistoryService>(
            builder: (context, svc, _) {
              if (svc.items.isEmpty) return const SizedBox.shrink();
              return IconButton(
                icon: const Icon(Icons.delete_sweep),
                tooltip: '清空',
                onPressed: () async {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (_) => AlertDialog(
                      title: const Text('清空历史'),
                      content: const Text('确定清空所有阅读历史？'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('取消'),
                        ),
                        FilledButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('确定'),
                        ),
                      ],
                    ),
                  );
                  if (ok == true) await svc.clear();
                },
              );
            },
          ),
        ],
      ),
      body: Consumer<HistoryService>(
        builder: (context, svc, _) {
          if (svc.items.isEmpty) {
            return const EmptyState(
              icon: Icons.history,
              message: '暂无阅读历史',
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: svc.items.length,
            separatorBuilder: (_, __) => const Divider(height: 1, indent: 80),
            itemBuilder: (context, i) {
              final item = svc.items[i];
              return BookCard(
                book: item.book,
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => BookDetailPage(
                        book: item.book,
                        fromShelf: true,
                      ),
                    ),
                  );
                },
                subtitle: '${item.chapterTitle} · ${item.readTime.toRelativeString()}',
                progress: item.progress,
              );
            },
          );
        },
      ),
    );
  }
}
