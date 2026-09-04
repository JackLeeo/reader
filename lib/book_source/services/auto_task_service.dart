import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../js/fjs_engine.dart';
import 'rss_service.dart';
import 'shelf_service.dart';
import 'shelf_update_service.dart';

/// 自动任务（对应官方 `AutoTask`）。
///
/// 一组可配置的定时任务：启用后按 [intervalMin]（分钟）周期触发 [action]。
class AutoTask {
  AutoTask({
    required this.name,
    this.enabled = true,
    this.intervalMin = 60,
    this.action = 'notify',
    this.lastRunAt,
    this.script,
    this.cron,
  });

  /// 任务名（唯一标识）。
  final String name;

  /// 是否启用。
  final bool enabled;

  /// 执行间隔（分钟）。与 [cron] 至少其一生效（cron 优先）。
  final int intervalMin;

  /// 动作标识：`refresh_rss`/`check_shelf`/`run_js`/`notify`。
  final String action;

  /// `run_js` 动作的脚本内容（QuickJS/fjs 执行）。
  final String? script;

  /// 5 字段 cron 表达式（`分 时 日 月 周`）；非空时按 cron 触发（忽略 intervalMin）。
  final String? cron;

  /// 上次执行时间。
  final DateTime? lastRunAt;

  AutoTask copyWith({bool? enabled, DateTime? lastRunAt}) => AutoTask(
        name: name,
        enabled: enabled ?? this.enabled,
        intervalMin: intervalMin,
        action: action,
        script: script,
        cron: cron,
        lastRunAt: lastRunAt ?? this.lastRunAt,
      );

  factory AutoTask.fromJson(Map<String, dynamic> m) {
    final last = m['lastRunAt'];
    return AutoTask(
      name: (m['name'] ?? '') as String,
      enabled: (m['enabled'] as bool?) ?? true,
      intervalMin: (m['intervalMin'] as int?) ?? 60,
      action: (m['action'] ?? 'notify') as String,
      script: m['script'] as String?,
      cron: m['cron'] as String?,
      lastRunAt: last is int
          ? DateTime.fromMillisecondsSinceEpoch(last, isUtc: true)
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'enabled': enabled,
        'intervalMin': intervalMin,
        'action': action,
        'script': script,
        'cron': cron,
        'lastRunAt': lastRunAt?.millisecondsSinceEpoch,
      };
}

/// 自动任务服务：任务的增删改查、持久化与定时调度。
///
/// - 持久化到 prefs key `auto_tasks_v1`
/// - [dueTasks] 根据 enabled + 间隔判断是否有到期任务
/// - [runTask] 执行动作并更新 lastRunAt，动作失败容错不抛异常
/// - [tick] 找出到期任务并逐个执行
class AutoTaskService {
  AutoTaskService._();

  static final AutoTaskService instance = AutoTaskService._();

  static const String _prefsKey = 'auto_tasks_v1';

  final List<AutoTask> _tasks = [];
  bool initialized = false;

  /// 全部任务。
  List<AutoTask> get tasks => List.unmodifiable(_tasks);

  Future<void> init() async {
    if (initialized) return;
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_prefsKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        _tasks
          ..clear()
          ..addAll((jsonDecode(raw) as List)
              .map((e) => AutoTask.fromJson(e as Map<String, dynamic>)));
      } catch (_) {
        _tasks.clear();
      }
    }
    initialized = true;
  }

  /// 重置内存状态并重新初始化（测试用）。
  void clear() {
    _tasks.clear();
    initialized = false;
  }

  /// 新增任务（同名覆盖）。
  void addTask(AutoTask task) {
    final idx = _tasks.indexWhere((t) => t.name == task.name);
    if (idx >= 0) {
      _tasks[idx] = task;
    } else {
      _tasks.add(task);
    }
    save();
  }

  /// 更新任务（同名覆盖）。
  void updateTask(AutoTask task) => addTask(task);

  /// 删除任务。
  void removeTask(String name) {
    _tasks.removeWhere((t) => t.name == name);
    save();
  }

  /// 按名字取任务。
  AutoTask? taskByName(String name) {
    for (final t in _tasks) {
      if (t.name == name) return t;
    }
    return null;
  }

  /// 周期内是否已过期（从 [lastRunAt] 起算 [intervalMin] 分钟；[task.cron] 优先）。
  bool _isDue(AutoTask task, [DateTime? now]) {
    if (!task.enabled) return false;
    final current = now ?? DateTime.now();
    if ((task.cron ?? '').trim().isNotEmpty) {
      return _cronMatches(task.cron!.trim(), current) &&
          !_ranInMinute(task, current);
    }
    if (task.intervalMin <= 0) return false;
    final last = task.lastRunAt;
    if (last == null) return true; // 从未执行过视为到期
    final due = last.add(Duration(minutes: task.intervalMin));
    return current.toUtc().isAfter(due);
  }

  bool _ranInMinute(AutoTask task, DateTime now) {
    final last = task.lastRunAt;
    if (last == null) return false;
    final l = last.toLocal();
    return l.year == now.year &&
        l.month == now.month &&
        l.day == now.day &&
        l.hour == now.hour &&
        l.minute == now.minute;
  }

  /// 判断本地时间 [t] 是否命中 5 字段 cron（`分 时 日 月 周`）。
  ///
  /// 支持 `*`、数字、逗号列表、区间 `a-b` 与步长 `a/step`；`日/周` 任一命中即视为
  /// 命中（对齐常见 cron 语义）。
  static bool _cronMatches(String expr, DateTime t) {
    final parts = expr.trim().split(RegExp(r'\s+'));
    if (parts.length != 5) return false;
    final domT = t.day;
    final monT = t.month;
    final dowT = t.weekday % 7; // cron 周日=0，Flutter weekday 周日=7
    if (!_fieldOk(parts[0], t.minute)) return false;
    if (!_fieldOk(parts[1], t.hour)) return false;
    if (!_fieldOk(parts[2], domT)) return false;
    if (!_fieldOk(parts[3], monT)) return false;
    // 日/周：两字段均具体时取 OR
    if (!_fieldOk(parts[2], domT) && !_fieldOk(parts[4], dowT)) return false;
    return true;
  }

  static bool _fieldOk(String field, int v) {
    final f = field.trim();
    if (f == '*') return true;
    var matched = false;
    for (final seg in f.split(',')) {
      final s = seg.trim();
      if (s.isEmpty) continue;
      String base = s;
      final slash = s.indexOf('/');
      var step = 1;
      if (slash >= 0) {
        final sStep = int.tryParse(s.substring(slash + 1).trim());
        step = sStep ?? 1;
        base = s.substring(0, slash).trim();
      }
      var lo = -1;
      var hi = -1;
      final dash = base.indexOf('-');
      if (dash >= 0 && !base.startsWith('-')) {
        lo = int.tryParse(base.substring(0, dash).trim()) ?? -1;
        hi = int.tryParse(base.substring(dash + 1).trim()) ?? -1;
      } else {
        final single = int.tryParse(base);
        if (single != null) {
          lo = single;
          hi = single;
        }
      }
      if (lo < 0 || hi < 0) continue;
      if (v >= lo && v <= hi && (v - lo) % step == 0) matched = true;
    }
    return matched;
  }

  /// 返回当前应执行的任务。
  List<AutoTask> dueTasks() => _tasks.where(_isDue).toList();

  /// 执行单个任务动作，成功后更新 [AutoTask.lastRunAt] 并持久化。
  ///
  /// 动作执行失败容错，不抛异常。
  Future<void> runTask(AutoTask task) async {
    try {
      switch (task.action) {
        case 'refresh_rss':
          // 刷新所有 RSS 订阅（逐条抓取，失败单条忽略）
          for (final url in RssService.instance.urls) {
            try {
              await RssService.instance.fetch(url);
            } catch (_) {
              // 单条失败忽略，继续下一条
            }
          }
          break;
        case 'check_shelf':
          // 检测书架所有网络书的新章节，结果由 ShelfUpdateService 通知 UI。
          final shelf = ShelfService.instance;
          await ShelfUpdateService.instance.checkAll(
            shelf.books.where((b) => !b.isLocal).toList(),
          );
          break;
        case 'run_js':
          // 执行用户脚本（QuickJS/fjs）。失败静默。
          final code = (task.script ?? '').trim();
          if (code.isNotEmpty) {
            await FjsJsEngine.instance.ensureReady();
            if (FjsJsEngine.instance.isAvailable) {
              await FjsJsEngine.instance.evaluate(code);
            }
          }
          break;
        case 'notify':
        default:
          // 占位动作，无需业务逻辑
          break;
      }
    } catch (_) {
      // 整体容错
    }
    // 无论动作成功与否都更新执行时间，避免频繁重试
    final updated = task.copyWith(lastRunAt: DateTime.now().toUtc());
    final idx = _tasks.indexWhere((t) => t.name == updated.name);
    if (idx >= 0) _tasks[idx] = updated;
    await save();
  }

  /// 调度：找出到期任务并逐个执行。
  Future<void> tick() async {
    for (final task in dueTasks()) {
      try {
        await runTask(task);
      } catch (_) {
        // 容错：单个任务失败不中断其余任务
      }
    }
  }

  /// 立即持久化。
  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(
        _prefsKey, jsonEncode(_tasks.map((t) => t.toJson()).toList()));
  }
}