import 'package:html/parser.dart' show parseFragment;

/// URL 工具（对标官方 `NetworkUtils`）。
class UrlUtil {
  UrlUtil._();

  /// 依据请求最终实际地址 baseUrl 解析规范化链接（官方 `getAbsoluteURL`）。
  ///
  /// 会合并 `.`/`..` 路径段、规范化连续斜杠、处理 `//` 协议相对地址。
  static String getAbsoluteURL(String? base, String url) {
    if (url.isEmpty) return base ?? '';
    // 已是绝对地址
    if (url.startsWith('http://') || url.startsWith('https://')) {
      return normalize(url);
    }
    // 协议相对：//host/…
    if (url.startsWith('//')) {
      final scheme = (base ?? '').contains('://') ? (base ?? '').split('://').first : 'http';
      return normalize('$scheme:$url');
    }
    if (base == null || base.isEmpty) return normalize(url);
    try {
      final baseUri = Uri.parse(base);
      final resolved = baseUri.resolve(url);
      return normalize(resolved.toString());
    } on FormatException {
      return normalize(url);
    }
  }

  /// 合并路径内连续斜杠与 `.`/`..`（解决 `//2924//2924` 畸形路径）。
  static String normalize(String url) {
    if (url.length < 8) return url;
    const marker = '://';
    final schemeEnd = url.indexOf(marker);
    if (schemeEnd < 0) return url;
    final afterScheme = schemeEnd + marker.length;
    final firstSlash = url.indexOf('/', afterScheme);
    final prefix = firstSlash < 0 ? url : url.substring(0, firstSlash);
    var path = firstSlash < 0 ? '' : url.substring(firstSlash);
    if (path.isEmpty) return url;
    // 折叠连续斜杠（保留协议后的双斜杠不被碰，因 prefix 已剥离）
    while (path.contains('//')) {
      path = path.replaceAll('//', '/');
    }
    // 规范化 . 和 ...
    final folded = _foldDotSegments(path);
    return '$prefix$folded';
  }

  static String _foldDotSegments(String path) {
    final isRel = !path.startsWith('/');
    final segs = path.split('/').where((s) => s.isNotEmpty).toList();
    final stack = <String>[];
    for (final s in segs) {
      if (s == '.') continue;
      if (s == '..') {
        if (stack.isNotEmpty) stack.removeLast();
        continue;
      }
      stack.add(s);
    }
    return (isRel ? '' : '/') + stack.join('/');
  }

  /// 非常轻量地从 HTML 片段中取文本（jsoup 语义，仅作辅助，主流程走 analyze_css）。
  static String textFromHtml(String html) {
    try {
      final doc = parseFragment(html);
      return doc.text?.trim() ?? '';
    } catch (_) {
      return splitTextFromHtml(html);
    }
  }

  static String splitTextFromHtml(String html) {
    return html
        .replaceAll(RegExp(r'<[^>]+>'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }
}