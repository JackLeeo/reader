import 'package:flutter_test/flutter_test.dart';
import 'package:legado_flutter/book_source/help/content_processor.dart';

void main() {
  const cp = ContentProcessor();

  group('ContentProcessor', () {
    test('去重复标题：正文首行与章节标题一致时剔除', () {
      final out = cp.clean('第一章  风起\n风起，少年醒来。', title: '第一章 风起');
      expect(out, '风起，少年醒来。');
    });

    test('标题不含正文则不误删', () {
      final text = '清晨，少年练剑。\n重剑无锋。';
      expect(cp.clean(text, title: '第一章'), text);
    });

    test('归一化空白：CRLF/LF 统一、多余空行压缩、首尾去空行', () {
      final out = cp.clean('  首行\r\n\r\n\r\n  第二段  \r\n  ');
      expect(out, '首行\n\n  第二段\n\n'.trim());
    });

    test('替换规则钩子默认安全：不改变正文', () {
      expect(cp.clean(' ab ', title: 'x'), 'ab');
    });

    test('空串安全', () {
      expect(cp.clean(''), '');
      expect(cp.clean('   '), '');
    });
  });
}