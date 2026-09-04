import '../entities/source_rule.dart';

/// 正则分析器（官方 `AnalyzeByRegex`）。
///
/// jsoup `getElements` 时若模式是正则（`@Regex:` / `:` / `isRegex`），
/// 用 `&&` 分隔多模式逐层匹配。
class AnalyzeRegex {
  AnalyzeRegex._();

  /// 取第一条捕获组或整组匹配（官方 `getString`）。
  static String getString(RuleValue ctx, String rule) {
    if (ctx is! RuleTextValue) return '';
    final patterns = rule.split('&&').where((e) => e.isNotEmpty).toList();
    var text = ctx.text;
    for (var i = 0; i < patterns.length; i++) {
      final m = RegExp(patterns[i]).firstMatch(text);
      if (m == null) {
        if (i == 0) return '';
        break;
      }
      text = _groupValue(m, patterns[i]);
    }
    return text;
  }

  static String _groupValue(RegExpMatch m, String pattern) {
    if (m.groupCount >= 1) {
      final g = m.group(1);
      if (g != null && g.isNotEmpty) return g;
    }
    return m.group(0) ?? '';
  }

  /// 返回每个匹配（官方 `getElements` 集合）。
  static List<RuleValue> getList(RuleValue ctx, String rule) {
    if (ctx is! RuleTextValue) return const [];
    return [for (final e in getElementsObject(ctx.text, rule.split('&&').where((e) => e.isNotEmpty).toList())) RuleTextValue(e)];
  }

  /// 官方 `AnalyzeByRegex.getElements`：多层 `&&` 模式逐层匹配，返回捕获组字符串列表。
  static List<String> getElementsObject(String text, List<String> patterns) {
    List<String> current = [text];
    for (final p in patterns) {
      if (current.isEmpty) return const [];
      final next = <String>[];
      for (final seg in current) {
        final re = _tryCompile(p);
        if (re == null) continue;
        for (final m in re.allMatches(seg)) {
          next.add(_groupValue(m, p));
        }
      }
      current = next;
    }
    return current;
  }

  static RegExp? _tryCompile(String p) {
    try {
      return RegExp(p);
    } catch (_) {
      return null;
    }
  }

  /// 替换（`##` 分隔）。`$$keepAll` 等高级标记暂走简单替换。
  static String replace(String input, String regex, String replacement, {bool firstOnly = false}) {
    try {
      final re = RegExp(regex);
      if (firstOnly) {
        final span = re.firstMatch(input);
        if (span == null) return input;
        return input.replaceRange(span.start, span.end, replacement);
      }
      // 处理 `$1` 反向引用
      return input.replaceAllMapped(re, (m) {
        var out = replacement;
        for (var i = 0; i <= m.groupCount; i++) {
          out = out.replaceAll('\$$i', m.group(i) ?? '');
        }
        return out;
      });
    } catch (_) {
      return input;
    }
  }
}