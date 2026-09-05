import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gbk_codec/gbk_codec.dart';

import '../models/book_source.dart';
import 'login_service.dart';
import 'proxy_service.dart';

/// HTTP 响应（正文 + 状态 + 最终 URL）。
class Resp {
  Resp({
    required this.statusCode,
    required this.body,
    this.bodyBytes,
    this.finalUrl,
    this.headers = const {},
  });

  final int statusCode;
  final String body;
  final List<int>? bodyBytes;
  final Uri? finalUrl;
  final Map<String, String> headers;

  bool get ok => statusCode >= 200 && statusCode < 300;
}

/// 书源网络请求服务（对齐官方 `HttpHelper`）。
///
/// - 内置默认 User-Agent
/// - 按域名 CookieJar（读 Response `set-cookie`，写 `cookie` 请求头）
/// - 并发率限速（如 `1000/1s`）
class HttpService {
  HttpService._();

  static final HttpService instance = HttpService._();

  static const String defaultUserAgent =
      'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/120.0.0.0 Mobile Safari/537.36';

  /// 自定义全局 UA（空 = 用默认）。
  String _customUserAgent = '';

  String get userAgent => _customUserAgent.trim().isEmpty
      ? defaultUserAgent
      : _customUserAgent.trim();

  /// 设置自定义全局 UA（空串恢复默认）。
  void setUserAgent(String v) => _customUserAgent = v;

  /// 启动时从偏好恢复自定义 UA / 常用偏好。
  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    _customUserAgent = p.getString('customUA') ?? '';
  }

  /// 内置 Client：通过 `findProxy` 接入全局代理（每次请求实时读取，改动即时生效）。
  final http.Client _client = _buildClient();

  static http.Client _buildClient() {
    final inner = HttpClient();
    inner.findProxy = (_) => ProxyService.instance.proxyDirective;
    // 部分书源站点使用自签署/过期证书（如 m.1kkk.com），官方可正常访问；
    // 这里跳过 TLS 证书校验以兼容这类源。仅影响书源 HTTP 客户端，不影响系统安全设置。
    inner.badCertificateCallback = (_, _, _) => true;
    return IOClient(inner);
  }

  /// 默认请求头（合并书源自定义头）。
  Map<String, String> _baseHeaders() {
    final headers = <String, String>{
      'User-Agent': userAgent,
      'Accept': '*/*',
      'Connection': 'keep-alive',
    };
    // HTTP 代理认证：配置了账号密码时注入 Proxy-Authorization（尽力覆盖 407）。
    final proxy = ProxyService.instance;
    if (proxy.hasAuth && proxy.type == ProxyService.kTypeHttp) {
      final creds = base64Encode(utf8.encode('${proxy.username}:${proxy.password}'));
      headers['Proxy-Authorization'] = 'Basic $creds';
    }
    return headers;
  }

  /// 会话 Cookie：host -> {cookieName -> value}
  final Map<String, Map<String, String>> _cookieSession = {};

  /// 限速：host -> 下一次允许请求时刻（ms）
  final Map<String, int> _nextAllowedAt = {};

  void _applyCookies(String host, Map<String, String> headers) {
    final cookies = _cookieSession[host];
    if (cookies == null || cookies.isEmpty) return;
    final parts = cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');
    headers['cookie'] = parts;
  }

  void _storeCookies(Uri uri, List<String>? setCookies) {
    if (setCookies == null || setCookies.isEmpty) return;
    final host = uri.host;
    final map = _cookieSession.putIfAbsent(host, () => {});
    for (final sc in setCookies) {
      final semi = sc.indexOf(';');
      final seg = semi >= 0 ? sc.substring(0, semi) : sc;
      final eq = seg.indexOf('=');
      if (eq <= 0) continue;
      map[seg.substring(0, eq).trim()] = seg.substring(eq + 1).trim();
    }
  }

  Uri _resolve(Uri base, String url) {
    if (url.startsWith('http://') || url.startsWith('https://')) {
      return Uri.parse(url);
    }
    return base.resolve(url);
  }

  Uri? _lastUri;

  /// GET，返回响应。
  ///
  /// [referer] 设 Referer 头；[source] 提供书源自定义 header 与限速。
  Future<Resp> get(
    String url, {
    Uri? base,
    String? referer,
    BookSource? source,
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final uri = _resolve(base ?? _lastUri ?? Uri(), url);
    final h = _baseHeaders();
    if (headers != null) h.addAll(headers);
    final sourceHeaders = source?.parseHeader() ?? const {};
    h.addAll(sourceHeaders);
    // 防盗链：当来自某书源的请求目标与书源域名不同（典型子资源/图片），
    // 且未显式指定 Referer 时，自动以书源首页为 Referer，避免被目标站拦截。
    if (referer == null && source != null &&
        !h.containsKey('Referer') && source.host.isNotEmpty &&
        uri.host != source.host) {
      h['Referer'] = source.origin;
    }
    if (referer != null && !h.containsKey('Referer')) h['Referer'] = referer;
    _applyCookies(uri.host, h);
    // 持久 CookieJar：登录源注入已保存的 cookie。
    final persistent = PersistentCookie.seed(source, uri.host);
    if (persistent != null) {
      final merged = h['cookie'] == null
          ? persistent
          : '${h['cookie']}; $persistent';
      h['cookie'] = merged;
    }
    await _throttle(uri.host, source);

    final started = DateTime.now();
    try {
      final resp = await _client
          .get(uri, headers: h)
          .timeout(timeout, onTimeout: () => throw TimeoutException('请求超时 $url'));
      _lastUri = uri;
      final setCookies = resp.headers['set-cookie'] != null ? [resp.headers['set-cookie']!] : null;
      _storeCookies(uri, setCookies);
      if (setCookies != null) {
        PersistentCookie.persist(source, uri.host, setCookies);
      }
      return _toResp(resp, uri);
    } finally {
      // ignore: avoid_print
      print('[http] ${DateTime.now().difference(started).inMilliseconds}ms $uri');
    }
  }

  Future<Resp> _toResp(http.Response resp, Uri uri) async {
    var body = '';
    List<int>? bytes;
    try {
      bytes = resp.bodyBytes;
      body = _decode(resp.bodyBytes, resp.headers['content-type']);
    } catch (_) {
      body = resp.body;
    }
    return Resp(
      statusCode: resp.statusCode,
      body: body,
      bodyBytes: bytes,
      finalUrl: uri,
      headers: resp.headers,
    );
  }

  String _decode(List<int> bytes, String? contentType) {
    final charset = _charsetOf(contentType);
    if (charset == 'gbk' || charset == 'gb2312' || charset == 'gb-2312' ||
        _looksGbk(bytes)) {
      // GBK 中文站：用 gbk_bytes 精确解码（多重字节），失败才退化为 utf8 容错。
      // 注意：不能用 gbk（该包的单字节变体），对真实多字节 GBK 网页会逐字节误翻。
      try {
        return gbk_bytes.decode(bytes);
      } catch (_) {}
    }
    try {
      return utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
      return String.fromCharCodes(bytes);
    }
  }

  /// 部分站点 HTTP 头不声明 charset，仅在 HTML `<meta charset="gbk">` 里声明。
  /// 从正文头部字节嗅探 gbk/gb2312 以正确解码。
  bool _looksGbk(List<int> bytes) {
    final head = bytes.length > 2048 ? bytes.sublist(0, 2048) : bytes;
    try {
      final s = String.fromCharCodes(head);
      return RegExp(
        'charset\\s*=\\s*["\']?\\s*(gbk|gb2312|gb_2312|gb-2312)',
        caseSensitive: false,
      ).hasMatch(s);
    } catch (_) {
      return false;
    }
  }

  static String _charsetOf(String? contentType) {
    if (contentType == null) return 'utf-8';
    final m = RegExp('charset=([^;\\s]+)', caseSensitive: false).firstMatch(contentType);
    if (m == null) return 'utf-8';
    final c = m.group(1)!.replaceAll('"', '').trim().toLowerCase();
    if (c == 'gb2312' || c == 'gbk' || c == 'gb-2312' || c == 'gb_2312') return 'gbk';
    return c;
  }

  /// 并发率限速：按 host 节流。
  Future<void> _throttle(String host, BookSource? source) async {
    final rate = source?.concurrentRate;
    final intervalMs = (rate == null || rate.trim().isEmpty)
        ? 200
        : (1000 / (_parseRate(rate.trim()) <= 0 ? 1 : _parseRate(rate.trim())))
            .round();
    await _sleep(host, intervalMs);
  }

  Future<void> _sleep(String host, int intervalMs) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = _nextAllowedAt[host] ?? 0;
    final wait = last + intervalMs - now;
    _nextAllowedAt[host] = now + (wait > 0 ? wait : 0);
    if (wait <= 0) return Future.value();
    return Future.delayed(Duration(milliseconds: wait));
  }

  /// 解析并发率，如 `1000/1s`、`200/600ms`，返回每秒请求数。
  static double _parseRate(String rate) {
    final m =
        RegExp(r'(\d+)\s*/\s*(\d+)\s*(ms|s)?', caseSensitive: false).firstMatch(rate);
    if (m == null) return 5;
    final count = int.tryParse(m.group(1)!) ?? 5;
    final unit = m.group(3) ?? '';
    final dur = int.tryParse(m.group(2)!) ?? 1000;
    final secs = unit == 'ms' ? dur / 1000.0 : dur.toDouble();
    if (secs <= 0) return count.toDouble();
    return count / secs;
  }

  /// POST（表单或 JSON）。
  Future<Resp> post(
    String url, {
    BookSource? source,
    Map<String, String>? form,
    String? json,
    String? bodyRaw,
    Uri? base,
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final uri = _resolve(base ?? _lastUri ?? Uri(), url);
    final h = _baseHeaders();
    if (headers != null) h.addAll(headers);
    final sourceHeaders = source?.parseHeader() ?? const {};
    h.addAll(sourceHeaders);
    _applyCookies(uri.host, h);
    final persistent = PersistentCookie.seed(source, uri.host);
    if (persistent != null) {
      final merged = h['cookie'] == null
          ? persistent
          : '${h['cookie']}; $persistent';
      h['cookie'] = merged;
    }
    await _throttle(uri.host, source);
    http.Response resp;
    if (json != null) {
      h['Content-Type'] = 'application/json; charset=utf-8';
      resp = await _client
          .post(uri, headers: h, body: json)
          .timeout(timeout, onTimeout: () => throw TimeoutException('POST超时'));
    } else if (bodyRaw != null) {
      if (!h.containsKey('Content-Type')) {
        h['Content-Type'] = 'text/plain; charset=utf-8';
      }
      resp = await _client
          .post(uri, headers: h, body: bodyRaw)
          .timeout(timeout, onTimeout: () => throw TimeoutException('POST超时'));
    } else {
      resp = await _client
          .post(uri, headers: h, body: form ?? '')
          .timeout(timeout, onTimeout: () => throw TimeoutException('POST超时'));
    }
    _lastUri = uri;
    final setCookies = resp.headers['set-cookie'] != null ? [resp.headers['set-cookie']!] : null;
    _storeCookies(uri, setCookies);
    if (setCookies != null) {
      PersistentCookie.persist(source, uri.host, setCookies);
    }
    return _toResp(resp, uri);
  }

  /// 清理指定域名的 Cookie。
  void clearCookies(String host) => _cookieSession.remove(host);

  void clearAllCookies() => _cookieSession.clear();
}