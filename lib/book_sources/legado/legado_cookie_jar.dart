// 文件说明：Legado 书源 Cookie 管理，按域隔离存储、请求时回传
// Cookie 头、解析 Set-Cookie 更新，并持久化到 SharedPreferences。
// 技术要点：Cookie 解析、SharedPreferences。

import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

class LegadoCookieJar {
  LegadoCookieJar._();

  static LegadoCookieJar? _instance;

  /// 全局共享实例（书源语义与浏览器一致：同域共享 Cookie）。
  static LegadoCookieJar get instance => _instance ??= LegadoCookieJar._();

  static const String _preferencePrefix = 'legado_cookie_jar_';

  final Map<String, Map<String, String>> _domains = {};
  final Set<String> _loadedDomains = {};
  bool _flushScheduled = false;

  /// 生成请求 Cookie 头；已有 [manualCookie]（书源自带）优先合并。
  String headerFor(Uri uri, {String? manualCookie}) {
    final cookies = _loadDomain(_domainKey(uri));
    final merged = <String, String>{};
    for (final entry in _allParentDomains(uri)) {
      merged.addAll(_loadDomain(entry));
    }
    merged.addAll(cookies);
    if (manualCookie != null && manualCookie.trim().isNotEmpty) {
      for (final pair in manualCookie.split(';')) {
        final separator = pair.indexOf('=');
        if (separator <= 0) continue;
        merged[pair.substring(0, separator).trim()] = pair
            .substring(separator + 1)
            .trim();
      }
    }
    return merged.entries
        .map((entry) => '${entry.key}=${entry.value}')
        .join('; ');
  }

  /// 解析响应 Set-Cookie 头并保存。
  void storeFromResponse(Uri uri, List<String> setCookies) {
    if (setCookies.isEmpty) return;
    final key = _domainKey(uri);
    final domain = _loadDomain(key);
    for (final raw in setCookies) {
      final body = raw.split(';').first.trim();
      final separator = body.indexOf('=');
      if (separator <= 0) continue;
      final name = body.substring(0, separator).trim();
      final value = body.substring(separator + 1).trim();
      if (name.isEmpty) continue;
      if (value.isEmpty) {
        domain.remove(name);
      } else {
        domain[name] = value;
      }
    }
    _domains[key] = domain;
    _scheduleFlush();
  }

  /// 书源 JS 桥：读取指定 URL 的 Cookie 串。
  String cookiesForUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return '';
    return headerFor(uri);
  }

  /// 导出 `host -> Cookie 头` 快照，供 JS 桥的 getCookies 同步读取。
  Map<String, String> cookieHeaderSnapshot() {
    final snapshot = <String, String>{};
    for (final entry in _domains.entries) {
      final header = entry.value.entries
          .map((cookie) => '${cookie.key}=${cookie.value}')
          .join('; ');
      if (header.isNotEmpty) snapshot[entry.key] = header;
    }
    return snapshot;
  }

  /// 书源 JS 桥：写入 k=v 到指定 URL 的域。
  void setCookie(String url, String name, String value) {
    final uri = Uri.tryParse(url);
    if (uri == null || name.isEmpty) return;
    final key = _domainKey(uri);
    final domain = _loadDomain(key);
    domain[name] = value;
    _domains[key] = domain;
    _scheduleFlush();
  }

  String _domainKey(Uri uri) =>
      (uri.host.isEmpty ? '' : uri.host).toLowerCase();

  List<String> _allParentDomains(Uri uri) {
    final host = _domainKey(uri);
    if (!host.contains('.')) return const [];
    final parts = host.split('.');
    return [
      for (var i = 1; i < parts.length - 1; i++) parts.sublist(i).join('.'),
    ];
  }

  Map<String, String> _loadDomain(String key) {
    if (_domains.containsKey(key)) return _domains[key]!;
    if (!_loadedDomains.contains(key)) {
      _loadedDomains.add(key);
      _unawaitedPrefRead(key);
    }
    // 首次异步读取前先返回空，后续请求自然带上。
    return _domains.putIfAbsent(key, () => {});
  }

  Future<void> _unawaitedPrefRead(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('$_preferencePrefix$key');
      if (raw == null || raw.isEmpty) return;
      final decoded = _decode(raw);
      if (decoded != null) {
        final existing = _domains[key] ?? {};
        existing.addAll(decoded);
        _domains[key] = existing;
      }
    } catch (_) {
      // Cookie 读取失败静默降级为内存模式。
    }
  }

  void _scheduleFlush() {
    if (_flushScheduled) return;
    _flushScheduled = true;
    Timer(const Duration(seconds: 2), _flush);
  }

  Future<void> _flush() async {
    _flushScheduled = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final entry in _domains.entries) {
        await prefs.setString(
          '$_preferencePrefix${entry.key}',
          _encode(entry.value),
        );
      }
    } catch (_) {
      // 持久化失败静默降级为内存模式。
    }
  }

  static String _encode(Map<String, String> cookies) {
    return cookies.entries
        .map((entry) => '${_escape(entry.key)}=${_escape(entry.value)}')
        .join('\n');
  }

  static Map<String, String>? _decode(String raw) {
    if (raw.isEmpty) return null;
    final result = <String, String>{};
    for (final line in raw.split('\n')) {
      final separator = line.indexOf('=');
      if (separator <= 0) continue;
      result[_unescape(line.substring(0, separator))] = _unescape(
        line.substring(separator + 1),
      );
    }
    return result;
  }

  static String _escape(String value) => value
      .replaceAll(r'\', r'\\')
      .replaceAll('=', r'\e')
      .replaceAll('\n', r'\n');

  static String _unescape(String value) => value
      .replaceAll(r'\n', '\n')
      .replaceAll(r'\e', '=')
      .replaceAll(r'\\', r'\');
}
