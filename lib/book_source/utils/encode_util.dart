/// 编码 / 解码工具（供 JS `$api` 桥接调用）。
library;

import 'dart:convert';

class EncodeUtil {
  EncodeUtil._();

  static String base64Encode(String s) => base64.encode(utf8.encode(s));

  static String base64Decode(String s) {
    try {
      return utf8.decode(base64.decode(s.trim()));
    } catch (_) {
      return '';
    }
  }

  static String base64UrlEncode(String s) {
    final b = base64.encode(utf8.encode(s));
    return b.replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '');
  }

  static String base64UrlDecode(String s) {
    try {
      final normalized = s
          .replaceAll('-', '+')
          .replaceAll('_', '/')
          .padRight(((s.length + 3) ~/ 4) * 4, '=');
      return utf8.decode(base64.decode(normalized.trim()));
    } catch (_) {
      return '';
    }
  }

  static String uriEncode(String s, {bool component = false}) =>
      component ? Uri.encodeComponent(s) : Uri.encodeFull(s);

  static String uriDecode(String s) {
    try {
      return Uri.decodeComponent(s);
    } catch (_) {
      return s;
    }
  }

  static String escape(String s) => Uri.encodeComponent(s);

  static String unescape(String s) => uriDecode(s);
}