// 书签服务
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/bookmark.dart';
import '../utils/log.dart';

class BookmarkService extends ChangeNotifier {
  final List<Bookmark> _all = [];
  bool _initialized = false;

  List<Bookmark> get all => List.unmodifiable(_all);
  bool get initialized => _initialized;

  Future<void> init() async {
    if (_initialized) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('bookmarks');
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = jsonDecode(raw) as List;
        for (final item in list) {
          if (item is Map) {
            try {
              _all.add(Bookmark.fromJson(
                  item.map((k, v) => MapEntry(k.toString(), v))));
            } catch (e) {
              Log.w('解析书签失败: $e');
            }
          }
        }
      } catch (e) {
        Log.w('解析书签JSON失败: $e');
      }
    }
    _all.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    _initialized = true;
    notifyListeners();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    final list = _all.map((b) => b.toJson()).toList();
    await prefs.setString('bookmarks', jsonEncode(list));
    notifyListeners();
  }

  /// 添加书签
  Future<void> add(Bookmark b) async {
    _all.removeWhere((e) => e.key == b.key);
    _all.insert(0, b);
    await _persist();
  }

  /// 删除书签
  Future<void> remove(String key) async {
    _all.removeWhere((e) => e.key == key);
    await _persist();
  }

  /// 获取某本书的书签
  List<Bookmark> forBook(String bookId) {
    return _all.where((b) => b.bookId == bookId).toList();
  }

  /// 检查某位置是否已有书签
  bool hasAt(String bookId, int chapterIndex, int offset) {
    return _all.any(
        (b) => b.bookId == bookId && b.chapterIndex == chapterIndex && b.offset == offset);
  }
}
