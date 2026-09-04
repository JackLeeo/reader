import 'dart:async';

import 'dart:io';

/// 网络时钟服务（对齐官方“NTP 校时”）。
///
/// 通过请求目标站并读取 `Date` 响应头估算服务器与本地时钟的偏差，
/// 供依赖服务器时间的功能（如章节内嵌发布时间、留言时间戳对齐）使用。
///
/// 结果带 TTL 缓存，避免频繁请求。
class ClockService {
  ClockService._();
  static final ClockService instance = ClockService._();

  static const Duration _ttl = Duration(minutes: 10);
  static const Duration _timeout = Duration(seconds: 5);

  DateTime? _offsetAt;
  Duration? _offset;

  /// 最近一次实测得到的 服务器时间 − 本地时间 偏移。
  Duration? get offset => _offset;

  /// 当前“网络时间”（有缓存偏移且有可用缓存源时）。
  ///
  /// 返回 null 表示尚未校时成功。
  DateTime? get networkNow {
    final off = _offset;
    if (off == null) return null;
    return DateTime.now().toUtc().add(off);
  }

  /// 强制刷新一次校时（失败返回 false 并保留旧值）。
  Future<bool> syncNow({Uri? source}) async {
    final target = source ??
        Uri.parse('https://www.baidu.com/');
    try {
      final client = HttpClient();
      client.badCertificateCallback = (_, _, _) => true;
      final req = await client
          .getUrl(target)
          .timeout(_timeout);
      final resp = await req.close().timeout(_timeout);
      final local = DateTime.now().toUtc();
      final date = resp.headers.value(HttpHeaders.dateHeader);
      await resp.drain<void>();
      client.close(force: true);
      if (date == null) return false;
      final server = HttpDate.parse(date);
      final off = server.difference(local);
      // 拒绝明显异常的偏移（> 1 天），多半是缓存/重定向所致。
      if (off.abs() > const Duration(days: 1)) return false;
      _offset = off;
      _offsetAt = DateTime.now();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 幂等获取偏移：过期才会重新请求。
  Future<Duration?> get currentOffset => _offsetIfFresh() != null
      ? Future.value(_offset)
      : syncNow().then((ok) => ok ? _offset : null);

  Duration? _offsetIfFresh() {
    final at = _offsetAt;
    if (at == null) return null;
    if (DateTime.now().difference(at) > _ttl) return null;
    return _offset;
  }

  /// 取整到分钟：便于展示“服务器与本地时差”。
  Duration get roundedOffset {
    final off = _offset ?? Duration.zero;
    final minutes = (off.inMinutes);
    return Duration(minutes: minutes);
  }
}