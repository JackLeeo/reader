import 'package:flutter/material.dart';

/// 高亮语言模式。
enum CodeMode {
  js('JavaScript', CodeStyle.js),
  json('JSON', CodeStyle.json),
  xml('XML / RSS', CodeStyle.xml),
  none('纯文本', CodeStyle.none);

  const CodeMode(this.label, this.style);
  final String label;
  final CodeHighlighter style;
}

/// 语法高亮器接口：给定文本产出 [TextSpan] 列表。
abstract interface class CodeHighlighter {
  List<TextSpan> highlight(String text);
}

/// 语法高亮配色与各语言高亮器。
abstract final class CodeStyle {
  // 默认前景
  static const def = Color(0xFF263238);

  // js
  static const jsKeyword = Color(0xFF7C3AED);
  static const jsString = Color(0xFF818CF8);
  static const jsNumber = Color(0xFFF59E0B);
  static const jsComment = Color(0xFF9E9E9E);

  // json
  static const jsonKey = Color(0xFF2563EB);
  static const jsonString = Color(0xFF16A34A);
  static const jsonNumber = Color(0xFFF59E0B);
  static const jsonBool = Color(0xFFDC2626);
  static const jsonPunct = Color(0xFF78909C);

  // xml
  static const xmlTag = Color(0xFFB91C1C);
  static const xmlAttr = Color(0xFF047857);
  static const xmlValue = Color(0xFF9333EA);
  static const xmlComment = Color(0xFF9E9E9E);

  static const CodeHighlighter js = _JsStyle();
  static const CodeHighlighter json = _JsonStyle();
  static const CodeHighlighter xml = _XmlStyle();
  static const CodeHighlighter none = _NoneStyle();
}

final class _JsStyle implements CodeHighlighter {
  const _JsStyle();
  static const _keywords = {
    'var', 'let', 'const', 'function', 'return', 'if', 'else', 'for',
    'while', 'do', 'switch', 'case', 'default', 'break', 'continue', 'new',
    'delete', 'typeof', 'instanceof', 'in', 'of', 'async', 'await', 'yield',
    'class', 'extends', 'super', 'this', 'try', 'catch', 'finally', 'throw',
    'import', 'export', 'from', 'static', 'void', 'null', 'true', 'false',
  };

  @override
  List<TextSpan> highlight(String text) {
    final out = <TextSpan>[];
    var i = 0;
    final n = text.length;
    final numRe = RegExp(r'\d+(\.\d+)?');
    final idRe = RegExp(r'[A-Za-z_$][A-Za-z0-9_$]*');
    while (i < n) {
      final c = text[i];
      // 行注释 //...
      if (c == '/' && i + 1 < n && text[i + 1] == '/') {
        final end = text.indexOf('\n', i);
        final stop = end < 0 ? n : end;
        out.add(TextSpan(
            text: text.substring(i, stop),
            style: const TextStyle(color: CodeStyle.jsComment)));
        i = stop;
        continue;
      }
      // 块注释 /*...*/
      if (c == '/' && i + 1 < n && text[i + 1] == '*') {
        final end = text.indexOf('*/', i + 2);
        final stop = end < 0 ? n : end + 2;
        out.add(TextSpan(
            text: text.substring(i, stop),
            style: const TextStyle(color: CodeStyle.jsComment)));
        i = stop;
        continue;
      }
      // 字符串 '...' 或 "..."
      if (c == '\'' || c == '"') {
        var j = i + 1;
        while (j < n) {
          if (text[j] == '\\') {
            j += 2;
            continue;
          }
          if (text[j] == c) {
            j++;
            break;
          }
          j++;
        }
        out.add(TextSpan(
            text: text.substring(i, j),
            style: const TextStyle(color: CodeStyle.jsString)));
        i = j;
        continue;
      }
      // 数字
      if (c == '-' && i + 1 < n && RegExp(r'\d').hasMatch(text[i + 1])) {
        i++;
      }
      if (RegExp(r'\d').hasMatch(c)) {
        final m = numRe.firstMatch(text.substring(i))!;
        out.add(TextSpan(
            text: m.group(0)!,
            style: const TextStyle(color: CodeStyle.jsNumber)));
        i += m.group(0)!.length;
        continue;
      }
      // 标识符 / 关键字
      if (RegExp(r'[A-Za-z_$]').hasMatch(c)) {
        final m = idRe.firstMatch(text.substring(i))!;
        final w = m.group(0)!;
        out.add(TextSpan(
            text: w,
            style: _keywords.contains(w)
                ? const TextStyle(color: CodeStyle.jsKeyword)
                : null));
        i += w.length;
        continue;
      }
      // 其它字符
      out.add(TextSpan(text: c));
      i++;
    }
    return out;
  }
}

final class _JsonStyle implements CodeHighlighter {
  const _JsonStyle();

  @override
  List<TextSpan> highlight(String text) {
    final out = <TextSpan>[];
    final re = RegExp(
        r"""("(?:[^\\"]|\\.)*")(\s*)(:)|("(?:[^\\"]|\\.)*")|(\b(?:true|false|null)\b)|(\b-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b)|([{}\[\],])""");
    var last = 0;
    for (final m in re.allMatches(text)) {
      if (m.start > last) out.add(TextSpan(text: text.substring(last, m.start)));
      if (m.group(3) != null) {
        out.add(TextSpan(text: m.group(1), style: const TextStyle(color: CodeStyle.jsonKey)));
        if (m.group(2)!.isNotEmpty) out.add(TextSpan(text: m.group(2)));
        out.add(const TextSpan(text: ':', style: TextStyle(color: CodeStyle.jsonPunct)));
      } else {
        Color? c = m.group(4) != null
            ? CodeStyle.jsonString
            : m.group(5) != null
                ? CodeStyle.jsonBool
                : m.group(6) != null
                    ? CodeStyle.jsonNumber
                    : m.group(7) != null
                        ? CodeStyle.jsonPunct
                        : null;
        out.add(TextSpan(text: m.group(0), style: c == null ? null : TextStyle(color: c)));
      }
      last = m.end;
    }
    if (last < text.length) out.add(TextSpan(text: text.substring(last)));
    return out;
  }
}

final class _XmlStyle implements CodeHighlighter {
  const _XmlStyle();

  @override
  List<TextSpan> highlight(String text) {
    final out = <TextSpan>[];
    final re = RegExp(
        r"""(<!--[\s\S]*?-->)|(</?)([A-Za-z_:][\w:.-]*)|([A-Za-z_:][\w:.-]*)(=)("(?:[^"]*)")""");
    var last = 0;
    for (final m in re.allMatches(text)) {
      if (m.start > last) out.add(TextSpan(text: text.substring(last, m.start)));
      if (m.group(1) != null) {
        out.add(TextSpan(text: m.group(1), style: const TextStyle(color: CodeStyle.xmlComment)));
      } else if (m.group(2) != null) {
        out.add(TextSpan(text: m.group(2), style: const TextStyle(color: CodeStyle.xmlTag)));
        out.add(TextSpan(text: m.group(3), style: const TextStyle(color: CodeStyle.xmlTag)));
      } else if (m.group(4) != null) {
        out.add(TextSpan(text: m.group(4), style: const TextStyle(color: CodeStyle.xmlAttr)));
        out.add(TextSpan(text: m.group(5), style: const TextStyle(color: CodeStyle.jsonPunct)));
        out.add(TextSpan(text: m.group(6), style: const TextStyle(color: CodeStyle.xmlValue)));
      }
      last = m.end;
    }
    if (last < text.length) out.add(TextSpan(text: text.substring(last)));
    return out;
  }
}

final class _NoneStyle implements CodeHighlighter {
  const _NoneStyle();
  @override
  List<TextSpan> highlight(String text) => [TextSpan(text: text)];
}

/// 轻量语法高亮代码编辑器（对齐官方 CodeEditActivity）。
///
/// 编辑层使用透明前景的 [TextField]，高亮层为等宽 [Text.rich]。
/// 两层完全相同字体/内边距，顶部对齐置于 [Stack]，外层 [SingleChildScrollView]
/// 统一滚动，保证逐字符对齐。支持 JS / JSON / XML(RSS) 三种高亮。
class CodeEditor extends StatefulWidget {
  const CodeEditor({
    super.key,
    required this.controller,
    this.mode = CodeMode.js,
    this.minLines = 8,
    this.maxLines = 200,
    this.fontSize = 14,
    this.hintText,
    this.enabled = true,
  });

  final TextEditingController controller;
  final CodeMode mode;
  final int minLines;
  final int maxLines;
  final double fontSize;
  final String? hintText;
  final bool enabled;

  @override
  State<CodeEditor> createState() => _CodeEditorState();
}

class _CodeEditorState extends State<CodeEditor> {
  final FocusNode _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    TextStyle mono([Color? color]) => TextStyle(
          fontFamily: 'monospace',
          fontSize: widget.fontSize,
          height: 1.4,
          color: color,
        );
    final padding = const EdgeInsets.all(10);
    final spans = widget.mode.style.highlight(widget.controller.text);

    final highlight = Container(
      padding: padding,
      alignment: Alignment.topLeft,
      color: Colors.transparent,
      child: Text.rich(
        TextSpan(style: mono(), children: spans),
        textAlign: TextAlign.left,
      ),
    );

    final editLayer = TextField(
      controller: widget.controller,
      focusNode: _focus,
      enabled: widget.enabled,
      minLines: widget.minLines,
      maxLines: widget.maxLines,
      keyboardType: TextInputType.multiline,
      textAlignVertical: TextAlignVertical.top,
      scrollPhysics: const NeverScrollableScrollPhysics(),
      style: mono(Colors.transparent),
      cursorColor: Theme.of(context).colorScheme.primary,
      decoration: InputDecoration(
        hintText: widget.hintText,
        hintStyle: mono(Colors.grey),
        border: InputBorder.none,
        contentPadding: padding,
        isCollapsed: true,
      ),
      onChanged: (_) => setState(() {}),
    );

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade400),
        borderRadius: BorderRadius.circular(6),
      ),
      clipBehavior: Clip.antiAlias,
      child: SingleChildScrollView(
        controller: null,
        child: Stack(
          alignment: Alignment.topLeft,
          children: [highlight, editLayer],
        ),
      ),
    );
  }
}