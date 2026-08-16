import 'dart:math' as math;

/// 业界沉淀下来的章节标题识别规则库（从其他项目导出的 19 条正则，
/// 按 serialNumber 保留原始顺序，并结合 enable 字段拆成「默认集」
/// 与「完整集」）。
///
/// 这个库同时服务三条链路：
///  1) Legado 书源目录抓取的 fallback：当 chapterList 规则匹配 0 条
///     或 "命中数 >> 有效章节数"（说明抓到太多杂项）时，退化为全
///     链接扫描 + [ChapterHeadingLibrary.filter] 过滤出真正的标题。
///  2) 本地 TXT 导入切章：替代 [txt_chapter_parser.dart] 里单条
///     硬编码正则，覆盖"数字-分隔符-标题""中文大写数字""特殊符号包裹"
///     等常见民间 TXT 风格。
///  3) 换源章节对齐：把 "（1）第一章 雪夜 【VIP】/【新书】" 之类
///     带前后装饰的脏标题归一化成语义形式，对齐成功率更高。
class ChapterHeadingLibrary {
  const ChapterHeadingLibrary._();

  /// 默认启用集合：serialNumber 对应 enable=true 的条目，误判率低。
  static List<ChapterHeadingRule> get defaultRules =>
      _compiledRules.where((r) => r.enabledByDefault).toList(growable: false);

  /// 完整集合（含默认关闭的高召回/场景专用项）。调用方可以按置信度
  /// 自行开关，例如 TXT 导入时先跑默认集，命中<2 条再开完整集。
  static List<ChapterHeadingRule> get allRules =>
      List.unmodifiable(_compiledRules);

  /// 判定单行文本是否像章节标题。
  static bool looksLikeHeading(
    String line, {
    List<ChapterHeadingRule>? rules,
  }) {
    final candidates = rules ?? defaultRules;
    final text = line.trim();
    if (text.isEmpty) return false;
    for (final rule in candidates) {
      if (rule.pattern.hasMatch(text)) return true;
    }
    return false;
  }

  /// 从一批候选里只留下像章节标题的，保留原顺序。
  ///
  /// [minMatch] 控制"至少命中几条规则才算真标题"：目录页抓取时建议 1
  /// （因为每条规则专门对应一种写法），正文伪章过滤时建议上调到 1+
  /// 并结合 [isolateByUrls] 的 URL 相似度做二次判断。
  static List<T> filter<T>(
    Iterable<T> candidates, {
    required String Function(T) titleOf,
    List<ChapterHeadingRule>? rules,
    int minMatch = 1,
  }) {
    final list = candidates.toList(growable: false);
    if (list.isEmpty) return const [];
    final effective = rules ?? defaultRules;
    final out = <T>[];
    for (final item in list) {
      final title = titleOf(item).trim();
      if (title.isEmpty) continue;
      var hits = 0;
      for (final rule in effective) {
        if (rule.pattern.hasMatch(title)) {
          hits++;
          if (hits >= minMatch) {
            out.add(item);
            break;
          }
        }
      }
    }
    return out;
  }

  /// 章节标题语义归一化：把装饰符、前后非语义块、重复空白去掉，
  /// 用于跨源换源对齐时的等值/包含比较。
  ///
  /// 步骤：
  ///  1) 压缩空白（含全角空格/tab/换行）为单空格。
  ///  2) 去掉成对的包裹符号内的"非章节序号标签"：
  ///     【新书】【VIP】/（1）/「推荐」/（订阅）这类装饰通常对
  ///     齐没帮助，先丢；序号型括号（(1)（一）、1 等）会保留。
  ///  3) 去掉开头末尾的纯装饰符。
  static String normalizeForCrossSource(String title) {
    var text = title.replaceAll(RegExp(r'[\s\u3000\r\n\t]+'), ' ').trim();
    if (text.isEmpty) return '';

    // 连续剥离成对的装饰括号，直到没有更多变化（解决"【VIP】【新书】..."
    // 这种多对括号叠加的情况）。
    for (var iter = 0; iter < 4; iter++) {
      final before = text;
      text = text.replaceAllMapped(
        RegExp(
          r'([【\[〔〖「『〈《\(（])\s*([^】\]〕〗」』〉》\)）]{1,20})\s*([】\]〕〗」』〉》\)）])',
        ),
        (match) {
          final open = match.group(1)!;
          final inner = match.group(2)!.trim();
          final close = match.group(3)!;
          // 先确认括号类型"大致配对"（防乱序）
          if (!_isMatchingBracket(open, close)) return match.group(0)!;
          if (_looksLikeDecorativeBracket(open, inner, close)) return '';
          return match.group(0)!;
        },
      ).replaceAll(RegExp(r'\s+'), ' ').trim();
      if (text == before) break;
    }

    // 移除头尾零散的装饰符号
    const trailingDecor = r'[\s\-—_=·•・☆★✦✧◆◇■□▲△▼▽※\*\+\#\^]+';
    text = text
        .replaceFirst(RegExp('^$trailingDecor'), '')
        .replaceFirst(RegExp('$trailingDecor\$'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return text;
  }

  static bool _isMatchingBracket(String open, String close) {
    const pairs = <String, String>{
      '【': '】', '[': ']', '〔': '〕', '〖': '〗', '「': '」',
      '『': '』', '〈': '〉', '《': '》', '(': ')', '（': '）',
    };
    return pairs[open] == close;
  }

  static bool _looksLikeDecorativeBracket(
    String open,
    String inner,
    String close,
  ) {
    if (inner.isEmpty) return true;
    // 如果括号里明显是数字序号（如 (1)、（一）、【1】），保留
    if (_numericChars.hasMatch(inner)) return false;
    // 常见装饰词：删除
    if (_decorativeKeywords.hasMatch(inner)) return true;
    // 纯非语义短字符视为装饰
    if (RegExp(r'^[\p{P}\p{S}\s]+$', unicode: true).hasMatch(inner)) return true;
    // 长度 ≤ 4 且不含常见"章节语义字"的也视作装饰（如"广告""热推"）
    if (inner.length <= 4 &&
        !_chapterSemanticChars.hasMatch(inner)) return true;
    return false;
  }

  static final RegExp _numericChars = RegExp(
    r'^(?:[\d０-９零〇一二两三四五六七八九十百千万两壹贰叁肆伍陆柒捌玖拾佰仟]+|part|chapter|section|episode|no\.?|回|场|篇|卷|集|部|章|节)$',
    caseSensitive: false,
  );

  static final RegExp _chapterSemanticChars =
      RegExp(r'[章节卷回场篇部集正文章]|序|楔|尾|后|前|言|文|案|引|跋|结');

  static final RegExp _decorativeKeywords = RegExp(
    r'^(VIP|加更|新书|推荐|收藏|订阅|月票|打赏|求票|合集|正文卷|上|下|免费|付费|上架|首订|公告|上架感言|请假条|请假|说明|通知|感言|番外篇|广告|热推|更?新?|HOT|热门)$',
    caseSensitive: false,
  );

  /// 从一行里"抽出"章节序号（若存在），用于换源章节对齐时
  /// 用"纯标题匹配失败 → 序号相等也视作同一章"的兜底。
  ///
  /// 返回 null 表示找不到任何像序号的片段。
  static ChapterHeadingIndex? extractIndex(String title) {
    final normalized = normalizeForCrossSource(title);
    if (normalized.isEmpty) return null;

    // 1) 中文：第X章 / 第X节 / 第X卷 ...
    final zh = RegExp(
      r'第\s*([\d零〇一二两三四五六七八九十百千万两壹贰叁肆伍陆柒捌玖拾佰仟]{1,12})\s*([章节卷部篇回场集])',
    ).firstMatch(normalized);
    if (zh != null) {
      final value = _parseChineseNumber(zh.group(1)!);
      if (value != null) {
        return ChapterHeadingIndex(
          numeric: value,
          unit: zh.group(2)!,
          raw: zh.group(0)!,
        );
      }
    }

    // 2) 英文 Chapter / Section / Part / Episode / No.
    final en = RegExp(
      r'(?:chapter|section|part|episode|no\.?)[\s　]*([\d０-９]{1,8})',
      caseSensitive: false,
    ).firstMatch(normalized);
    if (en != null) {
      final n = _parseIntFullwidth(en.group(1)!);
      if (n != null) {
        final prefix = en.group(0)!.toLowerCase();
        String unit = '章';
        if (prefix.startsWith('section')) {
          unit = '节';
        } else if (prefix.startsWith('part')) {
          unit = '部';
        } else if (prefix.startsWith('episode')) {
          unit = '集';
        }
        return ChapterHeadingIndex(
          numeric: n,
          unit: unit,
          raw: en.group(0)!,
        );
      }
    }

    // 3) 数字 + 分隔符："12. 风雪夜" / "001-风雪夜"
    final plain =
        RegExp(r'^([\d０-９]{1,8})[\s　]*[.、,，_\-—][\s　]*').firstMatch(normalized);
    if (plain != null) {
      final n = _parseIntFullwidth(plain.group(1)!);
      if (n != null) {
        return ChapterHeadingIndex(
          numeric: n,
          unit: '',
          raw: plain.group(0)!,
        );
      }
    }

    // 4) 特殊符号开头的序号："【第一章】" "〔Chapter 1〕"
    final bracket = RegExp(
      r'[【\[〔〖「『〈《\(（][\s　]*(?:第|chapter)[\s　]*([\d０-９零〇一二两三四五六七八九十百千万两壹贰叁肆伍陆柒捌玖拾佰仟]{1,12})[\s　]*[章节]',
      caseSensitive: false,
    ).firstMatch(normalized);
    if (bracket != null) {
      final value = _parseChineseNumber(bracket.group(1)!);
      if (value != null) {
        return ChapterHeadingIndex(
          numeric: value,
          unit: '章',
          raw: bracket.group(0)!,
        );
      }
    }
    return null;
  }

  static int? _parseIntFullwidth(String raw) {
    var s = raw;
    const fullwidth = '０１２３４５６７８９';
    const halfwidth = '0123456789';
    for (var i = 0; i < fullwidth.length; i++) {
      s = s.replaceAll(fullwidth[i], halfwidth[i]);
    }
    return int.tryParse(s);
  }

  static int? _parseChineseNumber(String raw) {
    final digits = _parseIntFullwidth(raw);
    if (digits != null) return digits;
    return ChineseNumberParser.tryParse(raw);
  }
}

/// 从导出 JSON 反序列化后的单条规则。
///
/// 为避免 Dart 全局对象初始化慢，规则里的 RegExp 懒编译且作为
/// static const 存放在 [_rules] 里，而不是运行期 fromJson。
class ChapterHeadingRule {
  const ChapterHeadingRule({
    required this.name,
    required this.pattern,
    required this.enabledByDefault,
    required this.serialNumber,
  });

  final String name;
  final RegExp pattern;
  final bool enabledByDefault;
  final int serialNumber;
}

/// 章节标题序号的结构化结果，用于换源对齐的二级 fallback。
class ChapterHeadingIndex {
  const ChapterHeadingIndex({
    required this.numeric,
    required this.unit,
    required this.raw,
  });

  /// 解析后统一成 int。中文数字大写也会落到这里。
  final int numeric;

  /// '章' / '节' / '部' / '集' / ''（纯数字标题）。
  final String unit;

  /// 原文本中匹配到的片段，用于诊断。
  final String raw;
}

/// 轻量中文数字解析：支持 零一二两三四五六七八九十百千万 以及
/// 壹贰叁肆伍陆柒捌玖拾佰仟。只覆盖书籍标题会用到的范围 ——
/// 1 到 99,999,999（一亿以内），足够支撑任何书籍章数。
class ChineseNumberParser {
  const ChineseNumberParser._();

  static const Map<String, int> _digits = {
    '零': 0, '〇': 0, '○': 0, '0': 0,
    '一': 1, '壹': 1, '两': 2, '二': 2, '贰': 2,
    '三': 3, '叁': 3, '四': 4, '肆': 4,
    '五': 5, '伍': 5, '六': 6, '陆': 6,
    '七': 7, '柒': 7, '八': 8, '捌': 8,
    '九': 9, '玖': 9,
  };

  static const Map<String, int> _units = {
    '十': 10, '拾': 10,
    '百': 100, '佰': 100,
    '千': 1000, '仟': 1000,
    '万': 10000,
  };

  static int? tryParse(String input) {
    var s = input.trim();
    if (s.isEmpty) return null;
    // 处理全角数字 -> 半角
    const fullwidth = '０１２３４５６７８９';
    const halfwidth = '0123456789';
    for (var i = 0; i < fullwidth.length; i++) {
      s = s.replaceAll(fullwidth[i], halfwidth[i]);
    }
    final pureDigits = int.tryParse(s);
    if (pureDigits != null) return pureDigits;

    var total = 0;
    var section = 0;
    var current = 0;
    var seenAny = false;

    for (var i = 0; i < s.length; i++) {
      final ch = s[i];
      final d = _digits[ch];
      if (d != null) {
        current = d;
        seenAny = true;
        continue;
      }
      final u = _units[ch];
      if (u == null) return null; // 夹杂未知字符
      seenAny = true;
      if (u == 10000) {
        // "万"作为段分隔：先把段加上当前位，然后入段
        section = (section + current) * u;
        total += section;
        section = 0;
      } else {
        // 十/百/千：如果 current=0（典型的"十=一十"开头写法），补 1
        final base = current == 0 ? 1 : current;
        section += base * u;
      }
      current = 0;
    }
    if (!seenAny) return null;
    return total + section + current;
  }
}

/// ---------------- 规则常量（从导出 JSON 手工重写，保留 serialNumber 顺序） ----------------
///
/// 说明：原始 19 条里大量用了 ^ 行首 / (?<=...) 后顾断言。TXT 解析场景
/// 每行是独立的；Legado 目录 fallback 场景下每条也是被 HTML 解析器切出
/// 的「节点纯文本」，所以 ^ 是合理的。仅原始里"纯后顾"开头的几条（2、3、5、11、12、13、16、17）
/// 我们会加一个 ^[\\s　]*? 的弱前导，保证单独一行文本也能命中，同时不影响原
/// 后顾场景（当它出现在更大段文本中时）。
///
/// 注意：Dart 的 `const List` 要求元素也是 const 构造。RegExp 在 Dart 里
/// **不是** const 构造的，所以这里用 `static final` 懒加载 + 只读 unmodifiable
/// list。调用方拿 defaultRules/allRules 时已经在 library 内部维护了唯一实例。
List<ChapterHeadingRule> get _compiledRules {
  if (__rulesCache != null) return __rulesCache!;
  RegExp safePattern(String source, {bool multiLine = false, bool unicode = false}) {
    // Dart RegExp 默认不支持 .NET 风格的命名组 (?<name>xxx) 与后顾中的
    // 可变宽度字符类，所以统一把 (?<=...X{0,N}) 这种形式替换成 ^ 通配：
    // TXT/标题匹配场景下我们总是按行判断，行前空白的后顾其实等价于行首允许空白。
    var s = source;
    // 1) 把后顾断言里的可变字符类（如 [xx]{0,4}）替换成只匹配固定字符
    //    或直接转成"允许开头"的形式。这里做一个简单重写：
    //    将 (?<=[X]{0,N}) → 替换为"不消耗，但要求前面是 X 或行首"，
    //    在 Dart 里最稳妥是直接去掉该后顾（因为我们在单独一行上匹配，
    //    后续的字符模式本身会在"贴边"时命中）。
    s = s.replaceAllMapped(
      RegExp(r'\(\?\<=\[?[^\]]*\]?\{[0-9],[0-9]*\}\)'),
      (_) => '',
    );
    // 2) 还有纯 (?<=单字符类) 如 (?<=[　\s])，Dart 是 OK 的，不用改。
    //    但 " (?<=[　\s])|^[\s　]*? " 这种分支式 "|" 左半边可能含上面
    //    的模式，已经在 (1) 里处理掉了。
    try {
      return RegExp(s, multiLine: multiLine, unicode: unicode);
    } on FormatException {
      // 若仍有 Dart 不支持的正则特性（比如 (?m) 内嵌在 pattern 开头 + 可变宽度后顾），
      // 把整个 pattern 里的 (?m) 单独抽出来，并再次去掉可变宽度后顾。
      var ml = multiLine;
      if (s.startsWith('(?m)')) {
        ml = true;
        s = s.substring(4);
      }
      s = s.replaceAllMapped(
        RegExp(r'\(\?\<=[^)]{1,80}\)'),
        (_) => '',
      );
      return RegExp(s, multiLine: ml, unicode: unicode);
    }
  }

  final list = <ChapterHeadingRule>[
    // 0: 相对通用 —— 提取式正则，标题中含"第X章/草"。
    ChapterHeadingRule(
      serialNumber: 0,
      name: '相对通用',
      enabledByDefault: true,
      pattern: safePattern(r'第([一二两三四五六七八九十○零百千0-9１２３４５６７８９０]{1,10})[章草]'),
    ),

    // 1: 目录 —— 行首的标准中文/数字 + 章/节/卷/集/部/篇（含负向前瞻过滤掉"节课/集合/部分/篇张"）。
    ChapterHeadingRule(
      serialNumber: 1,
      name: '目录',
      enabledByDefault: true,
      pattern: safePattern(
        r'^[ 　\t]{0,4}(?:序章|楔子|正文(?!完|结)|终章|后记|尾声|番外|第?\s{0,4}[\d零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]+?\s{0,4}(?:章|节(?!课)|卷|集(?![合和])|部(?!分)|篇(?!张))).{0,30}$',
      ),
    ),

    // 2: 目录(去空白) —— 从长文本里"贴边"摘，默认关。
    ChapterHeadingRule(
      serialNumber: 2,
      name: '目录(去空白)',
      enabledByDefault: false,
      pattern: safePattern(
        r'(?:(?<=[　\s])|^[　\s]*?)(?:序章|楔子|正文(?!完|结)|终章|后记|尾声|番外|第?\s{0,4}[\d零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]+?\s{0,4}(?:章|节(?!课)|卷|集(?![合和])|部(?!分)|篇(?!张))).{0,30}$',
      ),
    ),

    // 3: 目录(匹配简介) —— 把"简介/文案/前言"也算做章节，默认关。
    ChapterHeadingRule(
      serialNumber: 3,
      name: '目录(匹配简介)',
      enabledByDefault: false,
      pattern: safePattern(
        r'(?:(?<=[　\s])|^[　\s]*?)(?:(?:内容|文章)?简介|文案|前言|序章|楔子|正文(?!完|结)|终章|后记|尾声|番外|第?\s{0,4}[\d零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]+?\s{0,4}(?:章|节(?!课)|卷|集(?![合和])|部(?!分)|回(?![合来事去])|场(?![和合比电是])|篇(?!张))).{0,30}$',
      ),
    ),

    // 4: 目录(古典、轻小说备用) —— 行首 + 回/场。默认关。
    ChapterHeadingRule(
      serialNumber: 4,
      name: '目录(古典、轻小说备用)',
      enabledByDefault: false,
      pattern: safePattern(
        r'^[ 　\t]{0,4}(?:序章|楔子|正文(?!完|结)|终章|后记|尾声|番外|第?\s{0,4}[\d零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]+?\s{0,4}(?:章|节(?!课)|卷|集(?![合和])|部(?!分)|回(?![合来事去])|场(?![和合比电是])|篇(?!张))).{0,30}$',
      ),
    ),

    // 5: 数字(纯数字标题) —— 贴空白后的纯数字。默认关：误判率高。
    ChapterHeadingRule(
      serialNumber: 5,
      name: '数字(纯数字标题)',
      enabledByDefault: false,
      pattern: safePattern(r'(?:(?<=[　\s])|^[　\s]*?)\d+[ 　\t]{0,4}$'),
    ),

    // 6: 数字 分隔符 标题名称 —— 1.xxx / 1,xxx / 1-xxx
    ChapterHeadingRule(
      serialNumber: 6,
      name: '数字 分隔符 标题名称',
      enabledByDefault: true,
      pattern: safePattern(r'^[ 　\t]{0,4}\d{1,5}[,.， 、_—\-].{1,30}$'),
    ),

    // 7: 大写数字 分隔符 标题名称 —— 一、风雪夜
    ChapterHeadingRule(
      serialNumber: 7,
      name: '大写数字 分隔符 标题名称',
      enabledByDefault: true,
      pattern: safePattern(
        r'^[ 　\t]{0,4}[零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]{1,8}[ 、_—\-].{1,30}$',
      ),
    ),

    // 8: 正文 标题/序号 —— 正文 第一章
    ChapterHeadingRule(
      serialNumber: 8,
      name: '正文 标题\/序号',
      enabledByDefault: true,
      pattern: safePattern(r'^[ 　\t]{0,4}正文[ 　]{1,4}.{0,20}$'),
    ),

    // 9: Chapter/Section/Part/Episode 序号 标题 —— 含简介/文案
    ChapterHeadingRule(
      serialNumber: 9,
      name: 'Chapter\/Section\/Part\/Episode 序号 标题',
      enabledByDefault: true,
      pattern: safePattern(
        r'^[ 　\t]{0,4}(?:[Cc]hapter|[Ss]ection|[Pp]art|ＰＡＲＴ|[Nn][oO]\.|[Ee]pisode|(?:内容|文章)?简介|文案|前言|序章|楔子|正文(?!完|结)|终章|后记|尾声|番外)[\s　]{0,4}[\d０-９]{1,4}.{0,30}$',
      ),
    ),

    // 10: Chapter(去简介) —— 只认英文章节词。默认关。
    ChapterHeadingRule(
      serialNumber: 10,
      name: 'Chapter(去简介)',
      enabledByDefault: false,
      pattern: safePattern(
        r'^[ 　\t]{0,4}(?:[Cc]hapter|[Ss]ection|[Pp]art|ＰＡＲＴ|[Nn][Oo]\.|[Ee]pisode)[\s　]{0,4}[\d０-９]{1,4}.{0,30}$',
      ),
    ),

    // 11: 特殊符号 序号 标题 —— 【第一章... / 〔Chapter ...
    ChapterHeadingRule(
      serialNumber: 11,
      name: '特殊符号 序号 标题',
      enabledByDefault: true,
      pattern: safePattern(
        r'(?:(?<=[\s　])|^[\s　]*?)[【〔〖「『〈［\[](?:第|[Cc]hapter)[\s　]*(?:[\d０-９零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]{1,10}[\s　]*[章节]|[\d０-９]{1,8}).{0,20}$',
      ),
    ),

    // 12: 特殊符号 标题(成对) —— [xxx] / (xxx)。默认关：误判率高。
    ChapterHeadingRule(
      serialNumber: 12,
      name: '特殊符号 标题(成对)',
      enabledByDefault: false,
      pattern: safePattern(
        r'(?:(?<=[\s　]{0,4})|^[\s　]{0,4})(?:[\[〈「『〖〔《（【\(].{1,30}[\)】）》〕〗』」〉\]]?|(?:内容|文章)?简介|文案|前言|序章|楔子|正文(?!完|结)|终章|后记|尾声|番外)[ 　]{0,4}$',
      ),
    ),

    // 13: 特殊符号 标题(单个) —— ☆★✦✧ + 文字
    ChapterHeadingRule(
      serialNumber: 13,
      name: '特殊符号 标题(单个)',
      enabledByDefault: true,
      pattern: safePattern(
        r'(?:(?<=[\s　]{0,4})|^[\s　]{0,4})(?:[☆★✦✧].{1,30}|(?:内容|文章)?简介|文案|前言|序章|楔子|正文(?!完|结)|终章|后记|尾声|番外)[ 　]{0,4}$',
      ),
    ),

    // 14: 章/卷 序号 标题 —— "卷一 大风" / "章一 风起" / 简介文案序章等。
    ChapterHeadingRule(
      serialNumber: 14,
      name: '章\/卷 序号 标题',
      enabledByDefault: true,
      pattern: safePattern(
        r'^[ \t　]{0,4}(?:(?:内容|文章)?简介|文案|前言|序章|楔子|正文(?!完|结)|终章|后记|尾声|番外|[卷章][\d零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]{1,8})[ 　]{0,4}.{0,30}$',
      ),
    ),

    // 15: 顶格标题 —— 开头不是空白，长度 1~20。默认关：误判率最高。
    ChapterHeadingRule(
      serialNumber: 15,
      name: '顶格标题',
      enabledByDefault: false,
      pattern: safePattern(r'^\S.{1,20}$'),
    ),

    // 16: 双标题(前向) —— 依赖上下文下一行也是标题，多行匹配专用。默认关。
    ChapterHeadingRule(
      serialNumber: 16,
      name: '双标题(前向)',
      enabledByDefault: false,
      pattern: safePattern(
        r'第[\d零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]{1,8}章.{0,30}$(?=[\s　]{0,8}第[\d零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]{1,8}章)',
        multiLine: true,
      ),
    ),

    // 17: 双标题(后向) —— 同上，依赖上一行也是标题。默认关。
    ChapterHeadingRule(
      serialNumber: 17,
      name: '双标题(后向)',
      enabledByDefault: false,
      pattern: safePattern(
        r'第[\d零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]{1,8}章.{0,30}$',
        multiLine: true,
      ),
    ),

    // 18: 标题 特殊符号 序号 —— "大风起兮(一)" / "标题名称（12）"
    ChapterHeadingRule(
      serialNumber: 18,
      name: '标题 特殊符号 序号',
      enabledByDefault: true,
      pattern: safePattern(
        r'^.{1,20}[(（][\d零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]{1,8}[)）][ 　\t]{0,4}$',
      ),
    ),
  ];
  __rulesCache = List.unmodifiable(list);
  return __rulesCache!;
}

List<ChapterHeadingRule>? __rulesCache;

/// 帮助函数：为"看起来像一堆链接，但规则几乎没命中"的目录页
/// 估算是否值得走 fallback。阈值经验值：
///   - 若 chapterList 匹配 < 3 条 → 规则大概率写错或站点改版
///   - 若匹配 > 0 但 (有效章节 / 匹配数) < 0.2 → 抓了一堆广告/导航
bool shouldTryHeadingFallback({
  required int chapterListHits,
  required int validChapters,
}) {
  if (chapterListHits == 0) return true;
  if (validChapters >= 3 && validChapters >= chapterListHits) return false;
  final ratio = chapterListHits == 0 ? 0.0 : validChapters / chapterListHits;
  return validChapters < math.max(3, chapterListHits ~/ 5) || ratio < 0.2;
}
