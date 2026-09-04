import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 全局网络代理配置（对应官方「代理设置」）。
///
/// 支持 HTTP/HTTPS（`PROXY`)与 SOCKS5（`SOCKS`)，交由 dart:io `findProxy` 分发；
/// 认证字段（HTTP Proxy-Authorization / SOCKS5 用户名密码）保存于此，
/// 实际握手由请求层按需注入。
class ProxyService {
  ProxyService._();

  static final ProxyService instance = ProxyService._();

  static const String _prefsKey = 'proxy_config_v1';

  static const String kTypeHttp = 'http';
  static const String kTypeSocks5 = 'socks5';

  bool _enabled = false;
  String _host = '';
  int _port = 0;
  String _type = kTypeHttp;
  String _username = '';
  String _password = '';
  bool initialized = false;

  bool get enabled => _enabled;
  String get host => _host;
  int get port => _port;

  /// 代理类型：`http` 或 `socks5`。
  String get type => _type;
  String get username => _username;
  String get password => _password;

  /// 是否配置了可用代理。
  bool get isConfigured =>
      _enabled && _host.trim().isNotEmpty && _port > 0 && _port <= 65535;

  /// 生成 dart:io `findProxy` 返回的代理字符串；未启用返回 `DIRECT`。
  String get proxyDirective {
    if (!isConfigured) return 'DIRECT';
    return _type == kTypeSocks5
        ? 'SOCKS ${_host.trim()}:$_port'
        : 'PROXY ${_host.trim()}:$_port';
  }

  /// 是否启用代理且配置了账号密码（供请求层注入认证头）。
  bool get hasAuth => isConfigured && _username.isNotEmpty;

  Future<void> init() async {
    if (initialized) return;
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_prefsKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final m = jsonDecode(raw) as Map<String, dynamic>;
        _enabled = (m['enabled'] ?? false) as bool;
        _host = (m['host'] ?? '') as String;
        _port = (m['port'] ?? 0) as int;
        _type = (m['type'] ?? kTypeHttp) as String;
        _username = (m['username'] ?? '') as String;
        _password = (m['password'] ?? '') as String;
      } catch (_) {
        // 使用默认值。
      }
    }
    initialized = true;
  }

  Future<void> save({
    required bool enabled,
    required String host,
    required int port,
    String type = kTypeHttp,
    String username = '',
    String password = '',
  }) async {
    _enabled = enabled;
    _host = host.trim();
    _port = port;
    _type = (type == kTypeSocks5) ? kTypeSocks5 : kTypeHttp;
    _username = username;
    _password = password;
    final p = await SharedPreferences.getInstance();
    await p.setString(_prefsKey, jsonEncode({
          'enabled': _enabled,
          'host': _host,
          'port': _port,
          'type': _type,
          'username': _username,
          'password': _password,
        }));
  }

  /// 测试用：清空并重置初始化标记。
  void reset() {
    _enabled = false;
    _host = '';
    _port = 0;
    _type = kTypeHttp;
    _username = '';
    _password = '';
    initialized = false;
  }
}
