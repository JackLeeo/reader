import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:legado_flutter/book_source/services/highlight_service.dart';

void main() {
  group('高亮样式/笔记', () {
    test('划词高亮带颜色/样式/笔记可持久化往返', () {
      final rule = HighlightRule(
        name: 'hl-1',
        keyword: '天龙八部',
        colorHex: '#66FF7043',
        style: HighlightDrawStyle.underline,
        note: '很重要',
      );
      final restored = HighlightRule.fromJson(
          Map<String, dynamic>.from(jsonDecode(jsonEncode(rule.toJson()))));
      expect(restored.style, HighlightDrawStyle.underline);
      expect(restored.colorHex, '#66FF7043');
      expect(restored.note, '很重要');
    });

    test('默认样式为高亮，旧数据无 style 字段兼容', () {
      // 模拟旧格式：无 style/note 字段
      final old = HighlightRule.fromJson({
        'name': 'old',
        'keyword': 'x',
        'colorHex': '#FFFF00',
        'enabled': true,
      });
      expect(old.style, HighlightDrawStyle.highlight);
      expect(old.note, isNull);
    });

    test('matchAll 传递样式与笔记', () {
      final rule = HighlightRule(
        name: 'r',
        keyword: '乙',
        style: HighlightDrawStyle.strikethrough,
        note: 'n',
      );
      final ms = rule.matchAll('甲乙丙乙');
      expect(ms.length, 2);
      for (final m in ms) {
        expect(m.style, HighlightDrawStyle.strikethrough);
        expect(m.note, 'n');
      }
    });
  });
}