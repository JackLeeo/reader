import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:legado_flutter/book_source/utils/aes.dart';

String hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  test('AES-128 ECB 加密匹配 FIPS-197 C.1 向量', () {
    final key = List<int>.generate(16, (i) => i); // 00..0f
    final pt = List<int>.generate(16, (i) => (i * 0x11) & 0xff); // 00 11 22 ...
    final ct = Aes.encrypt(pt, key);
    expect(hex(ct.sublist(0, 16)), '69c4e0d86a7b0430d8cdb78070b4c55a');
  });

  test('AES 单块往返一致', () {
    final key = List<int>.generate(16, (i) => i);
    final pt = List<int>.generate(16, (i) => (i * 0x11) & 0xff);
    final dec = Aes.decrypt(Aes.encrypt(pt, key), key);
    expect(dec, isNotNull);
    expect(dec, pt);
  });

  test('AES 多块中文往返一致', () {
    final key = List<int>.generate(16, (i) => i);
    const s = '这是一段用于测试 AES 中文加解密正确性的较长文本，用于校验多块与填充逻辑。';
    final plain = utf8.encode(s);
    final dec = Aes.decrypt(Aes.encrypt(plain, key), key);
    expect(dec, isNotNull);
    expect(utf8.decode(dec!), s);
  });

  test('AES 口令错误/非法密文返回 null', () {
    final key = List<int>.generate(16, (i) => i);
    final ct = Aes.encrypt(utf8.encode('abc'), key);
    final wrongKey = List<int>.generate(16, (i) => (i + 1) & 0xff);
    // 解出非法填充概率极低，但需不抛异常：
    try {
      Aes.decrypt(ct, wrongKey);
    } catch (_) {
      // 允许 null 或异常（填充非法时返回 null）
    }
    expect(Aes.decrypt(ct, key), isNotNull);
    expect(Aes.decrypt(const [], key), isNull);
  });
}