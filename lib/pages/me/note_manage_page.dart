import 'package:flutter/material.dart';

import '../../book_source/services/note_service.dart';

/// 笔记管理页：按书分组展示全部笔记，可查看/编辑/删除。
///
/// 只管理笔记数据（不改阅读进度）；阅读中的笔记属于该书自己的笔记。
class NoteManagePage extends StatefulWidget {
  const NoteManagePage({super.key});

  @override
  State<NoteManagePage> createState() => _NoteManagePageState();
}

class _NoteManagePageState extends State<NoteManagePage> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('笔记管理')),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    final groups = NoteService.instance.grouped();
    if (groups.isEmpty) {
      return const Center(child: Text('暂无笔记，阅读时在顶部菜单添加'));
    }
    return ListView(
      children: [
        for (final (bookName, notes) in groups) ...[
          ListTile(
            leading: const Icon(Icons.menu_book_outlined),
            title: Text(bookName,
                maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text('${notes.length} 条笔记'),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: '删除本书所有笔记',
              onPressed: () => _removeBook(bookName, notes.first.bookKey),
            ),
          ),
          for (final n in notes)
            ListTile(
              dense: true,
              leading: const Icon(Icons.sticky_note_2_outlined),
              title: Text(n.chapterTitle,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(n.text,
                  maxLines: 2, overflow: TextOverflow.ellipsis),
              onTap: () => _edit(n),
            ),
          const Divider(height: 1),
        ],
      ],
    );
  }

  Future<void> _removeBook(String bookName, String bookKey) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除笔记'),
        content: Text('确定删除《$bookName》的全部笔记吗？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (yes == true) {
      await NoteService.instance.removeBook(bookKey);
      if (mounted) setState(() {});
    }
  }

  Future<void> _edit(ReadingNote n) async {
    final controller = TextEditingController(text: n.text);
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('编辑笔记 · ${n.chapterTitle}'),
        content: TextField(
          controller: controller,
          minLines: 4,
          maxLines: 8,
          decoration: const InputDecoration(hintText: '笔记内容'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('保存')),
        ],
      ),
    );
    final text = controller.text.trim();
    controller.dispose();
    if (saved == true) {
      if (text.isNotEmpty) {
        await NoteService.instance.saveNote(ReadingNote(
          bookKey: n.bookKey,
          bookName: n.bookName,
          chapterIndex: n.chapterIndex,
          chapterTitle: n.chapterTitle,
          text: text,
          time: DateTime.now().millisecondsSinceEpoch,
        ));
      } else {
        await NoteService.instance.removeNote(n.bookKey, n.chapterIndex);
      }
      if (mounted) setState(() {});
    }
  }
}