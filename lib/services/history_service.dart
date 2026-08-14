// 历史记录
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/history_item.dart';
import '../utils/log.dart';

class HistoryService extends ChangeNotifier {
  static const _maxItems = 200;
  final List<HistoryItem> _items = [];
  bool _initialized = false;

  List<HistoryItem> get items => List.unmodifiable(_items);
  bool get initialized => _initialized;

  Future<void> init() async {
    if (_initialized) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('history_items');
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = jsonDecode(raw) as List;
        for (final item in list) {
          if (item is Map) {
            try {
              _items.add(HistoryItem.fromJson(
                  item.map((k, v) => MapEntry(k.toString(), v))));
            } catch (e) {
              Log.w('解析历史项失败: $e');
            }
          }
        }
      } catch (e) {
        Log.w('解析历史JSON失败: $e');
      }
    }
    _initialized = true;
    notifyListeners();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    final list = _items.map((i) => i.toJson()).toList();
    await prefs.setString('history_items', jsonEncode(list));
    notifyListeners();
  }

  Future<void> add(HistoryItem item) async {
    // 移除同书同章节的旧记录
    _items.removeWhere((i) => i.book.id == item.book.id);
    _items.insert(0, item);
    if (_items.length > _maxItems) {
      _items.removeRange(_maxItems, _items.length);
    }
    await _persist();
  }

  Future<void> clear() async {
    _items.clear();
    await _persist();
  }

  Future<void> remove(String bookId) async {
    _items.removeWhere((i) => i.book.id == bookId);
    await _persist();
  }
}
