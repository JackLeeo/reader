import 'dart:convert';

import 'aes.dart';

/// 书源分享口令加密（AES-128-ECB + PKCS7，自包含实现，免第三方依赖）。
///
/// 用口令派生 16 字节密钥对书源 JSON 做 AES 加密，再 base64 输出，
/// 前缀 `enc:` 便于导入端识别并校验口令。内部加解密自洽可验证。
class SourceSharer {
  SourceSharer._();

  static const String _prefix = 'enc:';

  /// 口令 -> AES 密钥（16 字节）。
  static List<int> _key(String password) => Aes.deriveKey(password);

  static String encrypt(String payload, String password) {
    final data = utf8.encode(payload);
    final ct = Aes.encrypt(data, _key(password));
    return _prefix + base64Url.encode(ct);
  }

  /// 解密；口令错误或数据非法返回 null。
  static String? decrypt(String data, String password) {
    if (!data.startsWith(_prefix)) return null;
    try {
      final ct = base64Url.decode(data.substring(_prefix.length));
      final plain = Aes.decrypt(ct, _key(password));
      if (plain == null) return null;
      return utf8.decode(plain, allowMalformed: false);
    } catch (_) {
      return null;
    }
  }

  static bool isEncrypted(String data) => data.startsWith(_prefix);
}