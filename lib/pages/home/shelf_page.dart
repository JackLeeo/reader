// 书架页
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/shelf_book.dart';
import '../../services/shelf_service.dart';
import '../../utils/extensions.dart';
import '../../widgets/book_card.dart';
import '../../widgets/empty_state.dart';
import '../book/book_detail_page.dart';
import '../reader/reader_page.dart';

class ShelfPage extends StatelessWidget {
  const ShelfPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('我的书架'),
        centerTitle: false,
      ),
      body: Consumer<ShelfService>(
        builder: (context, shelf, _) {
          if (shelf.books.isEmpty) {
            return EmptyState(
              icon: Icons.menu_book_outlined,
              message: '书架空空如也',
              hint: '去搜索或发现页添加想看的书吧',
            );
          }
          return RefreshIndicator(
            onRefresh: () async {},
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: shelf.books.length,
              separatorBuilder: (_, __) => const Divider(height: 1, indent: 80),
              itemBuilder: (context, i) {
                final book = shelf.books[i];
                return _ShelfTile(
                  book: book,
                  onTap: () => _openBook(context, book),
                  onContinue: () => _continueReading(context, book),
                );
              },
            ),
          );
        },
      ),
    );
  }

  void _openBook(BuildContext context, ShelfBook sb) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => BookDetailPage(book: sb.book, fromShelf: true),
      ),
    );
  }

  void _continueReading(BuildContext context, ShelfBook sb) {
    if (sb.totalChapters == 0) {
      _openBook(context, sb);
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ReaderPage(
          book: sb.book,
          startChapter: sb.lastChapterIndex,
        ),
      ),
    );
  }
}

class _ShelfTile extends StatelessWidget {
  final ShelfBook book;
  final VoidCallback onTap;
  final VoidCallback onContinue;
  const _ShelfTile({required this.book, required this.onTap, required this.onContinue});

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        BookCard(
          book: book.book,
          onTap: onTap,
          onLongPress: () => _showMenu(context),
          subtitle: book.lastReadTime != null
              ? '${book.lastReadTime!.toRelativeString()} · 读至${(book.progress * 100).toStringAsFixed(0)}%'
              : null,
          progress: book.progress > 0 ? book.progress : null,
        ),
        if (book.lastChapterIndex > 0)
          Positioned(
            right: 12,
            bottom: 12,
            child: FilledButton.tonalIcon(
              onPressed: onContinue,
              icon: const Icon(Icons.play_arrow, size: 18),
              label: const Text('继续'),
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
              ),
            ),
          ),
      ],
    );
  }

  void _showMenu(BuildContext context) {
    showModalBottomSheet(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('从书架移除'),
              onTap: () async {
                await context.read<ShelfService>().remove(book.id);
                if (context.mounted) Navigator.pop(context);
              },
            ),
          ],
        ),
      ),
    );
  }
}
