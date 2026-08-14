// 本地书库列表
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/local_book_service.dart';
import '../../utils/log.dart';
import '../../widgets/empty_state.dart';
import '../reader/local_reader_page.dart';

class LocalBookListPage extends StatelessWidget {
  const LocalBookListPage({super.key});

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<LocalBookService>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('本地书库'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '导入TXT',
            onPressed: () => _importDialog(context),
          ),
        ],
      ),
      body: svc.books.isEmpty
          ? const EmptyState(
              icon: Icons.menu_book,
              message: '本地书库为空',
              hint: '点击右上角"+"导入TXT文件',
            )
          : ListView.separated(
              itemCount: svc.books.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (ctx, i) {
                final b = svc.books[i];
                return ListTile(
                  leading: const Icon(Icons.description, size: 32),
                  title: Text(b.name,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                      '${(b.fileSize / 1024).toStringAsFixed(1)} KB · ${_relativeTime(b.addedAt)}'),
                  trailing: PopupMenuButton<String>(
                    onSelected: (v) async {
                      if (v == 'delete') {
                        await svc.remove(b.id);
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'delete', child: Text('删除')),
                    ],
                  ),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => LocalReaderPage(book: b),
                      ),
                    );
                  },
                );
              },
            ),
    );
  }

  String _relativeTime(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return '刚刚';
    if (d.inHours < 1) return '${d.inMinutes}分钟前';
    if (d.inDays < 1) return '${d.inHours}小时前';
    if (d.inDays < 30) return '${d.inDays}天前';
    return '${(d.inDays / 30).floor()}个月前';
  }

  void _importDialog(BuildContext context) async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('导入TXT'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('输入TXT文件的绝对路径（iOS沙盒内）'),
              const SizedBox(height: 8),
              TextField(
                controller: controller,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: '/var/mobile/.../book.txt',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('导入'),
            ),
          ],
        );
      },
    );
    if (result == null || result.isEmpty) return;
    if (!context.mounted) return;
    final svc = context.read<LocalBookService>();
    try {
      if (!await File(result).exists()) {
        throw '文件不存在';
      }
      await svc.importFromPath(result);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已导入: ${result.split('/').last}')),
      );
    } catch (e) {
      Log.e('导入失败', error: e);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导入失败: $e')),
      );
    }
  }
}
