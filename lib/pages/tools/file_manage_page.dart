import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

/// 文件管理页：浏览应用文档目录下的数据/导出文件。
///
/// 列出 [root]（默认应用文档目录）下各子目录：local_books（本地书）、
/// exports（导出文本）等，可查看大小/删除。纯浏览用途，避免误删整个目录。
class FileManagePage extends StatefulWidget {
  const FileManagePage({super.key});

  @override
  State<FileManagePage> createState() => _FileManagePageState();
}

class _FileManagePageState extends State<FileManagePage> {
  String? _rootPath;
  List<(String, FileSystemEntity)> _entries = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final docs = await getApplicationDocumentsDirectory();
    String path = docs.path;
    final root = Directory(path);
    final list = <(String, FileSystemEntity)>[];
    if (await root.exists()) {
      for (final e in root.listSync(followLinks: false)) {
        list.add((e.path, e));
      }
    }
    list.sort((a, b) {
      final ad = FileSystemEntity.isDirectorySync(a.$2.path);
      final bd = FileSystemEntity.isDirectorySync(b.$2.path);
      if (ad != bd) return ad ? -1 : 1;
      return a.$1.toLowerCase().compareTo(b.$1.toLowerCase());
    });
    if (!mounted) return;
    setState(() {
      _rootPath = path;
      _entries = list;
    });
  }

  String _fileName(String p) =>
      p.split(Platform.pathSeparator).last;

  String _size(File f) {
    try {
      final s = f.lengthSync();
      if (s >= 1024 * 1024) return '${(s / 1024 / 1024).toStringAsFixed(1)} MB';
      if (s >= 1024) return '${(s / 1024).toStringAsFixed(1)} KB';
      return '$s B';
    } catch (_) {
      return '-';
    }
  }

  Future<void> _delete(FileSystemEntity e, String name) async {
    final isDir = e is Directory;
    final really = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除'),
        content: Text('确定删除「$name」吗？${isDir ? '（将删除其全部内容）' : ''}'),
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
    if (really != true) return;
    try {
      if (e is Directory) {
        await e.delete(recursive: true);
      } else {
        await e.delete();
      }
      _load();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('删除失败')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('文件管理'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
        ],
      ),
      body: _rootPath == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text('位置：$_rootPath',
                      style: Theme.of(context).textTheme.bodySmall),
                ),
                const Divider(height: 1),
                Expanded(
                  child: _entries.isEmpty
                      ? const Center(child: Text('目录为空'))
                      : ListView.builder(
                          itemCount: _entries.length,
                          itemBuilder: (_, i) {
                            final (path, e) = _entries[i];
                            final name = _fileName(path);
                            final isDir = FileSystemEntity.isDirectorySync(path);
                            return ListTile(
                              dense: true,
                              leading: Icon(isDir
                                  ? Icons.folder_outlined
                                  : Icons.insert_drive_file_outlined),
                              title: Text(name,
                                  maxLines: 1, overflow: TextOverflow.ellipsis),
                              subtitle: isDir
                                  ? Text('目录')
                                  : Text(_size(File(path))),
                              trailing: IconButton(
                                icon: const Icon(Icons.delete_outline),
                                tooltip: '删除',
                                onPressed: () => _delete(e, name),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }
}