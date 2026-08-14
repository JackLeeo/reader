// 书架服务 - 持久化收藏的书籍
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/shelf_book.dart';
import '../utils/log.dart';

class ShelfService extends ChangeNotifier {
  final List<ShelfBook> _books = [];
  bool _initialized = false;

  List<ShelfBook> get books => List.unmodifiable(_books);
  bool get initialized => _initialized;

  Future<void> init() async {
    if (_initialized) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('shelf_books');
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = jsonDecode(raw) as List;
        for (final item in list) {
          if (item is Map) {
            try {
              _books.add(ShelfBook.fromJson(
                  item.map((k, v) => MapEntry(k.toString(), v))));
            } catch (e) {
              Log.w('解析书架项失败: $e');
            }
          }
        }
      } catch (e) {
        Log.w('解析书架JSON失败: $e');
      }
    }
    _books.sort((a, b) {
      final at = a.lastReadTime ?? a.addTime;
      final bt = b.lastReadTime ?? b.addTime;
      return bt.compareTo(at);
    });
    _initialized = true;
    notifyListeners();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    final list = _books.map((b) => b.toJson()).toList();
    await prefs.setString('shelf_books', jsonEncode(list));
    notifyListeners();
  }

  /// 添加到书架（若已存在则不重复添加）
  Future<void> add(ShelfBook book) async {
    if (_books.any((b) => b.id == book.id)) {
      // 已存在，更新
      final idx = _books.indexWhere((b) => b.id == book.id);
      _books[idx] = book;
    } else {
      _books.insert(0, book);
    }
    await _persist();
  }

  Future<void> remove(String id) async {
    _books.removeWhere((b) => b.id == id);
    await _persist();
  }

  Future<void> updateProgress(String id,
      {int? chapterIndex, int? offset, int? totalChapters, DateTime? lastReadTime}) async {
    final book = _books.firstWhere((b) => b.id == id, orElse: () => throw 'not found');
    if (chapterIndex != null) book.lastChapterIndex = chapterIndex;
    if (offset != null) book.lastOffset = offset;
    if (totalChapters != null) book.totalChapters = totalChapters;
    book.lastReadTime = lastReadTime ?? DateTime.now();
    await _persist();
  }

  bool contains(String id) => _books.any((b) => b.id == id);

  ShelfBook? findById(String id) {
    try {
      return _books.firstWhere((b) => b.id == id);
    } catch (_) {
      return null;
    }
  }
}
