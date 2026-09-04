import 'dart:convert';

import '../models/book_source.dart';
import 'source_sharer.dart';

/// 书源文本解析：兼容数组、单对象、`{bookSources:[...]}` 包装、Legado 导出格式。
class SourceImportParser {
  /// 若 [text] 为口令加密串（`enc:` 前缀），用 [password] 解密后再解析。
  /// 解密失败（口令错误）返回 null。
  static List<BookSource>? parseWithPassword(String text, String password) {
    if (!SourceSharer.isEncrypted(text)) return parse(text);
    final dec = SourceSharer.decrypt(text, password);
    if (dec == null) return null;
    return parse(dec);
  }

  /// 从 [text] 解析出书源列表（支持纯 JSON 或 `text` 包装）。
  static List<BookSource> parse(String text) {
    final t = text.trim();
    if (t.isEmpty) return const [];
    // 兼容部分站点给出的 `text:{...}` json 声明。
    final jsonStr = t.startsWith('text:') ? t.substring(5).trim() : t;
    Object? dec;
    try {
      dec = jsonDecode(jsonStr);
    } catch (_) {
      // 尝试剥离常见的 markdown/code 包裹后再次解析。
      final cleaned = _stripCodeFence(jsonStr);
      try {
        dec = jsonDecode(cleaned);
      } catch (_) {
        dec = null;
      }
    }
    if (dec == null) return const [];

    final out = <BookSource>[];
    if (dec is List) {
      for (final e in dec) {
        if (e is Map) {
          final s = _trySource(Map<String, dynamic>.from(e));
          if (s != null) out.add(s);
        }
      }
    } else if (dec is Map) {
      // 兼容 `{sourceUrl, sourceName, sourceComment, ...}` 与 `{bookSources:[...]}` 包装。
      final map = Map<String, dynamic>.from(dec);
      if (map.containsKey('bookSources')) {
        final list = map['bookSources'];
        if (list is List) {
          for (final e in list) {
            if (e is Map) {
              final s = _trySource(Map<String, dynamic>.from(e));
              if (s != null) out.add(s);
            }
          }
        }
      } else {
        final s = _trySource(map);
        if (s != null) out.add(s);
      }
    }
    return out;
  }

  static BookSource? _trySource(Map<String, dynamic> m) {
    if ((m['bookSourceUrl'] ?? '').toString().trim().isEmpty) return null;
    try {
      return BookSource.fromJson(m);
    } catch (_) {
      return null;
    }
  }

  /// 去掉首尾 ``` 代码围栏（兼容同行/换行两种写法）。
  static String _stripCodeFence(String s) {
    var t = s.trim();
    if (t.startsWith('```')) {
      final nl = t.indexOf('\n');
      t = nl >= 0
          ? t.substring(nl + 1).trim()
          : t.replaceFirst(RegExp(r'^```+'), '').trim();
    }
    if (t.endsWith('```')) {
      t = t.substring(0, t.length - 3).trim();
    }
    return t;
  }
}