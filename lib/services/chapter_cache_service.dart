// 章节缓存服务 - 减少重复网络请求
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../utils/log.dart';

class ChapterCacheService extends ChangeNotifier {
  static const _dir = 'chapter_cache';
  static const _maxAge = Duration(days: 30);

  /// 获取缓存路径
  Future<File> _cacheFile(String key) async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, _dir));
    if (!await dir.exists()) await dir.create(recursive: true);
    return File(p.join(dir.path, '$key.txt'));
  }

  String _key(String bookId, int chapterIndex, String chapterUrl) {
    final raw = '${bookId}_${chapterIndex}_${chapterUrl.hashCode}';
    return sha1.convert(utf8.encode(raw)).toString().substring(0, 24);
  }

  /// 读取缓存（不触发网络）
  Future<String?> read(String bookId, int chapterIndex, String chapterUrl) async {
    try {
      final f = await _cacheFile(_key(bookId, chapterIndex, chapterUrl));
      if (!await f.exists()) return null;
      final stat = await f.stat();
      // 过期
      if (DateTime.now().difference(stat.modified) > _maxAge) return null;
      return f.readAsString();
    } catch (e) {
      Log.w('读章节缓存失败: $e');
      return null;
    }
  }

  /// 写入缓存
  Future<void> write(
      String bookId, int chapterIndex, String chapterUrl, String content) async {
    try {
      if (content.isEmpty) return;
      final f = await _cacheFile(_key(bookId, chapterIndex, chapterUrl));
      await f.writeAsString(content);
    } catch (e) {
      Log.w('写章节缓存失败: $e');
    }
  }

  /// 清空某本书所有缓存
  Future<void> clearBook(String bookId) async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(docs.path, _dir));
      if (!await dir.exists()) return;
      // 简单方式：删除所有满足 hash 前缀的（无法精确按bookId，所以清理全部）
      if (await dir.exists()) {
        await for (final entity in dir.list()) {
          if (entity is File) {
            try {
              await entity.delete();
            } catch (_) {}
          }
        }
      }
    } catch (e) {
      Log.w('清章节缓存失败: $e');
    }
  }

  /// 清空所有
  Future<int> clearAll() async {
    int n = 0;
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(docs.path, _dir));
      if (await dir.exists()) {
        await for (final entity in dir.list()) {
          if (entity is File) {
            try {
              await entity.delete();
              n++;
            } catch (_) {}
          }
        }
      }
    } catch (e) {
      Log.w('清空章节缓存失败: $e');
    }
    return n;
  }

  /// 估算占用
  Future<int> totalSize() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(docs.path, _dir));
      if (!await dir.exists()) return 0;
      int total = 0;
      await for (final entity in dir.list()) {
        if (entity is File) {
          try {
            total += await entity.length();
          } catch (_) {}
        }
      }
      return total;
    } catch (_) {
      return 0;
    }
  }
}
