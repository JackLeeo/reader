// Legado规则引擎 - 解析书源规则
// 支持语法:
//   - 选择器: tag.X / class.X / id.X / .X / #X / text.PATTERN
//   - 链式:   class.even@tag.a.0@href  (前N个@是子选择器, 最后@xxx是提取类型)
//   - AND链:  class.a&&tag.b          (同时满足, 每个&&段对前结果再查)
//   - 备选:   ||
//   - 位置:   :first / :last / :nth(n) / :skip(n) / :nth-of-type / :nth-child
//   - 索引:   .N (N>=0) / .-N (倒数)
//   - 排除:   !N
//   - 范围:   :N:M (从N到M) / :N:-M (从N到倒数第M)
//   - 替换:   ##pattern##replacement
//   - 提取:   text / html / src / href / ownText / textNodes / all / outerHtml
//             @text @html @src @href @ownText @textNodes @all @outerHtml
//             @data-attr  (任意属性)
//   - 快捷:   "text" / "href" / "src" / "html" 当上下文是Element时, 直接返回该值
//   - JS:     <js>...code...</js>   /   @js:\ncode   (基本透传, 无JS引擎时返回原值)
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import 'json_selector.dart';

class RuleEngine {
  final Uri baseUri;
  RuleEngine(this.baseUri);

  /// 已知提取类型 (出现在链尾的 @xxx, 用于判断该段是提取还是子选择器)
  static const _extractTypes = <String>{
    'text', 'html', 'outerHtml', 'src', 'href', 'ownText', 'textNodes', 'all',
  };

  /// 已知 HTML 标签名集合 (用于"裸字"启发式: 命中标签用tag, 否则用class)
  static const _knownTags = <String>{
    'a', 'abbr', 'address', 'article', 'aside', 'b', 'big', 'blockquote',
    'body', 'br', 'button', 'canvas', 'caption', 'cite', 'code', 'col',
    'colgroup', 'dd', 'del', 'details', 'dfn', 'dialog', 'div', 'dl', 'dt',
    'em', 'embed', 'fieldset', 'figcaption', 'figure', 'footer', 'form',
    'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'head', 'header', 'hgroup', 'hr',
    'html', 'i', 'iframe', 'img', 'input', 'ins', 'kbd', 'label', 'legend',
    'li', 'link', 'main', 'map', 'mark', 'menu', 'meta', 'nav', 'noscript',
    'object', 'ol', 'optgroup', 'option', 'p', 'param', 'picture', 'pre',
    'progress', 'q', 'rp', 'rt', 'ruby', 's', 'samp', 'script', 'section',
    'select', 'small', 'source', 'span', 'strong', 'style', 'sub', 'summary',
    'sup', 'table', 'tbody', 'td', 'template', 'textarea', 'tfoot', 'th',
    'thead', 'time', 'title', 'tr', 'track', 'u', 'ul', 'var', 'video', 'wbr',
  };

  /// 解析HTML文档
  static dom.Document parseHtml(String body) => html_parser.parse(body);

  /// 解析JSON值
  static Object? parseJson(String body) {
    final t = body.trim();
    if (t.isEmpty) return null;
    return JsonSelector.decode(t);
  }

  // ============== 公共 API ==============

  /// 列表提取: 返回元素列表 (用于 bookList / chapterList)
  List<dom.Element> selectList(dom.Document document, String rule) {
    if (rule.trim().isEmpty) return [];
    final (rawRule, _) = _splitReplace(rule);
    // JSON 类型: 不用元素引擎
    if (_looksLikeJsonPath(rawRule)) {
      return const [];
    }
    for (final alt in _splitAlternatives(rawRule)) {
      if (alt.isEmpty) continue;
      // 跳过 @js: 表达式 (无 JS 引擎支持, 跳过避免噪音)
      if (alt.trimLeft().startsWith('@js:') ||
          alt.trimLeft().startsWith('<js>') ||
          alt.contains('<js>')) {
        return const [];
      }
      final r = _evaluateChain(document.body!, null, alt, wantElements: true);
      if (r.found && r.elements.isNotEmpty) return r.elements;
    }
    return const [];
  }

  /// 在已有元素集合上应用子规则
  List<dom.Element> selectSubList(List<dom.Element> elements, String rule) {
    if (rule.trim().isEmpty || elements.isEmpty) return elements;
    final (rawRule, _) = _splitReplace(rule);
    for (final alt in _splitAlternatives(rawRule)) {
      if (alt.isEmpty) continue;
      if (alt.trimLeft().startsWith('@js:') ||
          alt.trimLeft().startsWith('<js>') ||
          alt.contains('<js>')) {
        return const [];
      }
      final collected = <dom.Element>[];
      for (final el in elements) {
        final r = _evaluateChain(el, null, alt, wantElements: true);
        if (r.found && r.elements.isNotEmpty) collected.addAll(r.elements);
      }
      if (collected.isNotEmpty) return collected;
    }
    return const [];
  }

  /// 单值提取
  String selectString(
    dynamic document, // 保留兼容, 未使用
    dynamic context, // dom.Element 或 List<dom.Element>
    String rule, {
    bool resolveUrl = false,
  }) {
    document; // unused
    if (rule.trim().isEmpty) {
      if (context is dom.Element) return context.text.trim();
      if (context is List && context.isNotEmpty && context.first is dom.Element) {
        return (context.first as dom.Element).text.trim();
      }
      return '';
    }

    final (rawRule, replace) = _splitReplace(rule);

    // 快捷: 当 context 是 Element 且 rule 是裸提取类型, 直接提取
    if (context is dom.Element) {
      final t = rawRule.trim();
      if (_extractTypes.contains(t) || t.startsWith('@')) {
        String value;
        final type = t.startsWith('@') ? t.substring(1) : t;
        if (type.contains('.') && !type.contains(' ')) {
          // 形如 @data-src 这种属性 (允许带 . 在属性名里? 但属性里不该有 .)
          value = context.attributes[type] ?? '';
        } else {
          value = _extractValue(context, type);
        }
        if (replace != null) value = _applyReplace(value, replace);
        if (resolveUrl && value.isNotEmpty) {
          value = _resolveUrl(value);
        }
        return value;
      }
    }

    // 初始元素集
    var seeds = <dom.Element>[];
    if (context is dom.Element) {
      seeds = [context];
    } else if (context is List && context.isNotEmpty) {
      seeds = context.whereType<dom.Element>().toList();
    }

    // 尝试每个 || 备选
    for (final alt in _splitAlternatives(rawRule)) {
      if (alt.isEmpty) continue;
      // @js: 表达式: 无 JS 引擎, 跳过
      if (alt.trimLeft().startsWith('@js:') ||
          alt.trimLeft().startsWith('<js>') ||
          alt.contains('<js>')) {
        return '';
      }
      // 如果是 @ 开头直接给提取类型 (如 @text, @src)
      if (alt.startsWith('@') && _extractTypes.contains(alt.substring(1).trim())) {
        if (seeds.isNotEmpty) {
          var value = _extractValue(seeds.first, alt.substring(1).trim());
          if (replace != null) value = _applyReplace(value, replace);
          if (resolveUrl && value.isNotEmpty) value = _resolveUrl(value);
          return value;
        }
        continue;
      }
      final r = _evaluateChain(context is dom.Element ? context : null, seeds, alt,
          wantElements: false);
      if (!r.found) continue;
      var value = r.value;
      if (replace != null) value = _applyReplace(value, replace);
      if (resolveUrl && value.isNotEmpty) value = _resolveUrl(value);
      return value;
    }
    return '';
  }

  String _resolveUrl(String value) {
    try {
      final resolved = baseUri.resolve(value);
      if (resolved.scheme == 'http' || resolved.scheme == 'https') {
        return resolved.toString();
      }
    } catch (_) {}
    return value;
  }

  List<String> extractAllText(List<dom.Element> elements) =>
      elements.map((e) => e.text.trim()).toList();

  // ============== 核心: 链式求值 ==============

  /// 单条规则链求值 (不含 || 和 ##)
  ///   - wantElements=true: 不剥提取类型, 把"最后一段"也作为选择器, 返回元素列表
  ///   - wantElements=false: 链尾是已知提取类型则剥, 否则全作选择器 + 默认@text
  _EvalResult _evaluateChain(
    dom.Element? root,
    List<dom.Element>? seeds,
    String rule, {
    required bool wantElements,
  }) {
    // 按 @ 拆链
    final parts = rule.split('@').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
    if (parts.isEmpty) return _EvalResult.miss();

    // 是否剥最后为提取类型 (仅在 wantElements=false 时)
    String? extractType;
    if (!wantElements && parts.length > 1 && _extractTypes.contains(parts.last)) {
      extractType = parts.removeLast();
    }

    // 初始元素: 有 seeds 用 seeds; 否则从 root 开始
    var current = <dom.Element>[];
    if (seeds != null) {
      current = List<dom.Element>.from(seeds);
    } else if (root != null) {
      current = [root];
    }

    if (current.isEmpty) return _EvalResult.miss();

    // 依次应用每段 (每段内可含 &&)
    for (var i = 0; i < parts.length; i++) {
      final seg = parts[i];
      final isLast = i == parts.length - 1;
      final subSteps = seg.split('&&').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
      if (subSteps.isEmpty) continue;

      final next = <dom.Element>[];
      for (final el in current) {
        for (final sub in subSteps) {
          if (sub.startsWith('@')) continue;
          final got =
              _applySelector(el, sub, isFinalStep: isLast && wantElements);
          next.addAll(got);
        }
        // 容错: self-reference (selector 不含 self) 时把 context 自身也加入
        //   例: context = <div class="item">, selector = "class.item"
        //   querySelectorAll 不含 self, 单独把 self 加入以支持 class.item@tag.a@text
        if (i == 0 && seeds != null && seeds.length == 1 && seeds.first == el) {
          // 单 context, 尝试 self-match
          for (final sub in subSteps) {
            if (_elementMatchesSelector(el, sub)) {
              if (!next.contains(el)) next.add(el);
            }
          }
        }
      }

      // 第一段没匹配但 seeds 是单个元素 -> 保留 current 继续
      if (next.isEmpty && i == 0 && seeds != null && seeds.length == 1) {
        continue;
      }

      if (next.isEmpty) return _EvalResult.miss();
      current = next;
    }

    if (current.isEmpty) return _EvalResult.miss();

    if (wantElements) {
      return _EvalResult(found: true, elements: current);
    }
    // wantElements=false: 已是最后一组元素
    final el = current.first;
    if (extractType != null) {
      return _EvalResult(found: true, value: _extractValue(el, extractType));
    }
    return _EvalResult(found: true, value: el.text.trim());
  }

  // ============== 内部: 单步选择 ==============

  /// 应用单个选择器
  ///   tag.X / class.X / id.X / .X / #X / text.PATTERN / X.N / X!N / X:first 等
  List<dom.Element> _applySelector(dom.Element root, String sel, {bool isFinalStep = false}) {
    if (sel.isEmpty) return const [];

    // 0. 特殊: ">" 或以 ">" 开头的子选择器 -> 不应单独出现
    if (sel == '>' || sel.startsWith('>')) return const [];

    // 1. 位置伪类 (在末尾, 形如 ":first" / ":nth(2)")
    //    CSS 伪类 (":nth-of-type(N)" / ":nth-child(N)") 保留在选择器中,
    //    由 querySelectorAll 直接处理
    String position = '';
    final posMatch = RegExp(
      r'^(.+?)(:(first|last|nth\(\d+\)|skip\(\d+\)))$',
    ).firstMatch(sel);
    if (posMatch != null) {
      sel = posMatch.group(1)!.trim();
      position = posMatch.group(2)!;
    }

    // 2. 排除索引 !N
    int? skipIndex;
    final exclMatch = RegExp(r'!(\d+)$').firstMatch(sel);
    if (exclMatch != null) {
      skipIndex = int.tryParse(exclMatch.group(1)!);
      sel = sel.substring(0, exclMatch.start);
    }

    // 3. 范围语法 :N:M 或 :N:-M (附加在尾部, 如 "tag.li.0:2:5" 选0,2,5; "tag.li:1:3" 选1到3)
    //    注意: 已经在 posMatch 里吃了 :nth(), 所以这里是其余形式
    final rangeMatch = RegExp(r'^(.+?):(\d+):(-?\d+)$').firstMatch(sel);
    List<int>? rangeIndices;
    String selAfterRange = sel;
    if (rangeMatch != null) {
      selAfterRange = rangeMatch.group(1)!;
      final start = int.parse(rangeMatch.group(2)!);
      final end = int.parse(rangeMatch.group(3)!);
      if (end >= 0) {
        rangeIndices = [for (var i = start; i <= end; i++) i];
      } else {
        // -1 表示最后一个
        rangeIndices = [for (var i = start; i >= -end; i--) i];
      }
    }

    // 4. 文本搜索: text.PATTERN
    if (selAfterRange.startsWith('text.') && selAfterRange.length > 5) {
      final pattern = selAfterRange.substring(5);
      final el = _findByText(root, RegExp(pattern));
      if (el == null) return const [];
      var list = [el];
      if (skipIndex != null && skipIndex < list.length) list.removeAt(skipIndex);
      if (position.isNotEmpty) list = _applyPosition(list, position);
      return list;
    }

    // 5. 普通选择 (类/标签/id/含空格的复杂选择)
    var list = _cssSelect(root, selAfterRange).toList();

    // 6. 索引 .N (允许负数表示倒数)
    final idxMatch = RegExp(r'\.(-?\d+)$').firstMatch(selAfterRange);
    if (idxMatch != null) {
      final n = int.parse(idxMatch.group(1)!);
      if (rangeIndices == null) {
        if (n < 0) {
          final realIdx = list.length + n;
          if (realIdx >= 0 && realIdx < list.length) {
            list = [list[realIdx]];
          } else {
            list = [];
          }
        } else {
          if (n < list.length) {
            list = [list[n]];
          } else {
            list = [];
          }
        }
      } else {
        // 范围
        final picked = <dom.Element>[];
        for (final idx in rangeIndices) {
          if (idx < 0) {
            final realIdx = list.length + idx;
            if (realIdx >= 0 && realIdx < list.length) picked.add(list[realIdx]);
          } else if (idx < list.length) {
            picked.add(list[idx]);
          }
        }
        list = picked;
      }
    } else if (rangeIndices != null) {
      final picked = <dom.Element>[];
      for (final idx in rangeIndices) {
        if (idx < 0) {
          final realIdx = list.length + idx;
          if (realIdx >= 0 && realIdx < list.length) picked.add(list[realIdx]);
        } else if (idx < list.length) {
          picked.add(list[idx]);
        }
      }
      list = picked;
    }

    // 7. 排除
    if (skipIndex != null && skipIndex < list.length) {
      final removed = list[skipIndex];
      list = list.where((e) => !identical(e, removed)).toList();
    }

    // 8. 位置伪类
    if (position.isNotEmpty) {
      list = _applyPosition(list, position);
    }

    return list;
  }

  /// CSS-like 选择
  /// 支持: tag.X / class.X / id.X / .X / #X / 裸字 / 带空格后代 / > 子选择器
  Iterable<dom.Element> _cssSelect(dom.Element root, String selector) sync* {
    final s = selector.trim();
    if (s.isEmpty) {
      yield root;
      return;
    }

    // 包含空格或 > 或 :nth-of-type :nth-child -- 整个作为 CSS 复合选择器
    if (s.contains(RegExp(r'\s+')) ||
        s.contains('>') ||
        s.contains(':nth-of-type') ||
        s.contains(':nth-child')) {
      // html 包的 querySelectorAll 不支持 :nth-of-type / :nth-child,
      // 手动实现 (剥伪类后用基础选择器拿到候选, 再按父节点的同类型/同位置过滤)
      final result = _evaluateComplexSelector(root, s);
      yield* result;
      return;
    }

    // tag选择: "tag.li" / "tag.li.0" (索引在外层处理)
    if (s.startsWith('tag.')) {
      final rest = s.substring(4);
      final dotIdx = rest.indexOf('.');
      final tagName = dotIdx < 0 ? rest : rest.substring(0, dotIdx);
      final restAfter = dotIdx < 0 ? '' : rest.substring(dotIdx + 1);
      final list = root.querySelectorAll(tagName);
      if (restAfter.isEmpty) {
        yield* list;
      } else {
        // restAfter 是纯数字 -> 索引, 不再过滤
        if (RegExp(r'^-?\d+$').hasMatch(restAfter)) {
          yield* list;
        } else {
          yield* _filterByExtra(list, restAfter);
        }
      }
      return;
    }

    // class选择: "class.foo" / ".foo"
    if (s.startsWith('class.')) {
      final rest = s.substring(6);
      final list = root.querySelectorAll('*[class]');
      yield* _filterByExtra(list, rest);
      return;
    }
    if (s.startsWith('.')) {
      final rest = s.substring(1);
      final list = root.querySelectorAll('*[class]');
      yield* _filterByExtra(list, rest);
      return;
    }

    // id选择
    if (s.startsWith('id.')) {
      final rest = s.substring(3);
      final list = root.querySelectorAll('*[id]');
      yield* _filterById(list, rest);
      return;
    }
    if (s.startsWith('#')) {
      final rest = s.substring(1);
      final list = root.querySelectorAll('*[id]');
      yield* _filterById(list, rest);
      return;
    }

    // 裸字: 启发式判断
    //   - 全小写且在已知标签集合 -> tag
    //   - 否则 -> class
    //   - 含 .N 索引 -> 剥索引后用前缀判断, 索引由 _applySelector 外层处理
    var baseForLookup = s;
    final baseDotIdx = s.lastIndexOf('.');
    if (baseDotIdx > 0) {
      final tail = s.substring(baseDotIdx + 1);
      if (RegExp(r'^-?\d+$').hasMatch(tail)) {
        baseForLookup = s.substring(0, baseDotIdx);
      }
    }
    if (_knownTags.contains(baseForLookup.toLowerCase())) {
      // 已知 tag, 去掉 .N 索引再查
      final tagOnly =
          baseForLookup.toLowerCase() + s.substring(baseForLookup.length);
      // 实际是: "tbody.0" -> querySelectorAll("tbody")
      // 索引已在 _applySelector 中处理
      final dotIdx2 = s.lastIndexOf('.');
      if (dotIdx2 > 0 && RegExp(r'^\.\d+$').hasMatch(s.substring(dotIdx2))) {
        yield* root.querySelectorAll(s.substring(0, dotIdx2));
      } else {
        yield* root.querySelectorAll(s);
      }
    } else {
      final list = root.querySelectorAll('*[class]');
      yield* _filterByExtra(list, s);
    }
  }

  /// 把 Legado 风格的复合选择转成 CSS
  String _toCssSelector(String s) {
    var t = s.trim();
    // tag.X.Y -> tag.X.Y (CSS 支持 tag.class)
    t = t.replaceAllMapped(
      RegExp(r'\btag\.([a-zA-Z][\w-]*)'),
      (m) => m.group(1)!,
    );
    // class.foo -> .foo
    t = t.replaceAllMapped(
      RegExp(r'\bclass\.([\w-]+)'),
      (m) => '.${m.group(1)}',
    );
    // id.foo -> #foo
    t = t.replaceAllMapped(
      RegExp(r'\bid\.([\w-]+)'),
      (m) => '#${m.group(1)}',
    );
    return t;
  }

  /// 复杂选择器: 处理后代 / > / :nth-of-type / :nth-child
  /// html 包的 querySelectorAll 不支持 :nth-of-type / :nth-child,
  /// 这里手动实现 (适用于带空格/>/伪类的复合选择)
  Iterable<dom.Element> _evaluateComplexSelector(
      dom.Element root, String selector) sync* {
    // 0. 先剥 nth-of-type / nth-child 标记, 记下要过滤的元素
    String nthTypeMode = ''; // '' | 'of-type' | 'child'
    int nthN = 0;
    var s = selector;
    final ofTypeMatch =
        RegExp(r':nth-of-type\((\d+)\)').firstMatch(s);
    if (ofTypeMatch != null) {
      nthTypeMode = 'of-type';
      nthN = int.parse(ofTypeMatch.group(1)!);
      s = s.replaceFirst(RegExp(r':nth-of-type\(\d+\)'), '');
    }
    final ofChildMatch = RegExp(r':nth-child\((\d+)\)').firstMatch(s);
    if (ofChildMatch != null) {
      nthTypeMode = 'child';
      nthN = int.parse(ofChildMatch.group(1)!);
      s = s.replaceFirst(RegExp(r':nth-child\(\d+\)'), '');
    }
    s = s.trim();

    // 1. 拆 descendant / > 链: 最后一个段是目标, 前面是祖先链
    //    例: ".mod li" ->  ["mod", "li"]
    //    例: ".mod > li" -> ["mod", ">", "li"]
    final tokens = <String>[];
    final buf = StringBuffer();
    var i = 0;
    while (i < s.length) {
      final c = s[i];
      if (c == ' ') {
        if (buf.isNotEmpty) {
          tokens.add(buf.toString());
          buf.clear();
        }
        // 跳过多余空格
        while (i + 1 < s.length && s[i + 1] == ' ') i++;
      } else if (c == '>') {
        if (buf.isNotEmpty) {
          tokens.add(buf.toString());
          buf.clear();
        }
        tokens.add('>');
        i++;
        while (i < s.length && s[i] == ' ') i++;
        continue;
      } else {
        buf.write(c);
      }
      i++;
    }
    if (buf.isNotEmpty) tokens.add(buf.toString());

    if (tokens.isEmpty) return;

    // 2. 末段是目标选择器, 在 root 中查找所有匹配
    final targetSel = tokens.last;
    final candidates = _cssSelect(root, targetSel).toList();

    // 3. 逐段链式过滤: 用 _findAncestorMatching / 直接父检查

    final filtered = <dom.Element>[];
    for (final el in candidates) {
      // 链式过滤: 逐段往上找
      var cur = el;
      var pass = true;
      var segIdx = tokens.length - 1;
      while (segIdx > 0) {
        segIdx--; // 移到上一个 token
        if (tokens[segIdx] == '>') {
          // 直接父
          segIdx--; // 再上一段是期望的 tag/class
          final wantSel = tokens[segIdx];
          final parent = cur.parent;
          if (parent == null || parent is! dom.Element) {
            pass = false;
            break;
          }
          if (!_elementMatchesSelector(parent, wantSel)) {
            pass = false;
            break;
          }
          cur = parent;
        } else {
          // 后代: 向上找匹配段
          final wantSel = tokens[segIdx];
          final p = _findAncestorMatching(cur, wantSel);
          if (p == null) {
            pass = false;
            break;
          }
          cur = p;
        }
      }
      if (pass) filtered.add(el);
    }

    // 4. 应用 nth-of-type / nth-child
    if (nthTypeMode == 'of-type') {
      // 按 (parent, localName) 分组, 取每组中第 nthN 个 (1-based)
      final byKey = <String, List<dom.Element>>{};
      for (final el in filtered) {
        final key = '${identityHashCode(el.parent)}_${el.localName}';
        byKey.putIfAbsent(key, () => []).add(el);
      }
      for (final list in byKey.values) {
        if (nthN - 1 >= 0 && nthN - 1 < list.length) {
          yield list[nthN - 1];
        }
      }
      return;
    }
    if (nthTypeMode == 'child') {
      // 按 parent 分组, 取每组中第 nthN 个 child (1-based)
      final byParent = <int, List<dom.Element>>{};
      for (final el in filtered) {
        final pid = identityHashCode(el.parent);
        byParent.putIfAbsent(pid, () => []).add(el);
      }
      for (final list in byParent.values) {
        if (nthN - 1 >= 0 && nthN - 1 < list.length) {
          yield list[nthN - 1];
        }
      }
      return;
    }

    yield* filtered;
  }

  /// 向上找匹配 selector 的最近祖先
  dom.Element? _findAncestorMatching(dom.Element el, String selector) {
    dom.Node? cur = el.parent;
    while (cur != null) {
      if (cur is dom.Element && _elementMatchesSelector(cur, selector)) {
        return cur;
      }
      cur = cur.parent;
    }
    return null;
  }

  /// 按类名 / 索引 进一步过滤
  Iterable<dom.Element> _filterByExtra(List<dom.Element> list, String extra) sync* {
    // extra 可能是 "outer.inner" (多个类) 或 "name.0" (类+索引, 但索引已剥离)
    // 简单实现: 只要元素包含第一个类名即匹配
    final classNames = extra.split(RegExp(r'[.#]')).where((s) => s.isNotEmpty).toList();
    if (classNames.isEmpty) {
      yield* list;
      return;
    }
    for (final el in list) {
      final classes = (el.className).split(RegExp(r'\s+'));
      bool matched = true;
      for (final cn in classNames) {
        if (!classes.contains(cn)) {
          matched = false;
          break;
        }
      }
      if (matched) yield el;
    }
  }

  /// 判断单个元素是否匹配 Legado 选择器 (用于 self-reference)
  bool _elementMatchesSelector(dom.Element el, String selector) {
    final s = selector.trim();
    if (s.isEmpty) return true;

    // 位置伪类后缀 :first/:last/:nth(N)/:skip(N) - 忽略这些后缀判断 self
    String position = '';
    var body = s;
    final posMatch = RegExp(r'^(.+?)(:(first|last|nth\(\d+\)|skip\(\d+\)))$').firstMatch(s);
    if (posMatch != null) {
      body = posMatch.group(1)!.trim();
      position = posMatch.group(2)!;
    }

    // 排除 !N - 同样忽略
    final exclMatch = RegExp(r'!(\d+)$').firstMatch(body);
    if (exclMatch != null) {
      body = body.substring(0, exclMatch.start);
    }

    // 范围 :N:M - 忽略
    final rangeMatch = RegExp(r'^(.+?):(\d+):(-?\d+)$').firstMatch(body);
    if (rangeMatch != null) {
      body = rangeMatch.group(1)!;
    }

    // text.PATTERN
    if (body.startsWith('text.') && body.length > 5) {
      final pattern = body.substring(5);
      try {
        return RegExp(pattern).hasMatch(el.text);
      } catch (_) {
        return false;
      }
    }

    // 索引 .N
    if (RegExp(r'\.(-?\d+)$').hasMatch(body)) {
      body = body.substring(0, body.lastIndexOf('.'));
    }

    final rest = body;

    // tag.X
    if (rest.startsWith('tag.')) {
      final name = rest.substring(4).split('.').first;
      if (el.localName?.toLowerCase() != name.toLowerCase()) return false;
      // 含类名时再校验
      final classesPart = rest.substring(4 + name.length);
      if (classesPart.startsWith('.')) {
        final cls = classesPart.substring(1).split('.').first;
        return (el.className).split(RegExp(r'\s+')).contains(cls);
      }
      return true;
    }

    // class.X / .X
    if (rest.startsWith('class.')) {
      final cls = rest.substring(6).split('.').first;
      return (el.className).split(RegExp(r'\s+')).contains(cls);
    }
    if (rest.startsWith('.')) {
      final cls = rest.substring(1).split('.').first;
      return (el.className).split(RegExp(r'\s+')).contains(cls);
    }

    // id.X / #X
    if (rest.startsWith('id.')) {
      return el.id == rest.substring(3).split('.').first;
    }
    if (rest.startsWith('#')) {
      return el.id == rest.substring(1).split('.').first;
    }

    // 裸字: 启发式
    if (_knownTags.contains(rest.toLowerCase())) {
      return el.localName?.toLowerCase() == rest.toLowerCase();
    }
    // 否则视为 class
    return (el.className).split(RegExp(r'\s+')).contains(rest);
  }

  /// 按 id 精确匹配
  Iterable<dom.Element> _filterById(List<dom.Element> list, String id) sync* {
    for (final el in list) {
      if (el.id == id) yield el;
    }
  }

  /// 按文本正则查找 (返回首个匹配文本的元素)
  dom.Element? _findByText(dom.Element root, RegExp pattern) {
    if (root.children.isEmpty) {
      if (pattern.hasMatch(root.text)) return root;
      return null;
    }
    for (final child in root.children) {
      final r = _findByText(child, pattern);
      if (r != null) return r;
    }
    if (pattern.hasMatch(root.text)) return root;
    return null;
  }

  List<dom.Element> _applyPosition(List<dom.Element> list, String position) {
    if (list.isEmpty) return list;
    if (position == ':first') return [list.first];
    if (position == ':last') return [list.last];
    final nth = RegExp(r':nth\((\d+)\)').firstMatch(position);
    if (nth != null) {
      final n = int.parse(nth.group(1)!);
      if (n < list.length) return [list[n]];
      return [];
    }
    final skip = RegExp(r':skip\((\d+)\)').firstMatch(position);
    if (skip != null) {
      final n = int.parse(skip.group(1)!);
      if (n >= list.length) return [];
      return list.sublist(n);
    }
    // CSS 伪类 (nth-of-type / nth-child) - 已在 _cssSelect 处理
    return list;
  }

  // ============== 内部: 提取 ==============

  String _extractValue(dom.Element element, String type) {
    switch (type) {
      case 'text':
        return element.text.trim();
      case 'textNodes':
        return element.nodes
            .whereType<dom.Text>()
            .map((t) => t.text)
            .join()
            .trim();
      case 'html':
        return element.innerHtml;
      case 'outerHtml':
        return element.outerHtml;
      case 'src':
        return element.attributes['src'] ?? element.attributes['data-src'] ?? '';
      case 'href':
        return element.attributes['href'] ?? '';
      case 'ownText':
        return element.nodes
            .whereType<dom.Text>()
            .map((t) => t.text)
            .join()
            .trim();
      case 'all':
        return element.text.trim();
      default:
        // 自定义属性: @data-id, @title 等
        if (type.startsWith('@')) {
          return element.attributes[type.substring(1)] ?? '';
        }
        return element.text.trim();
    }
  }

  // ============== 内部: 工具 ==============

  /// 拆分 ##pattern##replacement
  (String, _ReplaceRule?) _splitReplace(String rule) {
    final idx = rule.indexOf('##');
    if (idx < 0) return (rule, null);
    final main = rule.substring(0, idx);
    final rest = rule.substring(idx + 2);
    final sepIdx = rest.indexOf('##');
    if (sepIdx < 0) {
      return (main, _ReplaceRule(pattern: rest, replacement: ''));
    }
    return (
      main,
      _ReplaceRule(
        pattern: rest.substring(0, sepIdx),
        replacement: rest.substring(sepIdx + 2),
      ),
    );
  }

  /// 拆分 || 备选
  List<String> _splitAlternatives(String rule) =>
      rule.split('||').map((s) => s.trim()).toList();

  String _applyReplace(String input, _ReplaceRule rule) {
    try {
      final pattern = RegExp(rule.pattern, multiLine: true, dotAll: true);
      return input.replaceAll(pattern, rule.replacement);
    } catch (_) {
      return input;
    }
  }

  /// 判断是否是 JSONPath
  bool _looksLikeJsonPath(String s) {
    final t = s.trimLeft();
    return t.startsWith(r'$.') || t.startsWith(r'$[') || t.startsWith(r'$..');
  }
}

/// 求值结果
class _EvalResult {
  final bool found;
  final String value;
  final List<dom.Element> elements;
  const _EvalResult({this.found = false, this.value = '', this.elements = const []});
  factory _EvalResult.miss() => const _EvalResult();
  factory _EvalResult.hit(String value) =>
      _EvalResult(found: true, value: value, elements: const []);
  factory _EvalResult.elements(List<dom.Element> els) =>
      _EvalResult(found: true, value: '', elements: els);
}

class _ReplaceRule {
  final String pattern;
  final String replacement;
  const _ReplaceRule({required this.pattern, this.replacement = ''});
}
