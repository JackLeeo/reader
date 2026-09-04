import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as parser;

import '../entities/source_rule.dart';

/// jsoup 语义的 CSS 分析器（对应官方 `AnalyzeByJSoup`）。
///
/// 用 package:html 做 CSS 选择器，并补充 jsoup 扩展：
/// `text` / `ownText` / `html` / `attr` / `all` / `children` / 位置伪类等。
class AnalyzeCss {
  AnalyzeCss._();

  /// 取文本（jsoup `Element.text()`，合并后代可见文本）。
  static String text(RuleValue value) => switch (value) {
        RuleTextValue(:final text) => text,
        RuleElementValue(:final element) => element.text.trim(),
        RuleJsonValue() => '',
      };

  /// ownText：仅自身直接子文本（jsoup `ownText()`）。
  static String ownText(RuleValue value) {
    if (value is! RuleElementValue) return text(value);
    final el = value.element;
    final sb = StringBuffer();
    for (final child in el.nodes) {
      if (child is dom.Text) sb.write(child.text);
    }
    return sb.toString().trim();
  }

  static String html(RuleValue value) {
    if (value is RuleElementValue) return value.element.innerHtml.trim();
    if (value is RuleTextValue) return value.text;
    return '';
  }

  /// 取属性；给定元素集合时取第一个命中。
  static String attr(RuleValue value, String name) {
    if (value is RuleElementValue) return value.element.attributes[name] ?? '';
    if (value is RuleTextValue || value is RuleJsonValue) return '';
    return '';
  }

  static List<dom.Element> _asElements(RuleValue value) {
    if (value is RuleElementValue) return [value.element];
    if (value is RuleTextValue && value.text.trim().isNotEmpty) {
      // 上下文是整段 HTML：解析为文档，用 body 作为查询根
      try {
        final doc = parser.parse(value.text);
        final body = doc.body;
        if (body != null) return [body];
        return const [];
      } catch (_) {
        return const [];
      }
    }
    return const [];
  }

  /// jsoup `getElements()`：对上下文执行 CSS 选择器，返回元素列表。
  ///
  /// 兼容官方「元素索引/筛选」语法：`tag.div.0`、`tag.div!0:3`、`tag.div[2]`、
  /// 负索引、区间、反向（`-1:0`）。有索引时先按 beforeRule 查询，再按索引筛选。
  static List<RuleElementValue> getElements(RuleValue ctx, String css) {
    final rule = css.trim();
    if (rule.isEmpty) return _asElements(ctx).map(RuleElementValue.new).toList();

    // 解析尾部索引/筛选（`beforeRule.index` / `beforeRule!...` / `beforeRule[...]`）
    final idx = _ElementIndex.tryParse(rule);
    var select = idx?.beforeRule.trim() ?? rule;

    // Legado 传统前缀选择器：`class.xxx` `id.xxx` `tag.xxx`（官方兼容写法）
    // package:html 会把 `class` 误当元素名，需转译成标准 CSS。
    select = _translateLegacyPrefix(select);

    // 组合语法 `A && B`（并）/ `A || B`（或，前非空前短路）/ `A %% B`（列对齐）
    if (_splitCombinator(select) != null) {
      final combined = _applyCombinator(ctx, select);
      if (idx == null) return combined;
      return idx.apply(combined);
    }

    final list = <RuleElementValue>[];
    for (final root in _asElements(ctx)) {
      if (select == '*' || select == 'all') {
        _descendants(root, list);
      } else if (select == 'children') {
        for (final c in root.children) {
          list.add(RuleElementValue(c));
        }
      } else {
        try {
          for (final e in root.querySelectorAll(select)) {
            list.add(RuleElementValue(e));
          }
        } catch (_) {
          // 选择器不支持时回退为按标签名/类名粗匹配
          for (final e in _looseSelect(root, select)) {
            list.add(RuleElementValue(e));
          }
        }
      }
    }
    if (idx == null) return list;
    return idx.apply(list);
  }

  /// 组合语法切分；仅当不含选择器自身的类名冲突时识别。返回 (type, parts)。
  static (String, List<String>)? _splitCombinator(String s) {
    for (final sep in ['&&', '||', '%%']) {
      if (s.contains(sep)) {
        final parts = s.split(sep).map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
        if (parts.length > 1) return (sep, parts);
      }
    }
    return null;
  }

  /// Legado 传统前缀选择器转译：
  /// `class.xxx`→`.xxx`、`id.xxx`→`#xxx`、`tag.xxx`→`xxx`。
  /// 仅当前缀前是开始 / 空白 / 组合符（`>+~,`）时生效，避免误伤
  /// `div.class`、`a.tag` 等复合写法（其前缀前是 `.` 等非边界字符）。
  static final RegExp _legacyPrefixRe =
      RegExp(r'([\s>+~,]|^)(class|tag|id)\.');
  static String _translateLegacyPrefix(String s) {
    return s.replaceAllMapped(
      _legacyPrefixRe,
      (m) => m.group(1)!
          + switch (m.group(2)) {
              'class' => '.',
              'tag' => '',
              _ => '#',
            },
    );
  }

  static List<RuleElementValue> _applyCombinator(RuleValue ctx, String rule) {
    final combo = _splitCombinator(rule)!;
    final sep = combo.$1;
    final results = <List<RuleElementValue>>[];
    for (final part in combo.$2) {
      final els = getElements(ctx, part);
      results.add(els);
      if (sep == '||' && els.isNotEmpty) break;
    }
    if (sep == '%%') {
      // 列对齐：逐行取同位置元素
      final out = <RuleElementValue>[];
      final n = results.first.length;
      for (var i = 0; i < n; i++) {
        for (final r in results) {
          if (i < r.length) out.add(r[i]);
        }
      }
      return out;
    }
    return [for (final r in results) ...r];
  }

  static void _descendants(dom.Element root, List<RuleElementValue> out) {
    for (final e in root.querySelectorAll('*')) {
      out.add(RuleElementValue(e));
    }
  }

  /// 宽松匹配：`tag`, `.class`, `#id`, `tag.class`。
  static List<dom.Element> _looseSelect(dom.Element root, String rule) {
    final parts = rule.split('#');
    var tag = parts[0].trim().toLowerCase();
    final id = parts.length > 1 ? parts[1].trim() : '';
    final out = <dom.Element>[];
    final List<dom.Element> all;
    try {
      all = root.querySelectorAll(tag.isEmpty ? '*' : tag);
    } catch (_) {
      return const [];
    }
    for (final e in all) {
      if (id.isNotEmpty && e.id != id) continue;
      final classes = tag.split('.');
      final clsPart = classes.length > 1 ? classes.last : '';
      if (clsPart.isNotEmpty && !(e.className).contains(clsPart)) continue;
      out.add(e);
    }
    return out;
  }

  /// jsoup `getString()`：对第一条匹配求字符串。
  ///
  /// - 空规则 → 上下文文本
  /// - 伪属性 `text` / `textNodes` / `ownText` / `html` / `all` → 对应语义（官方 getResultLast）
  /// - 其它 `@attr` / `tag@attr` → 取属性
  static String getString(RuleValue ctx, String rawRule, {bool isUrl = false}) {
    var rule = rawRule.trim();
    if (rule.isEmpty) return text(ctx);

    // 纯伪属性 / 纯属性：`@text` / `@ownText` / `@src`
    if (rule.startsWith('@')) {
      return _resolveLast(ctx, rule.substring(1));
    }
    // `tag@伪属性-或-属性`：取选择器匹配元素，再解析最后一个 @ 之后的内容
    final atIdx = _attrSepIndex(rule);
    if (atIdx >= 0) {
      final selector = rule.substring(0, atIdx).trim();
      final lastToken = rule.substring(atIdx + 1).trim();
      final hits = getElements(ctx, selector);
      if (hits.isEmpty) return '';
      return _resolveTokens([hits.first.element], lastToken);
    }

    return switch (rule.toLowerCase()) {
      'text' => text(ctx),
      'owntext' => ownText(ctx),
      'html' => html(ctx),
      'all' => text(ctx),
      'alltext' => text(ctx),
      'children' => _childrenText(ctx),
      _ => _selectFirstString(ctx, rule),
    };
  }

  /// jsoup `getStringList()`：对每条匹配求字符串，返回列表。
  ///
  /// - 空规则 → 每个匹配元素的文本
  /// - 无 `@` 后缀 → 默认取元素文本（对齐官方 getStringList 未带伪属性时的文本语义）
  /// - 有 `@attr` / `@text` 等 → 逐元素解析伪属性/属性
  static List<String> getStringList(RuleValue ctx, String rawRule) {
    var rule = rawRule.trim();
    if (rule.isEmpty) {
      return _asElements(ctx).map((e) => e.text.trim()).toList();
    }
    final atIdx = _attrSepIndex(rule);
    final selector = atIdx >= 0 ? rule.substring(0, atIdx).trim() : rule;
    final postfix = atIdx >= 0 ? rule.substring(atIdx + 1).trim() : 'text';
    final hits = getElements(ctx, selector);
    if (hits.isEmpty) return const [];
    return [for (final h in hits) _resolveTokens([h.element], postfix)];
  }

  /// 解析「元素集合 + 伪属性或属性名」→ 首个字符串（对齐官方 getResultLast）。
  static String _resolveLast(RuleValue ctx, String token) {
    final els = _asElements(ctx);
    if (els.isEmpty) return '';
    return _resolveTokens(els, token);
  }

  static String _resolveTokens(List<dom.Element> els, String token) {
    final t = token.trim().toLowerCase();
    return switch (t) {
      'text' => els.firstOrNull?.text.trim() ?? '',
      'owntext' => els.firstOrNull == null ? '' : ownText(RuleElementValue(els.first)),
      'html' => els.firstOrNull == null ? '' : els.first.innerHtml.trim(),
      'all' => els.map((e) => e.outerHtml).join(),
      'alltext' => els.map((e) => e.text.trim()).join(' '),
      'textnodes' => _textNodes(els),
      _ => els.firstOrNull?.attributes[token.trim()] ?? '',
    };
  }

  static String _textNodes(List<dom.Element> els) {
    final buf = StringBuffer();
    for (final e in els) {
      for (final n in e.nodes) {
        if (n is dom.Text) buf.write(n.text.trim());
      }
    }
    return buf.toString().trim();
  }

  static int _attrSepIndex(String rule) {
    // 与官方一致：取最后一个 @ 作为「选择器 | 伪属性/属性」分隔（jsoup 官方用 lastIndexOf）
    final i = rule.lastIndexOf('@');
    if (i <= 0) return -1;
    return i;
  }

  static String attrOnFirst(RuleValue ctx, String attrName) {
    final els = _asElements(ctx);
    if (els.isEmpty) return '';
    return els.first.attributes[attrName] ?? '';
  }

  static String _selectFirstString(RuleValue ctx, String selector) {
    final hits = getElements(ctx, selector);
    if (hits.isEmpty) return '';
    return text(hits.first);
  }

  static String _childrenText(RuleValue ctx) {
    final els = _asElements(ctx);
    if (els.isEmpty) return '';
    return els.first.children.map((c) => c.text).join();
  }
}

/// 官方 `AnalyzeByJSoup.ElementsSingle` 的元素索引/筛选。
///
/// 支持两种写法：
/// - 索引列表 `[it, start:end:step, it, ...]`（`!` 前缀 = 排除，`-1:0` 可反向）
/// - 阅读原写法 `.N`（包含）/ `!N`(排除)，分隔符可用 `:` 连接区间
class _ElementIndex {
  _ElementIndex({
    required this.beforeRule,
    required this.exclude,
    required this.indexes,
  });

  final String beforeRule;
  final bool exclude;
  final List<List<int>> indexes;

  List<int> _resolveSingle(List<RuleElementValue> list, int ix) {
    final len = list.length;
    final n = ix < 0 ? ix + len : ix;
    if (n < 0 || n >= len) return const [];
    return [n];
  }

  List<int> _resolveRange(List<RuleElementValue> list, int startX, int endX, int stepX) {
    final len = list.length;
    var start = startX < 0 ? startX + len : startX;
    var end = endX < 0 ? endX + len : endX;
    if ((start < 0 && end < 0) || (start >= len && end >= len)) return const [];
    start = start.clamp(0, len - 1);
    end = end.clamp(0, len - 1);
    if (start == end || stepX.abs() >= len) return [start];
    final step = stepX > 0 ? stepX : (stepX + len <= 0 ? 1 : stepX + len);
    final out = <int>[];
    if (end > start) {
      for (var i = start; i <= end; i += step) {
        out.add(i);
      }
    } else {
      for (var i = start; i >= end; i -= step) {
        out.add(i);
      }
    }
    return out;
  }

  List<RuleElementValue> apply(List<RuleElementValue> els) {
    if (indexes.isEmpty || els.isEmpty) return els;
    final sel = <int>{};
    for (final ix in indexes) {
      if (ix.length == 1) {
        sel.addAll(_resolveSingle(els, ix[0]));
      } else {
        final start = ix[0];
        final end = ix[1];
        final step = ix.length > 2 ? ix[2] : 1;
        sel.addAll(_resolveRange(els, start, end, step));
      }
    }
    if (exclude) {
      return [for (var i = 0; i < els.length; i++) if (!sel.contains(i)) els[i]];
    }
    // Set 自带插入序去重；不再排序，保留区间/反向的原始顺序（如 -1:0 反向）。
    return [for (final i in sel) els[i]];
  }

  /// 解析尾部索引语法；无法识别返回 null（纯 CSS 选择器）。
  static _ElementIndex? tryParse(String rule) {
    final t = rule.trim();
    if (t.startsWith('@CSS:') || t.startsWith('@@')) return null;
    if (t.isEmpty) return null;

    // [] 式索引：格式 `beforeRule[it,...]`，后面可选.
    final bracket = _matchBracket(t);
    if (bracket != null) {
      final content = bracket.$2;
      final parsed = _parseBracket(content);
      if (parsed != null) {
        return _ElementIndex(
            beforeRule: bracket.$1,
            exclude: _looksLikeExclude(bracket.$1) ? true : parsed.$2,
            indexes: parsed.$1,
          );
      }
    }

    // 逆序扫描 `:` 区间的阅读原写法：`.N` / `!N`，N 可为负
    var i = t.length - 1;
    final nums = <List<int>>[];
    var excludeFlg = false;
    final buf = StringBuffer();
    var curIsNegative = false;
    var pending = <int>[];
    while (i >= 0) {
      final c = t[i];
      if (c == ' ') {
        i--;
        continue;
      }
      if (_isDigit(c)) {
        buf.write(c);
      } else if (c == '-') {
        curIsNegative = true;
      } else if (c == ':' || c == '.' || c == '!') {
        final n = buf.isEmpty
            ? 0
            : (curIsNegative ? -int.parse(buf.toString()) : int.parse(buf.toString()));
        buf.clear();
        curIsNegative = false;
        if (c == ':') {
          pending.insert(0, n);
        } else {
          // '.' 或 '!' 结束索引段；若之前有 ':'，按区间 [n, pending...] 收集
          if (pending.isNotEmpty) {
            final range = <int>[n, ...pending];
            nums.insert(0, range);
          } else {
            nums.insert(0, [n]);
          }
          pending = [];
          excludeFlg = c == '!';
          final before = t.substring(0, i).trim();
          if (before.isEmpty) return null;
          if (_isSelectorLike(before)) {
            return _ElementIndex(
              beforeRule: before,
              exclude: excludeFlg,
              indexes: nums,
            );
          }
          return null;
        }
      } else {
        // 非索引字符：若非纯数字结尾则不是索引语法
        break;
      }
      i--;
    }
    return null;
  }

  static bool _isDigit(String c) => c.codeUnitAt(0) >= 0x30 && c.codeUnitAt(0) <= 0x39;

  static bool _isSelectorLike(String s) {
    if (s.isEmpty) return false;
    final c = s[0];
    if (c == '*' || c == '#' || c == '.') return true;
    // 常见标签名 / 复杂选择器的宽松判断
    if (_isAlphaLower(c)) return true;
    return false;
  }

  static bool _isAlphaLower(String c) {
    final u = c.codeUnitAt(0);
    return (u >= 0x61 && u <= 0x7a) || (u >= 0x30 && u <= 0x39);
  }

  static bool _looksLikeExclude(String before) => before.endsWith('!');

  /// 匹配 `before[content]`，返回 (before, content)；未匹配返回 null。
  static (String, String)? _matchBracket(String rule) {
    final close = rule.lastIndexOf(']');
    if (close < 0) return null;
    var open = close;
    while (open >= 0 && rule[open] != '[') {
      open--;
    }
    if (open < 0 || open >= close) return null;
    final before = rule.substring(0, open).trim();
    final content = rule.substring(open + 1, close);
    if (!_isSelectorLike(before)) return null;
    return (before, content);
  }

  /// 解析 `[a, b:c:d, e]` 索引列表，返回 (解析结果, 是否排除)。无法解析返回 null。
  static (List<List<int>>, bool)? _parseBracket(String content) {
    final s = content.trim();
    var exclude = false;
    var body = s;
    if (body.startsWith('!')) {
      exclude = true;
      body = body.substring(1).trim();
    } else if (body.startsWith('.')) {
      body = body.substring(1).trim();
    }
    final out = <List<int>>[];
    // 按逗号拆，忽略复合区间内的逗号前空格
    for (final part in body.split(',')) {
      final p = part.trim();
      if (p.isEmpty) continue;
      final segs = p.split(':');
      final nums = <int>[];
      for (final seg in segs) {
        final n = int.tryParse(seg.trim());
        if (n == null) {
          nums.clear();
          break;
        }
        nums.add(n);
      }
      if (nums.isEmpty) continue;
      if (nums.length > 3) nums.length = 3;
      out.add(nums);
    }
    if (out.isEmpty) return null;
    return (out, exclude);
  }
}