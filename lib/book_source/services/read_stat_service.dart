import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 单本书的阅读时长统计。
class ReadStatEntry {
  ReadStatEntry({
    required this.bookKey,
    required this.title,
    this.seconds = 0,
  });

  final String bookKey;
  String title;
  int seconds;

  factory ReadStatEntry.fromJson(Map<String, dynamic> m) => ReadStatEntry(
        bookKey: (m['bookKey'] ?? '') as String,
        title: (m['title'] ?? '') as String,
        seconds: (m['seconds'] ?? 0) as int,
      );

  Map<String, dynamic> toJson() => {
        'bookKey': bookKey,
        'title': title,
        'seconds': seconds,
      };
}

/// 阅读时长统计服务（对标官方“阅读时长”）。
///
/// 以“秒”为粒度累加，持久化到本地；提供总时长、今日时长（按本地日期分桶）
/// 和按书排行。阅读器在前台且页面可见时周期性调用 [addSeconds]。
class ReadStatService {
  ReadStatService._();

  static final ReadStatService instance = ReadStatService._();

  static const String _prefsKey = 'read_stat_v1';
  static const String _todayKey = 'read_stat_today_v1';

  final Map<String, ReadStatEntry> _byBook = {};
  int _todaySeconds = 0;
  String _todayDate = '';
  bool initialized = false;

  /// 总阅读秒数（本地累计）。
  int get totalSeconds {
    var t = 0;
    for (final e in _byBook.values) {
      t += e.seconds;
    }
    return t;
  }

  /// 今日阅读秒数。
  int get todaySeconds => _todaySeconds;

  /// 按时长降序返回书目统计。
  List<ReadStatEntry> get topBooks {
    final list = _byBook.values.toList()
      ..sort((a, b) => b.seconds.compareTo(a.seconds));
    return list;
  }

  String get todayDate => _todayDate;

  Future<void> init() async {
    if (initialized) return;
    final p = await SharedPreferences.getInstance();

    final raw = p.getString(_prefsKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        _byBook.clear();
        for (final e in jsonDecode(raw) as List) {
          final entry = ReadStatEntry.fromJson(e as Map<String, dynamic>);
          _byBook[entry.bookKey] = entry;
        }
      } catch (_) {
        _byBook.clear();
      }
    }

    final todayRaw = p.getString(_todayKey);
    if (todayRaw != null && todayRaw.isNotEmpty) {
      try {
        final m = jsonDecode(todayRaw) as Map<String, dynamic>;
        _todayDate = (m['date'] ?? '') as String;
        _todaySeconds = (m['seconds'] ?? 0) as int;
      } catch (_) {
        _todayDate = '';
        _todaySeconds = 0;
      }
    }
    _rollTodayIfNeeded();
    initialized = true;
  }

  void _rollTodayIfNeeded() {
    final now = _localDateStr(DateTime.now());
    if (_todayDate != now) {
      _todayDate = now;
      _todaySeconds = 0;
    }
  }

  static String _localDateStr(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// 累加阅读时长（秒）。
  void addSeconds(String bookKey, {String title = '', int seconds = 1}) {
    if (seconds <= 0) return;
    final entry = _byBook.putIfAbsent(
        bookKey, () => ReadStatEntry(bookKey: bookKey, title: title));
    if (title.isNotEmpty) entry.title = title;
    entry.seconds += seconds;
    _rollTodayIfNeeded();
    _todaySeconds += seconds;
    save();
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(
        _prefsKey, jsonEncode(_byBook.values.map((e) => e.toJson()).toList()));
    await p.setString(_todayKey, jsonEncode({
          'date': _todayDate,
          'seconds': _todaySeconds,
        }));
  }

  void clear() {
    _byBook.clear();
    _todaySeconds = 0;
    _todayDate = '';
  }
}
