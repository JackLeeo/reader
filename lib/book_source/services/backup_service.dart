import 'dart:convert';

import '../models/book_source.dart';
import 'shelf_service.dart';
import 'book_source_service.dart';
import 'auto_task_service.dart';
import 'dict_service.dart';
import 'replace_rule_service.dart';
import 'rss_service.dart';

/// 备份 / 恢复（对应官方“备份到本地/从备份恢复”）。
///
/// 跨平台版以 JSON 字符串为载体（剪贴板粘贴/导出），
/// 聚合书源 + 书架一次导出，可整体恢复。
class BackupService {
  BackupService._();

  static final BackupService instance = BackupService._();

  static const int _version = 1;

  /// 生成全量备份 JSON 字符串。
  String export() {
    final map = <String, dynamic>{
      'legado_export': true,
      'version': _version,
      'exportTime': DateTime.now().millisecondsSinceEpoch,
      'bookSources':
          BookSourceService.instance.sources.map((s) => s.toJson()).toList(),
      'shelf':
          ShelfService.instance.books.map((b) => b.toJson()).toList(),
      // 扩展数据（对齐官方备份范围，缺失字段时恢复侧自动跳过）。
      'rss': {
        'urls': RssService.instance.urls,
        'sources': RssService.instance.sources.map((s) => s.toJson()).toList(),
        'favs': RssService.instance.favorites.toList(),
      },
      'dict':
          DictService.instance.sources.map((s) => s.toJson()).toList(),
      'replaceRules': ReplaceRuleService.instance.rules
          .map((r) => r.toJson())
          .toList(),
      'autoTasks':
          AutoTaskService.instance.tasks.map((t) => t.toJson()).toList(),
    };
    return jsonEncode(map);
  }

  /// 恢复备份。返回 (书源数, 书架数)。
  ({int sources, int shelf}) import(String jsonStr) {
    final dynamic decoded;
    try {
      decoded = jsonDecode(jsonStr);
    } catch (_) {
      throw const FormatException('无法解析备份内容');
    }
    final root = decoded is Map ? decoded : null;
    // 兼容纯书源数组旧备份
    if (decoded is List) {
      final n = BookSourceService.instance.importAll(
        decoded.map((e) => BookSource.fromJson(Map<String, dynamic>.from(e))).toList(),
      );
      BookSourceService.instance.save();
      return (sources: n, shelf: 0);
    }
    if (root == null) throw const FormatException('备份格式不正确');

    var sourceCount = 0;
    if (root['bookSources'] is List) {
      final list = (root['bookSources'] as List)
          .map((e) => BookSource.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      sourceCount = BookSourceService.instance.importAll(list);
      BookSourceService.instance.save();
    }

    final shelfItems = (root['shelf'] as List?) ?? const [];
    var added = 0;
    for (final e in shelfItems) {
      final b = ShelfBook.fromJson(Map<String, dynamic>.from(e));
      if (ShelfService.instance.addBook(b)) added++;
    }
    ShelfService.instance.save();

    // RSS 订阅（url + 规则源 + 收藏）。
    final rss = root['rss'];
    if (rss is Map) {
      for (final u in (rss['urls'] as List? ?? const [])) {
        RssService.instance.addFeed(u.toString());
      }
      for (final e in (rss['sources'] as List? ?? const [])) {
        RssService.instance
            .addSource(RssSource.fromJson(Map<String, dynamic>.from(e as Map)));
      }
      for (final f in (rss['favs'] as List? ?? const [])) {
        final s = f.toString();
        final idx = s.indexOf('|');
        final feed = idx >= 0 ? s.substring(0, idx) : s;
        final link = idx >= 0 ? s.substring(idx + 1) : s;
        RssService.instance
            .toggleFavorite(feed, RssItem(title: link, link: link, description: ''));
      }
      RssService.instance.save();
    }

    // 词典源。
    for (final e in (root['dict'] as List? ?? const [])) {
      DictService.instance
          .addSource(DictSource.fromJson(Map<String, dynamic>.from(e as Map)));
    }
    DictService.instance.save();

    // 替换规则。
    for (final e in (root['replaceRules'] as List? ?? const [])) {
      ReplaceRuleService.instance
          .upsert(ReplaceRule.fromJson(Map<String, dynamic>.from(e as Map)));
    }

    // 自动任务。
    for (final e in (root['autoTasks'] as List? ?? const [])) {
      AutoTaskService.instance
          .addTask(AutoTask.fromJson(Map<String, dynamic>.from(e as Map)));
    }

    return (sources: sourceCount, shelf: added);
  }
}