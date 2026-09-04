/// 正文净化管线（对标官方 `ContentProcessor` 的等价实现）。
///
/// 官方在正文进入阅读器前会做：去重复标题、重新分段、简繁转换、
/// HTML 特殊格式处理、应用替换/净化规则。本实现覆盖：去重复标题、
/// 空白归一、替换规则（[replaceRules]）、简繁转换（[convertType]）。
library;

import '../services/replace_rule_service.dart';
import 'chinese_converter.dart';

/// 单条替换钩子：入参（书源, 文本），返回替换后文本。
typedef ContentReplaceRule = String Function(String? source, String text);

/// 简繁转换类型：0=不转换，1=简体→繁体，2=繁体→简体。
const int kConvertNone = 0;
const int kConvertToTraditional = 1;
const int kConvertToSimplified = 2;

/// 正文净化上下文（对应官方 ContentProcessor）。
class ContentProcessor {
  const ContentProcessor({
    this.sourceName,
    this.replaceRules = const [],
    this.convertType = kConvertNone,
  });

  /// 书源 URL（替换规则按源过滤）。
  final String? sourceName;

  /// 替换规则钩子（来自 ReplaceRuleService）。
  final List<ContentReplaceRule> replaceRules;

  /// 简繁转换类型。
  final int convertType;

  /// 净化正文。
  ///
  /// [text] 原始正文，[title] 当前章节标题（用于去重复题名）。
  String clean(String text, {String? title}) {
    var t = text;
    if (t.isEmpty) return t;

    // 1. 去重复标题（正文首段与章节标题一致时去掉首行重复题名）。
    t = _removeDuplicateTitle(t, title);

    // 1.5 对齐官方 ContentProcessor：HTML 特殊格式处理——解码实体、`<br>`/块级标签转换行、清除残留标签。
    t = _htmlDecodeAndBreak(t);

    // 2. 归一化空白：CRLF→LF，多个空行→单空行，去除行尾空格（保留段首缩进）。
    t = t.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    t = t.replaceAll(RegExp(r'[ \t]+\n'), '\n');
    t = t.replaceAll(RegExp(r'\n{3,}'), '\n\n');

    // 3. 重新分段：去掉首尾空行，确保段落间只有一个空行。
    t = t.trim();

    // 4. 替换规则钩子（按顺序应用）。
    for (final rule in replaceRules) {
      t = rule(sourceName, t);
    }

    // 5. 简繁转换。
    if (convertType == kConvertToTraditional) {
      t = ChineseConverter.toTraditional(t);
    } else if (convertType == kConvertToSimplified) {
      t = ChineseConverter.toSimplified(t);
    }
    return t;
  }

  /// HTML 特殊格式处理：先解码实体，再把 `换行类标签`（br、段落、标题、列举）转成换行，
  /// 剩余标签剥离。纯文本（无标签）不受影响；`<` `>` 用于比较等场景不易误伤。
  static String _htmlDecodeAndBreak(String text) {
    if (!text.contains('<')) return text; // 无标签，直接返回
    final buf = StringBuffer();
    var i = 0;
    final n = text.length;
    while (i < n) {
      final ch = text[i];
      if (ch == '&') {
        buf.write(_decodeEntity(text, i));
        i += _entityLen(text, i);
        continue;
      }
      if (ch == '<') {
        final close = text.indexOf('>', i + 1);
        if (close < 0) { buf.write('<'); i++; continue; }
        String tag = text.substring(i + 1, close).trim();
        // 去掉属性，取标签名
        final sp = tag.indexOf(' ');
        if (sp > 0) tag = tag.substring(0, sp);
        final isClose = tag.startsWith('/');
        final name = isClose ? tag.substring(1).toLowerCase() : tag.toLowerCase();
        if (name == 'br' || name == 'p' || name == 'div' || name == 'li' ||
            name == 'h1' || name == 'h2' || name == 'h3' || name == 'h4' ||
            name == 'tr' || name == 'blockquote') {
          buf.write('\n'); // 换行类标签
        }
        // 其余标签（span/a/img 等的开闭）直接丢弃
        i = close + 1;
        continue;
      }
      buf.write(ch);
      i++;
    }
    return buf.toString().replaceAll(RegExp(r'\n{3,}'), '\n\n');
  }

  static String _decodeEntity(String s, int at) {
    final semi = s.indexOf(';', at);
    if (semi < 0 || semi - at > 10) return '&';
    final body = s.substring(at + 1, semi);
    if (body.isEmpty) return '&';
    // 数字字符引用
    if (body.startsWith('#x') || body.startsWith('#X')) {
      final hex = int.tryParse(body.substring(2), radix: 16);
      return hex == null ? '&$body;' : String.fromCharCode(hex);
    }
    if (body.startsWith('#')) {
      final dec = int.tryParse(body.substring(1));
      return dec == null ? '&$body;' : String.fromCharCode(dec);
    }
    switch (body) {
      case 'nbsp': return ' ';
      case 'amp': return '&';
      case 'lt': return '<';
      case 'gt': return '>';
      case 'quot': return '"';
      case 'apos': return "'";
      case 'ensp': return ' ';
      case 'emsp': return '  ';
      case 'mdash': return '—';
      case 'ndash': return '–';
      case 'ldquo': return '“';
      case 'rdquo': return '”';
      case 'lsquo': return '‘';
      case 'rsquo': return '’';
      case 'middot': return '·';
      case 'hellip': return '…';
      case 'times': return '×';
      default: return '&$body;';
    }
  }

  static int _entityLen(String s, int at) {
    final semi = s.indexOf(';', at);
    if (semi < 0 || semi - at > 10) return 1;
    return semi - at + 1;
  }

  /// 把 ReplaceRuleService 的生效规则转成钩子列表。
  static List<ContentReplaceRule> hooksFrom({
    required String? sourceUrl,
    required bool forTitle,
  }) {
    final rules =
        ReplaceRuleService.instance.activeFor(sourceUrl: sourceUrl, forTitle: forTitle);
    return [
      for (final r in rules)
        (_, text) => r.apply(text),
    ];
  }

  /// 去重复标题：正文第一行若与章节标题高度重合，则剔除。
  static String _removeDuplicateTitle(String text, String? title) {
    if (title == null || title.isEmpty) return text;
    final t = text.trim();
    final firstLineEnds = t.indexOf('\n');
    String first;
    String rest;
    if (firstLineEnds < 0) {
      first = t;
      rest = '';
    } else {
      first = t.substring(0, firstLineEnds).trim();
      rest = t.substring(firstLineEnds);
    }
    // 首行完全等于标题，或标题包含首行（反之亦然）且较长，判为重复。
    // 比较前先折叠正文/标题内部的连续空白，避免缩进差异误判不相等。
    String norm(String s) => s.replaceAll(RegExp(r'\s+'), '');
    final firstNorm = norm(first);
    final titleNorm = norm(title.trim());
    if (firstNorm == titleNorm) {
      return rest.trim();
    }
    if (titleNorm.length >= 4 &&
        (firstNorm.contains(titleNorm) || titleNorm.contains(firstNorm))) {
      return rest.trim();
    }
    return text;
  }

  /// 归一化正文中的全角/半角空格与段首缩进（供排版兜底用）。
  static String normalizeIndent(String text) {
    // 保留原文，仅把连续空格清理，缩进交由排版层画 "\u3000\u3000"。
    return text.replaceAll(RegExp(r'[ \t]{2,}'), ' ').trim();
  }
}
