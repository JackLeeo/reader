import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 文本导出工具：把章节（标题 + 正文）导出为 `.txt` 文件。
///
/// 存放于 `<Documents>/exports/<书名>.txt`，返回实际保存路径；
/// 目录/写入失败返回 null，不抛异常。
class BookExporter {
  BookExporter._();

  /// 文件名规范化（去非法字符）。
  static String _sanitize(String s) {
    final bad = RegExp(r'[\\/:*?"<>|\x00-\x1f]');
    var out = s.replaceAll(bad, '_').trim();
    if (out.isEmpty) out = '未命名';
    return out.length <= 100 ? out : out.substring(0, 100);
  }

  static Future<Directory> _dir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/exports');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// 导出章节列表为 txt。
  ///
  /// [fileName] 不含扩展名；[chapters] 为 (标题, 正文) 列表。
  /// 返回绝对路径，失败返回 null。
  static Future<String?> exportText({
    required String fileName,
    required List<(String, String)> chapters,
    String joinBy = '\n\n',
  }) async {
    if (chapters.isEmpty) return null;
    try {
      final dir = await _dir();
      final buffer = StringBuffer();
      for (final (title, body) in chapters) {
        if (title.trim().isNotEmpty) {
          buffer.write(title.trim());
          buffer.write('\n\n');
        }
        buffer.write(body.trim());
        buffer.write('\n\n');
      }
      final path = '${dir.path}/${_sanitize(fileName)}.txt';
      final f = File(path);
      await f.writeAsString(buffer.toString(), flush: true);
      return f.path;
    } catch (_) {
      return null;
    }
  }
}