// 本地书籍管理 - TXT导入 + 章节切分 + 缓存
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/local_book.dart';
import '../utils/log.dart';

/// 本地书籍服务
class LocalBookService extends ChangeNotifier {
  static const _prefsKey = 'local_books';
  static const _dir = 'local_books';

  final List<LocalBook> _books = [];
  bool _initialized = false;

  List<LocalBook> get books => List.unmodifiable(_books);
  bool get initialized => _initialized;

  Future<void> init() async {
    if (_initialized) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = jsonDecode(raw) as List;
        for (final item in list) {
          if (item is Map) {
            try {
              _books.add(LocalBook.fromJson(
                  item.map((k, v) => MapEntry(k.toString(), v))));
            } catch (e) {
              Log.w('解析本地书失败: $e');
            }
          }
        }
      } catch (e) {
        Log.w('解析本地书JSON失败: $e');
      }
    }
    _initialized = true;
    notifyListeners();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    final list = _books.map((b) => b.toJson()).toList();
    await prefs.setString(_prefsKey, jsonEncode(list));
    notifyListeners();
  }

  /// 导入一个本地TXT文件
  /// 返回 LocalBook，已存在则复用
  Future<LocalBook> importFromPath(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw '文件不存在: $filePath';
    }
    final bytes = await file.readAsBytes();
    final id = 'local_${md5.convert(bytes).toString().substring(0, 16)}';
    final existing = _books.firstWhere(
      (b) => b.id == id,
      orElse: () => LocalBook(id: id, name: '', filePath: ''),
    );
    if (existing.name.isNotEmpty) {
      return existing;
    }
    // 解码并切分章节
    final content = _decodeText(bytes);
    final name = p.basenameWithoutExtension(filePath);
    final newBook = LocalBook(
      id: id,
      name: name,
      filePath: filePath,
      fileSize: bytes.length,
    );
    _books.insert(0, newBook);
    // 写入缓存
    await _ensureCacheDir();
    final cacheFile = await _cacheFile(id);
    await cacheFile.writeAsString(content);
    await _persist();
    return newBook;
  }

  /// 读取书籍全文（已切分章节）
  Future<String> readContent(LocalBook book) async {
    final cacheFile = await _cacheFile(book.id);
    if (await cacheFile.exists()) {
      return cacheFile.readAsString();
    }
    // 缓存丢失，从原文件重新读取
    final file = File(book.filePath);
    if (!await file.exists()) return '';
    final bytes = await file.readAsBytes();
    final content = _decodeText(bytes);
    await _ensureCacheDir();
    await cacheFile.writeAsString(content);
    return content;
  }

  /// 自动章节切分
  /// 优先匹配"第X章/第X回/第X卷/Chapter X"等
  List<String> splitChapters(String content) {
    if (content.isEmpty) return const [];
    final regex = RegExp(
      r'^\s*(第[\s\S]{0,30}[章节回卷集篇部][\s\S]{0,30}|Chapter\s+\d+[\s\S]{0,30}|CHAPTER\s+[IVXLCDM]+[\s\S]{0,30})\s*$',
      multiLine: true,
    );
    final matches = regex.allMatches(content).toList();
    if (matches.length < 2) {
      // 没有切到章节，整本作为一章
      return [content];
    }
    final chapters = <String>[];
    for (int i = 0; i < matches.length; i++) {
      final start = matches[i].start;
      final end = i + 1 < matches.length ? matches[i + 1].start : content.length;
      var ch = content.substring(start, end).trim();
      if (ch.isNotEmpty) chapters.add(ch);
    }
    if (chapters.length < 2) return [content];
    return chapters;
  }

  /// 章节标题（取第一行非空）
  String chapterTitle(String chapter, int index) {
    final lines = chapter.split('\n').take(2);
    for (final l in lines) {
      final t = l.trim();
      if (t.isNotEmpty) return t.length > 40 ? '${t.substring(0, 40)}…' : t;
    }
    return '第${index + 1}章';
  }

  /// 简单字符编码探测
  /// 中文优先 GBK / GB18030, 否则 UTF-8
  String _decodeText(Uint8List bytes) {
    // 检查 UTF-8 BOM
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      return utf8.decode(bytes.sublist(3), allowMalformed: true);
    }
    // 试 UTF-8
    try {
      final s = utf8.decode(bytes, allowMalformed: false);
      // UTF-8 合法时，检查是否包含正常中文（避免 GBK 误判成 UTF-8 拿到乱码）
      if (_looksLikeChineseText(s)) return s;
    } catch (_) {}
    // 回退 GBK
    try {
      final s = gb18030.decode(bytes);
      if (s.isNotEmpty) return s;
    } catch (_) {}
    return latin1.decode(bytes);
  }

  bool _looksLikeChineseText(String s) {
    int cn = 0;
    int total = 0;
    for (final r in s.runes) {
      total++;
      if (total > 500) break;
      if (r >= 0x4E00 && r <= 0x9FFF) cn++;
    }
    return total > 0 && cn * 10 >= total; // 中文占比 >= 10%
  }

  Future<Directory> _ensureCacheDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, _dir));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<File> _cacheFile(String id) async {
    final dir = await _ensureCacheDir();
    return File(p.join(dir.path, '$id.txt'));
  }

  /// 更新阅读进度
  Future<void> updateProgress(String id, int chapterIndex, int offset) async {
    final book = _books.firstWhere(
      (b) => b.id == id,
      orElse: () => throw 'book not found',
    );
    book.lastChapterIndex = chapterIndex;
    book.lastOffset = offset;
    await _persist();
  }

  /// 删除
  Future<void> remove(String id) async {
    _books.removeWhere((b) => b.id == id);
    final cache = await _cacheFile(id);
    if (await cache.exists()) await cache.delete();
    await _persist();
  }
}
