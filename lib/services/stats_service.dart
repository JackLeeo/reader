// 阅读统计服务
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/reading_stats.dart';
import '../utils/log.dart';

class StatsService extends ChangeNotifier {
  final List<ReadingSession> _sessions = [];
  bool _initialized = false;

  bool get initialized => _initialized;

  Future<void> init() async {
    if (_initialized) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('reading_sessions');
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = jsonDecode(raw) as List;
        for (final item in list) {
          if (item is Map) {
            try {
              _sessions.add(ReadingSession.fromJson(
                  item.map((k, v) => MapEntry(k.toString(), v))));
            } catch (_) {}
          }
        }
      } catch (e) {
        Log.w('解析阅读统计失败: $e');
      }
    }
    _initialized = true;
    notifyListeners();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    // 只保留最近 90 天数据
    final cutoff = DateTime.now().subtract(const Duration(days: 90));
    _sessions.removeWhere((s) => s.date.isBefore(cutoff));
    final list = _sessions.map((s) => s.toJson()).toList();
    await prefs.setString('reading_sessions', jsonEncode(list));
    notifyListeners();
  }

  /// 记录一次阅读 session
  Future<void> record(ReadingSession s) async {
    _sessions.add(s);
    await _persist();
  }

  /// 今日累计
  DailyStats get today {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day);
    return _aggregate(start);
  }

  /// 本周累计
  DailyStats get thisWeek {
    final now = DateTime.now();
    final monday = now.subtract(Duration(days: now.weekday - 1));
    final start = DateTime(monday.year, monday.month, monday.day);
    return _aggregate(start);
  }

  /// 总累计
  DailyStats get total => _aggregate(DateTime(1970));

  /// 最近 N 天每日统计
  List<DailyStats> lastDays(int n) {
    final now = DateTime.now();
    final result = <DailyStats>[];
    for (int i = n - 1; i >= 0; i--) {
      final day = DateTime(now.year, now.month, now.day).subtract(Duration(days: i));
      result.add(_aggregate(day, dayEnd: day.add(const Duration(days: 1))));
    }
    return result;
  }

  DailyStats _aggregate(DateTime start, {DateTime? dayEnd}) {
    final end = dayEnd ?? DateTime.now();
    int totalSeconds = 0;
    int totalChars = 0;
    int totalPages = 0;
    final books = <String>{};
    for (final s in _sessions) {
      if (s.date.isBefore(start) || !s.date.isBefore(end)) continue;
      totalSeconds += s.duration.inSeconds;
      totalChars += s.charsRead;
      totalPages += s.pagesRead;
      books.add(s.bookId);
    }
    return DailyStats(
      date: start,
      totalSeconds: totalSeconds,
      totalChars: totalChars,
      totalPages: totalPages,
      booksRead: books,
    );
  }
}
