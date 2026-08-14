// 书源健康检查服务
//
// 职责:
//   1. 后台检测每个书源是否可达 (HTTP 探测 bookSourceUrl 根路径)
//   2. 检测失败的书源默认禁用 (受 SettingsService.invalidAutoDisable 控制)
//   3. 检测结果落盘 SharedPreferences, 启动时优先读取, 避免冷启动长时间加载
//   4. 暴露检测进度给 UI (书源管理页可以显示 ✓/✗/待检测)
import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/book_source.dart';
import '../utils/log.dart';
import 'book_source_service.dart';

/// 单次检测结果
class SourceCheckResult {
  final String sourceId;
  final bool ok;
  final String? error;
  final int statusCode;
  final int elapsedMs;

  SourceCheckResult({
    required this.sourceId,
    required this.ok,
    this.error,
    required this.statusCode,
    required this.elapsedMs,
  });
}

class SourceHealthService extends ChangeNotifier {
  static const _prefsPrefix = 'source_health_';
  static const _lastBatchKey = 'source_health_last_batch';
  static const _checkIntervalHours = 6; // 距上次检查超过 6 小时才重新探测

  final BookSourceService _bookSourceService;

  /// 是否正在批量检测中
  bool _checking = false;
  bool get isChecking => _checking;

  /// 已检测数量
  int _checkedCount = 0;
  int get checkedCount => _checkedCount;

  /// 总数
  int _totalCount = 0;
  int get totalCount => _totalCount;

  /// 上次批量检测完成时间
  DateTime? _lastBatchFinishedAt;
  DateTime? get lastBatchFinishedAt => _lastBatchFinishedAt;

  /// 自定义 Dio (短超时, 不走书源 header)
  late final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 4),
    receiveTimeout: const Duration(seconds: 6),
    sendTimeout: const Duration(seconds: 4),
    followRedirects: true,
    validateStatus: (s) => s != null && s < 500,
    headers: const {
      'User-Agent':
          'Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1',
      'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
    },
  ));

  SourceHealthService(this._bookSourceService);

  /// 初始化: 从 SharedPreferences 恢复上次检测结果
  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final lastBatchMs = prefs.getInt(_lastBatchKey);
      if (lastBatchMs != null) {
        _lastBatchFinishedAt =
            DateTime.fromMillisecondsSinceEpoch(lastBatchMs);
      }
      for (final s in _bookSourceService.sources) {
        final raw = prefs.getString('$_prefsPrefix${s.id}');
        if (raw == null) {
          s.healthStatus = 0;
          continue;
        }
        try {
          final map = jsonDecode(raw) as Map;
          s.healthStatus = (map['status'] as int?) ?? 0;
          s.healthError = map['error'] as String?;
          final ts = map['checkedAt'] as int?;
          s.healthCheckedAt =
              ts != null ? DateTime.fromMillisecondsSinceEpoch(ts) : null;
        } catch (_) {}
      }
      Log.i('SourceHealthService init: 已恢复 ${_bookSourceService.sources.length} 源状态');
    } catch (e) {
      Log.w('恢复健康检查状态失败: $e');
    }
  }

  /// 启动时调用: 如果距上次批量检测超过阈值, 后台跑一次
  /// autoDisableWhenFail: 由 SettingsService.invalidAutoDisable 决定
  Future<void> runOnStartupIfNeeded({required bool autoDisableWhenFail}) async {
    final now = DateTime.now();
    final needCheck = _lastBatchFinishedAt == null ||
        now.difference(_lastBatchFinishedAt!).inHours >= _checkIntervalHours;
    if (!needCheck) {
      Log.i('启动检测跳过: 距上次 ${now.difference(_lastBatchFinishedAt!).inMinutes} 分钟');
      return;
    }
    // 异步执行, 不阻塞 UI
    unawaited(checkAll(autoDisableWhenFail: autoDisableWhenFail));
  }

  /// 全量检测: 并发 4, 自动禁用失效源 (受开关控制)
  Future<List<SourceCheckResult>> checkAll({
    required bool autoDisableWhenFail,
  }) async {
    if (_checking) {
      Log.w('checkAll: 已在检测中, 跳过');
      return const [];
    }
    _checking = true;
    _checkedCount = 0;
    _totalCount = _bookSourceService.sources.length;
    notifyListeners();

    final results = <SourceCheckResult>[];
    try {
      final all = _bookSourceService.sources;
      // 批次并发 (每批 4 个)
      const concurrency = 4;
      for (var i = 0; i < all.length; i += concurrency) {
        final batch = <Future<SourceCheckResult>>[];
        final end = (i + concurrency).clamp(0, all.length);
        for (var j = i; j < end; j++) {
          batch.add(_checkOneWithCount(all[j]));
        }
        await Future.wait(batch);
      }

      // 收集所有结果
      for (final s in all) {
        results.add(SourceCheckResult(
          sourceId: s.id,
          ok: s.healthStatus == 1,
          error: s.healthError,
          statusCode: 0,
          elapsedMs: 0,
        ));
      }

      _lastBatchFinishedAt = DateTime.now();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
          _lastBatchKey, _lastBatchFinishedAt!.millisecondsSinceEpoch);

      // 自动禁用失效源
      if (autoDisableWhenFail) {
        await _autoDisableFailed(all);
      }

      Log.i(
          '全量检测完成: ${all.length} 源, 健康 ${all.where((s) => s.healthStatus == 1).length}, 失效 ${all.where((s) => s.healthStatus == 2).length}');
    } catch (e, st) {
      Log.e('全量检测异常', error: e, stack: st);
    } finally {
      _checking = false;
      notifyListeners();
    }
    return results;
  }

  Future<SourceCheckResult> _checkOneWithCount(BookSource s) async {
    final r = await _checkOne(s);
    _checkedCount++;
    notifyListeners();
    return r;
  }

  /// 单源检测
  Future<SourceCheckResult> _checkOne(BookSource s) async {
    final start = DateTime.now();
    try {
      // 探测 bookSourceUrl 根路径
      final resp = await _dio.get<dynamic>(s.bookSourceUrl);
      final elapsed = DateTime.now().difference(start).inMilliseconds;
      final status = resp.statusCode ?? 0;
      // 任何 2xx/3xx/4xx 视为"主机可达" (4xx 说明服务器在响应)
      if (status > 0 && status < 500) {
        await _persist(s, status: 1, error: null);
        return SourceCheckResult(
            sourceId: s.id, ok: true, statusCode: status, elapsedMs: elapsed);
      }
      final err = 'HTTP $status';
      await _persist(s, status: 2, error: err);
      return SourceCheckResult(
          sourceId: s.id, ok: false, error: err, statusCode: status, elapsedMs: elapsed);
    } on DioException catch (e) {
      final elapsed = DateTime.now().difference(start).inMilliseconds;
      final err = _dioErrorMsg(e);
      await _persist(s, status: 2, error: err);
      return SourceCheckResult(
          sourceId: s.id, ok: false, error: err, statusCode: 0, elapsedMs: elapsed);
    } catch (e) {
      final elapsed = DateTime.now().difference(start).inMilliseconds;
      await _persist(s, status: 2, error: e.toString());
      return SourceCheckResult(
          sourceId: s.id,
          ok: false,
          error: e.toString(),
          statusCode: 0,
          elapsedMs: elapsed);
    }
  }

  String _dioErrorMsg(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
        return '连接超时';
      case DioExceptionType.sendTimeout:
        return '发送超时';
      case DioExceptionType.receiveTimeout:
        return '响应超时';
      case DioExceptionType.badResponse:
        return 'HTTP ${e.response?.statusCode ?? "?"}';
      case DioExceptionType.connectionError:
        return '连接失败';
      case DioExceptionType.cancel:
        return '已取消';
      default:
        return e.message ?? '未知错误';
    }
  }

  /// 手动单源重测 (UI 调用)
  Future<SourceCheckResult> recheckOne(BookSource s) async {
    final r = await _checkOne(s);
    // 重测完成后立即通知 UI
    notifyListeners();
    return r;
  }

  /// 持久化单源状态
  Future<void> _persist(BookSource s,
      {required int status, String? error}) async {
    s.healthStatus = status;
    s.healthError = error;
    s.healthCheckedAt = DateTime.now();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      '$_prefsPrefix${s.id}',
      jsonEncode({
        'status': status,
        'error': error,
        'checkedAt': s.healthCheckedAt!.millisecondsSinceEpoch,
      }),
    );
  }

  /// 自动禁用失效源 (仅在已启用且检测失败的源上操作)
  Future<void> _autoDisableFailed(List<BookSource> sources) async {
    final toDisable = <String>[];
    for (final s in sources) {
      if (s.healthStatus == 2 && s.isEnabled) {
        s.isEnabled = false;
        toDisable.add(s.id);
      }
    }
    if (toDisable.isEmpty) return;
    Log.w('自动禁用失效源: ${toDisable.length} 个');
    // 合并到 disabled_sources 列表 (不去重已存在的)
    final prefs = await SharedPreferences.getInstance();
    final disabled =
        (prefs.getStringList('disabled_sources') ?? <String>[]).toSet();
    disabled.addAll(toDisable);
    await prefs.setStringList('disabled_sources', disabled.toList());
    _bookSourceService.notifyChanged();
  }
}
