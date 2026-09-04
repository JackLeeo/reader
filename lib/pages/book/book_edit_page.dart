import 'package:flutter/material.dart';

import '../../book_source/services/shelf_service.dart';

/// 书籍自编辑。对应官方 `ui/book/info/edit`：本地改名/作者/封面/简介。
class BookEditPage extends StatefulWidget {
  const BookEditPage({super.key, required this.book});

  final ShelfBook book;

  @override
  State<BookEditPage> createState() => _BookEditPageState();
}

class _BookEditPageState extends State<BookEditPage> {
  late final TextEditingController _name;
  late final TextEditingController _author;
  late final TextEditingController _cover;
  late final TextEditingController _intro;

  String get _key => widget.book.key;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.book.name);
    _author = TextEditingController(text: widget.book.author ?? '');
    _cover = TextEditingController(text: widget.book.coverUrl ?? '');
    _intro = TextEditingController(text: widget.book.intro ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _author.dispose();
    _cover.dispose();
    _intro.dispose();
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('书名不能为空')),
      );
      return;
    }
    ShelfService.instance.updateMeta(
      _key,
      name: name,
      author: _author.text.trim(),
      coverUrl: _cover.text.trim(),
      intro: _intro.text.trim(),
    );
    ShelfService.instance.save();
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('编辑书籍'),
        actions: [
          TextButton(onPressed: _save, child: const Text('保存')),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: '书名'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _author,
            decoration: const InputDecoration(labelText: '作者'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _cover,
            decoration: const InputDecoration(
              labelText: '封面地址',
              hintText: 'https://... 或留空',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _intro,
            maxLines: 4,
            decoration: const InputDecoration(labelText: '简介'),
          ),
        ],
      ),
    );
  }
}