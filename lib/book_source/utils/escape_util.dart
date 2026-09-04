/// 简单 HTML 实体反转义（对标官方 Apache `StringEscapeUtils.unescapeHtml4` 子集）。
///
/// 覆盖小说站点标题/简介/正文里 99% 的命名与数字实体。
class EscapeUtil {
  EscapeUtil._();

  static const Map<String, String> _named = {
    '&amp;': '&',
    '&lt;': '<',
    '&gt;': '>',
    '&quot;': '"',
    '&apos;': "'",
    '&nbsp;': '\u00A0',
    '&nbsp': '\u00A0',
    '&ensp;': '\u2002',
    '&emsp;': '\u2003',
    '&mdash;': '\u2014',
    '&ndash;': '\u2013',
    '&hellip;': '\u2026',
    '&ldquo;': '\u201C',
    '&rdquo;': '\u201D',
    '&lsquo;': '\u2018',
    '&rsquo;': '\u2019',
    '&middot;': '\u00B7',
    '&bull;': '\u2022',
    '&copy;': '©',
    '&reg;': '®',
    '&trade;': '\u2122',
    '&deg;': '°',
    '&times;': '×',
    '&divide;': '÷',
    '&plusmn;': '±',
    '&frac12;': '½',
    '&laquo;': '«',
    '&raquo;': '»',
    '&shy;': '\u00AD',
    '&uuml;': 'ü',
    '&auml;': 'ä',
    '&ouml;': 'ö',
    '&eacute;': 'é',
    '&egrave;': 'è',
    '&ccedil;': 'ç',
    '&ntilde;': 'ñ',
  };

  static final RegExp _num = RegExp(r'&#(\d+);');
  static final RegExp _hex = RegExp(r'&#x([0-9A-Fa-f]+);');

  /// 仅当含 `&` 时执行，避免普通文本白白分配。
  static String unescape(String input) {
    if (!input.contains('&')) return input;
    var out = input;
    for (final e in _named.entries) {
      if (out.contains(e.key)) out = out.replaceAll(e.key, e.value);
    }
    out = out.replaceAllMapped(_num, (m) {
      final code = int.tryParse(m.group(1)!);
      return code != null && code > 0 ? String.fromCharCode(code) : m.group(0)!;
    });
    out = out.replaceAllMapped(_hex, (m) {
      final code = int.tryParse(m.group(1)!, radix: 16);
      return code != null && code > 0 ? String.fromCharCode(code) : m.group(0)!;
    });
    return out;
  }
}