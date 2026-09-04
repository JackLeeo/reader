/// 听书/音频 HTTP 引擎（对应官方「音频请求头」处理）。
///
/// 原生播放器（ExoPlayer 等）不支持直接设置自定义请求头，官方做法是把
/// `referer` / `user-agent` / `cookie` 等以查询参数注入 URL（ExoPlayer 会把
/// 这些参数转回请求头）。本引擎实现该 URL 构造，并合并书源自定义头与
/// 已登录持久化的 Cookie。
library;

import '../models/book_source.dart';
import '../models/books.dart';
import '../services/book_source_service.dart';
import '../services/cookie_service.dart';

class AudioEngine {
  AudioEngine._();

  static const String _defaultUserAgent =
      'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/120.0.0.0 Mobile Safari/537.36';

  /// 为音频地址构造“可播放 URL”：追加 referer / user-agent / cookie 参数。
  ///
  /// 已有同名参数不会被覆盖。无附加内容时原样返回。
  static String buildPlayableUrl(
    String url, {
    String? referer,
    String? userAgent,
    String? cookie,
  }) {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) return url;

    final params = <String, String>{...uri.queryParameters};
    if (referer != null && referer.isNotEmpty && !params.containsKey('referer')) {
      params['referer'] = referer;
    }
    if (userAgent != null && userAgent.isNotEmpty && !params.containsKey('userAgent')) {
      params['userAgent'] = userAgent;
    }
    if (cookie != null && cookie.isNotEmpty && !params.containsKey('cookie')) {
      params['cookie'] = cookie;
    }
    if (params.isEmpty) return url;
    return uri.replace(queryParameters: params).toString();
  }

  /// 基于书源构造可播放地址：合并书源 header（Referer/User-Agent）+
  /// 该域名的持久化 Cookie。
  static String buildSourcePlayableUrl(String url, BookSource source) {
    final headers = source.parseHeader();
    final referer = headers['Referer'] ?? headers['referer'];
    final ua = headers['User-Agent'] ?? headers['user-agent'] ?? _defaultUserAgent;
    final domain = Uri.tryParse(url)?.host ?? '';
    final cookie =
        source.enabledCookieJar != false ? CookieService.instance.cookieHeaderFor(domain) : '';
    return buildPlayableUrl(url, referer: referer, userAgent: ua, cookie: cookie);
  }

  /// 基于 [Book] 构造可播放地址：由 `sourceTag` 反查书源配置。
  ///
  /// 找不到书源时退化为仅注入默认 User-Agent（不强依赖配置）。
  static String buildBookPlayableUrl(String url, Book book) {
    BookSource? matched;
    for (final s in BookSourceService.instance.sources) {
      if (s.bookSourceUrl == book.sourceTag) {
        matched = s;
        break;
      }
    }
    if (matched == null) {
      return buildPlayableUrl(url, userAgent: _defaultUserAgent);
    }
    return buildSourcePlayableUrl(url, matched);
  }

  /// 是否为 base64 编码的音频地址（部分听书源直接给 base64）。
  static bool isBase64Audio(String url) {
    final t = url.trim();
    // 过短无意义；URL 含 :/ 不会通过下方正则，天然排除。
    if (t.length < 8) return false;
    final base64Re = RegExp(r'^[A-Za-z0-9+/=\s]+$');
    if (!base64Re.hasMatch(t)) return false;
    // 需要足够的数据量且填充符规范，避免误判普通路径。
    if (t.length % 4 != 0) return false;
    return true;
  }

  /// 尝试解码 base64 音频地址；非 base64 原样返回。
  static String decodeIfBase64(String url) {
    if (!isBase64Audio(url)) return url;
    try {
      return String.fromCharCodes(_decodeB64(url));
    } catch (_) {
      return url;
    }
  }

  static List<int> _decodeB64(String input) {
    const table = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    final clean = input.replaceAll(RegExp(r'\s'), '');
    final out = <int>[];
    var buffer = 0, bits = 0;
    for (var i = 0; i < clean.length; i++) {
      final c = clean[i];
      if (c == '=') break;
      final val = table.indexOf(c);
      if (val < 0) continue;
      buffer = (buffer << 6) | val;
      bits += 6;
      if (bits >= 8) {
        bits -= 8;
        out.add((buffer >> bits) & 0xFF);
      }
    }
    return out;
  }
}
