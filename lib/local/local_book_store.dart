import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'local_book.dart';

/// 本地书存储：把已解析的本地书按书名持久化为 JSON 文件。
///
/// 存放于 `<Documents>/local_books/<name>.json`，支持保存 / 按名加载 /
/// 列出全部 / 删除。纯服务层，便于后续扩展导入导出。
class LocalBookStore {
  LocalBookStore._();

  static final LocalBookStore instance = LocalBookStore._();

  /// 规范化文件名（去非法字符），保证稳定唯一。
  static String _fileName(LocalBook b) => '${_sanitize(b.key)}.json';

  static String _sanitize(String s) {
    final bad = RegExp(r'[\\/:*?"<>|\x00-\x1f]');
    var out = s.replaceAll(bad, '_').trim();
    if (out.isEmpty) out = '未命名';
    return out.length <= 120 ? out : out.substring(0, 120);
  }

  Future<Directory> _dir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/local_books');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<void> save(LocalBook book) async {
    final dir = await _dir();
    // 内嵌(data URI)封面落盘为本地文件，并把 book.cover 改为 file:// 供书架统一显示。
    final cover = book.cover;
    if (cover != null && cover.startsWith('data:')) {
      final comma = cover.indexOf('base64,');
      if (comma > 0) {
        try {
          final raw = base64Decode(cover.substring(comma + 7));
          final mime = cover.substring(5, cover.indexOf(';'));
          final ext = switch (mime) {
            'image/png' => 'png',
            'image/gif' => 'gif',
            'image/webp' => 'webp',
            'image/jpeg' => 'jpg',
            _ => 'png',
          };
          final covers = Directory('${dir.path}/covers');
          if (!await covers.exists()) await covers.create(recursive: true);
          final path = '${covers.path}/${_sanitize(book.key)}.$ext';
          await File(path).writeAsBytes(raw, flush: true);
          book.cover = 'file://${path.replaceAll('\\', '/')}';
        } catch (_) {
          book.cover = null; // 落盘失败则不携带封面
        }
      }
    }
    await File('${dir.path}/${_fileName(book)}')
        .writeAsString(jsonEncode(book.toJson()), flush: true);
  }

  Future<LocalBook?> loadByName(String name) async {
    if (name.isEmpty) return null;
    final dir = await _dir();
    for (final f in dir.listSync(followLinks: false)) {
      if (f is! File) continue;
      final basename = f.path.split(Platform.pathSeparator).last;
      if (basename == _fileName(LocalBook(name: name))) {
        return _readFile(f);
      }
    }
    return null;
  }

  Future<List<LocalBook>> loadAll() async {
    final dir = await _dir();
    if (!await dir.exists()) return const [];
    final out = <LocalBook>[];
    for (final f in dir.listSync(followLinks: false)) {
      if (f is! File || !f.path.endsWith('.json')) continue;
      final b = await _readFile(f);
      if (b != null) out.add(b);
    }
    return out;
  }

  Future<LocalBook?> _readFile(File f) async {
    try {
      final raw = await f.readAsString();
      return LocalBook.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> remove(String name) async {
    if (name.isEmpty) return;
    final dir = await _dir();
    if (!await dir.exists()) return;
    final target = File('${dir.path}/${_fileName(LocalBook(name: name))}');
    if (await target.exists()) await target.delete();
  }
}