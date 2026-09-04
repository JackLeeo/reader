import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 持久化 Cookie 管理（对应官方「Cookie」/ 登录 cookie）。
///
/// 按域名存储 cookie（name=value），供书源请求与听书/图片流地址携带。
/// 与 [HttpService] 的内存会话不同，这里落盘持久，登录后可长期复用。
class CookieService {
  CookieService._();

  static final CookieService instance = CookieService._();

  static const String _prefsKey = 'persist_cookies_v1';

  /// domain -> {name: value}
  Map<String, Map<String, String>> _store = {};
  bool initialized = false;

  List<String> get domains => _store.keys.toList();

  /// 指定域名的 cookie 表。
  Map<String, String> cookiesFor(String domain) =>
      Map.unmodifiable(_store[domain] ?? const {});

  /// 是否有该域名的 cookie。
  bool hasCookie(String domain) =>
      (_store[domain] ?? const {}).isNotEmpty;

  /// 指定域名的 Cookie 请求头字符串（`a=b; c=d`）。
  String cookieHeaderFor(String domain) {
    final m = _store[domain];
    if (m == null || m.isEmpty) return '';
    return m.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  Future<void> init() async {
    if (initialized) return;
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_prefsKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final dec = jsonDecode(raw) as Map<String, dynamic>;
        _store = dec.map((k, v) =>
            MapEntry(k, Map<String, String>.from(v as Map)));
      } catch (_) {
        _store = {};
      }
    }
    initialized = true;
  }

  /// 设置单个 cookie。
  Future<void> setCookie(String domain, String name, String value) async {
    if (domain.isEmpty || name.isEmpty) return;
    _store.putIfAbsent(domain, () => {})[name] = value;
    await _persist();
  }

  /// 从 `Set-Cookie` 响应头解析并保存。
  Future<void> setCookiesFromHeader(
      String domain, List<String> setCookieHeaders) async {
    if (domain.isEmpty) return;
    final map = _store.putIfAbsent(domain, () => {});
    for (final sc in setCookieHeaders) {
      final semi = sc.indexOf(';');
      final seg = semi >= 0 ? sc.substring(0, semi) : sc;
      final eq = seg.indexOf('=');
      if (eq <= 0) continue;
      map[seg.substring(0, eq).trim()] = seg.substring(eq + 1).trim();
    }
    await _persist();
  }

  /// 从原始 cookie 字符串（`k1=v1; k2=v2`）解析并保存到 [domain]。
  ///
  /// 用于书源登录后把 WebView 的 `document.cookie`（或抓取的 Set-Cookie 原始串）
  /// 持久化。空名/无 `=` 段被忽略。
  Future<void> setCookiesFromString(String domain, String cookieStr) async {
    if (domain.isEmpty || cookieStr.trim().isEmpty) return;
    final map = _store.putIfAbsent(domain, () => {});
    for (final seg in cookieStr.split(';')) {
      final t = seg.trim();
      if (t.isEmpty) continue;
      if (t.contains('=')) {
        // 带属性的段（如 `Domain=...` / `Path=...` / `Expires=...`）忽略。
        final name = t.substring(0, t.indexOf('=')).trim();
        final low = name.toLowerCase();
        if (low == 'domain' || low == 'path' || low == 'expires' ||
            low == 'max-age' || low == 'secure' || low == 'httponly' ||
            low == 'samesite') {
          continue;
        }
        final value = t.substring(t.indexOf('=') + 1).trim();
        if (name.isNotEmpty) map[name] = value;
      }
    }
    await _persist();
  }

  /// 删除单个 cookie。
  Future<void> deleteCookie(String domain, String name) async {
    _store[domain]?.remove(name);
    if ((_store[domain] ?? {}).isEmpty) _store.remove(domain);
    await _persist();
  }

  /// 清空指定域名。
  Future<void> clearDomain(String domain) async {
    _store.remove(domain);
    await _persist();
  }

  /// 清空全部。
  Future<void> clearAll() async {
    _store = {};
    await _persist();
  }

  Future<void> _persist() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_prefsKey, jsonEncode(_store));
  }

  /// 测试用：重置。
  void reset() {
    _store = {};
    initialized = false;
  }
}
