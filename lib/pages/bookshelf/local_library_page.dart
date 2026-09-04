import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../book_source/models/books.dart';
import '../../book_source/services/shelf_service.dart';
import '../../book_source/services/txt_toc_rule_service.dart';
import '../../local/local_book.dart';
import '../../local/local_book_parser.dart';
import '../../local/local_book_store.dart';
import '../reader/reader_page.dart';
import '../tools/txt_toc_rule_page.dart';
import '../../widgets/cover_image.dart';

/// 本地图书馆：导入 TXT/EPUB 并阅读。
///
/// 提供两种导入途径：
/// - 系统文件选择器（file_selector，双端稳定）
/// - 直接粘贴 TXT 文本
/// 导入后解析、持久化到本地书库并加入书架，可点击直接进入阅读器。
class LocalLibraryPage extends StatefulWidget {
  const LocalLibraryPage({super.key});

  @override
  State<LocalLibraryPage> createState() => _LocalLibraryPageState();
}

class _LocalLibraryPageState extends State<LocalLibraryPage> {
  List<LocalBook> _books = [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final list = await LocalBookStore.instance.loadAll();
    if (!mounted) return;
    setState(() => _books = list);
  }

  /// 解析文本（无扩展名时按 utf8 解码）。
  static String _decodeTxt(List<int> bytes) {
    try {
      return utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
      return String.fromCharCodes(bytes);
    }
  }

  Future<void> _import(String name, List<int> bytes, String format,
    {bool silent = false}) async {
    if (!silent) setState(() => _busy = true);
    try {
      final LocalBook book;
      if (format == 'epub') {
        book = LocalBookParser.parseEpub(bytes, name: name);
      } else {
        await TxtTocRuleService.instance.init();
        book = LocalBookParser.parseTxt(_decodeTxt(bytes), name,
            chapterRegex: TxtTocRuleService.instance.activePattern);
      }
      if (book.chapters.isEmpty && book.name.isEmpty) {
        throw Exception('无法解析出章节内容');
      }
      final finalName =
          book.name.trim().isEmpty ? name : book.name.trim();
      final finalBook = LocalBook(
        name: finalName,
        author: book.author,
        cover: book.cover,
        chapters: book.chapters,
      );

      await LocalBookStore.instance.save(finalBook);
      ShelfService.instance.addBook(ShelfBook(
        name: finalBook.name,
        author: finalBook.author,
        coverUrl: finalBook.cover,
        bookUrl: finalBook.key,
        origin: '本地',
        sourceTag: 'local',
        isLocal: true,
      ));
      await ShelfService.instance.save();
      await _reload();
      if (silent) return; // 批量导入不逐本弹提示。
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已导入《$finalName》（${finalBook.chapters.length} 章）')),
      );
    } catch (e) {
      if (!mounted) return;
      if (!silent) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('导入失败：$e')));
      }
      rethrow; // 批量导入据此统计失败数。
    } finally {
      if (!silent && mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickFile() async {
    const typeGroup = XTypeGroup(
      label: 'book',
      extensions: ['txt', 'epub'],
      uniformTypeIdentifiers: ['public.plain-text', 'org.idpf.epub-container'],
    );
    final XFile? file = await openFile(acceptedTypeGroups: [typeGroup]);
    if (file == null) return;
    final bytes = await file.readAsBytes();
    final lower = file.name.toLowerCase();
    final format = lower.endsWith('.epub') ? 'epub' : 'txt';
    final fullName = file.name.split(Platform.pathSeparator).last;
    await _import(
      fullName.replaceAll(RegExp(r'\.[A-Za-z0-9]+$'), ''),
      bytes,
      format,
    );
  }

  /// 打开系统目录选择器，递归扫描文件夹内的 TXT/EPUB 并逐个导入。
  Future<void> _pickFolder() async {
    final String? dirPath = await getDirectoryPath();
    if (dirPath == null) return;
    final files = <File>[];
    void walk(Directory d) {
      try {
        for (final e in d.listSync()) {
          if (e is File) {
            final name = e.path.toLowerCase();
            if (name.endsWith('.txt') || name.endsWith('.epub')) {
              files.add(e);
            }
          } else if (e is Directory) {
            walk(e);
          }
        }
      } catch (_) {}
    }

    walk(Directory(dirPath));
    if (files.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('所选文件夹内未找到 TXT / EPUB 文件')),
      );
      return;
    }

    setState(() => _busy = true);
    var ok = 0;
    var fail = 0;
    try {
      for (final f in files) {
        try {
          final bytes = await f.readAsBytes();
          final lower = f.path.toLowerCase();
          final format = lower.endsWith('.epub') ? 'epub' : 'txt';
          await _import(
            f.uri.pathSegments.isNotEmpty
                ? f.uri.pathSegments.last
                    .replaceAll(RegExp(r'\.[A-Za-z0-9]+$'), '')
                : '本地书',
            bytes,
            format,
            silent: true,
          );
          ok++;
        } catch (_) {
          fail++;
        }
      }
    } finally {
      setState(() => _busy = false);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('文件夹导入完成：成功 $ok 本${fail > 0 ? '，失败 $fail 本' : ''}')),
    );
    await _reload();
  }

  Future<void> _pasteText() async {
    final controller = TextEditingController();
    final nameController = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('粘贴 TXT 文本导入'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(labelText: '书名（可选）'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: controller,
              maxLines: 8,
              decoration: const InputDecoration(
                labelText: '正文内容',
                alignLabelWithHint: true,
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
            onPressed: () => Navigator.pop(ctx, 'ok'),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    if (name == null) return;
    final content = controller.text.trim();
    if (content.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('正文内容为空')));
      return;
    }
    final bookName =
        nameController.text.trim().isEmpty ? '粘贴导入的书籍' : nameController.text.trim();
    await _import(bookName, utf8.encode(content), 'txt');
  }

  Future<void> _openBook(BuildContext context, LocalBook book) async {
    final chapters = <BookChapter>[
      for (var i = 0; i < book.chapters.length; i++)
        BookChapter(title: book.chapters[i].title, url: 'local://$i'),
    ];
    final shelf = ShelfBook(
      name: book.name,
      author: book.author,
      bookUrl: book.key,
      origin: '本地',
      sourceTag: 'local',
      isLocal: true,
    );
    final saved = ShelfService.instance.findByKey(shelf.key);
    final idx = saved?.lastReadIndex ?? 0;
    final page = saved?.lastReadPage ?? 0;

    final b = Book(
      name: book.name,
      author: book.author,
      bookUrl: book.key,
      origin: '本地',
      sourceTag: 'local',
      type: 0,
    );
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ReaderPage(
          book: b,
          chapters: chapters,
          initialIndex: idx,
          initialPage: page,
          localBook: book,
        ),
      ),
    );
  }

  Future<void> _remove(BuildContext context, LocalBook book) async {
    await LocalBookStore.instance.remove(book.key);
    final shelf = ShelfBook(
      name: book.name,
      author: book.author,
      bookUrl: book.key,
      origin: '本地',
      sourceTag: 'local',
      isLocal: true,
    );
    final saved = ShelfService.instance.findByKey(shelf.key);
    if (saved != null) {
      ShelfService.instance.removeBook(saved);
      await ShelfService.instance.save();
    }
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('本地书'),
        actions: [
          IconButton(
            icon: const Icon(Icons.rule_folder_outlined),
            tooltip: 'TXT 目录规则',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const TxtTocRulePage()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.upload_file),
            tooltip: '导入文件',
            onPressed: _busy ? null : _pickFile,
          ),
          IconButton(
            icon: const Icon(Icons.create_new_folder_outlined),
            tooltip: '导入文件夹（批量）',
            onPressed: _busy ? null : _pickFolder,
          ),
          IconButton(
            icon: const Icon(Icons.content_paste_go),
            tooltip: '粘贴文本',
            onPressed: _busy ? null : _pasteText,
          ),
        ],
      ),
      body: _busy
          ? const Center(child: CircularProgressIndicator())
          : _books.isEmpty
              ? _buildEmpty(context)
              : ListView.separated(
                  itemCount: _books.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final book = _books[i];
                    final saved = ShelfService.instance.findByKey(
                      ShelfBook(
                        name: book.name,
                        author: book.author,
                        bookUrl: book.key,
                        origin: '本地',
                        sourceTag: 'local',
                        isLocal: true,
                      ).key,
                    );
                    return ListTile(
                      leading: book.cover == null
                          ? const Icon(Icons.menu_book_outlined)
                          : CoverImage(
                              width: 42, height: 56, fallbackUrl: book.cover),
                      title: Text(book.name,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                        '${(book.author?.isEmpty ?? true) ? '未知作者' : book.author} · ${book.chapters.length} 章'
                        '${(saved?.lastReadChapter.isEmpty ?? true) ? '' : ' · 读到：${saved!.lastReadChapter}'}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () => _openBook(context, book),
                      onLongPress: () => _remove(context, book),
                    );
                  },
                ),
    );
  }

  Widget _buildEmpty(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.local_library_outlined, size: 64),
            const SizedBox(height: 12),
            const Text('还没有本地书\n点右上角导入 TXT / EPUB 电子书'),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _busy ? null : _pickFile,
              icon: const Icon(Icons.upload_file),
              label: const Text('导入本地书'),
            ),
          ],
        ),
      );
}