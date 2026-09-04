import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gbk_codec/gbk_codec.dart';

void main() {
  test('gbk_bytes decodes a real multi-byte GBK page',
      timeout: const Timeout(Duration(minutes: 2)), () {
    // 用正确编码器 gbk_bytes 生成真实多重字节 GBK
    const gbkMeta =
        '<!DOCTYPE html><html><head><meta charset="gbk" /><title>搜索</title></head>';
    final gbkBytes = gbk_bytes.encode(gbkMeta);

    // 双字节校验：至少包含合法的 GBK 双字节，而不是逐字节 latin1
    final wrong = gbk.decode(gbkBytes); // 旧的单字节变体 → 乱码
    expect(wrong.contains('搜索'), isFalse, reason: wrong);

    final right = gbk_bytes.decode(gbkBytes);
    expect(right.contains('搜索'), isTrue, reason: right);

    // 用与 _decode 相同逻辑的嗅探
    final head = gbkBytes.length > 2048 ? gbkBytes.sublist(0, 2048) : gbkBytes;
    final s = String.fromCharCodes(head);
    final looksGbk = RegExp(
      'charset\\s*=\\s*["\']?\\s*(gbk|gb2312|gb_2312|gb-2312)',
      caseSensitive: false,
    ).hasMatch(s);
    expect(looksGbk, isTrue);
  });

  test('utf-8 site must NOT be detected as gbk', () {
    const utf8Head = '<html><head><meta charset="utf-8"><title>搜索</title></head>';
    final bytes = utf8.encode(utf8Head);
    final s = String.fromCharCodes(bytes);
    final looksGbk = RegExp(
      'charset\\s*=\\s*["\']?\\s*(gbk|gb2312|gb_2312|gb-2312)',
      caseSensitive: false,
    ).hasMatch(s);
    expect(looksGbk, isFalse);
  });
}