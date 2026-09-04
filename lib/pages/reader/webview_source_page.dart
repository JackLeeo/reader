import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../book_source/services/web_js_service.dart';

/// WebView 型书源阅读页（官方“网页书源”）。
///
/// 用于正文需 JS 渲染、静态请求解析不到内容的书源：在真实浏览器内核内打开
/// 章节 URL，点「提取正文」运行注入脚本（优先用书源 content 规则的选择器，
/// 否则取整页文本），提取结果供复制/保存。
class WebViewSourcePage extends StatefulWidget {
  const WebViewSourcePage({
    super.key,
    required this.url,
    required this.title,
    this.contentSelector,
    this.jsCode,
  });

  final String url;
  final String title;

  /// 书源 content 规则（CSS 选择器）；为空时回退整页文本。
  final String? contentSelector;

  /// `js:` 书源的源码；非空时优先调用其 `content(url)` 函数（书源级 WebView 往返）。
  final String? jsCode;

  @override
  State<WebViewSourcePage> createState() => _WebViewSourcePageState();
}

class _WebViewSourcePageState extends State<WebViewSourcePage> {
  late final WebViewController _controller;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (_) => setState(() => _loading = true),
        onPageFinished: (_) => setState(() => _loading = false),
      ))
      ..loadRequest(Uri.parse(widget.url));
  }

  /// 注入脚本提取正文；选择器优先，否则整页 innerText。
  String get _extractJs {
    final sel = (widget.contentSelector ?? '').trim();
    if (sel.isNotEmpty) {
      return r'''
(function(){
  try {
    var el = document.querySelector('__SEL__');
    if (el) { var t = el.innerText || el.textContent || ''; return t.trim(); }
  } catch(e){}
  var b = document.body;
  return b ? (b.innerText || b.textContent || '').trim() : '';
})();
'''
          .replaceAll('__SEL__', sel);
    }
    return r'''
(function(){
  try {
    var b = document.body;
    return b ? (b.innerText || b.textContent || '').trim() : '';
  } catch(e){ return ''; }
})();
''';
  }

  Future<(bool, Object?)?> _runSourceFn(String fn, List<Object?> args) async {
    final code = (widget.jsCode ?? '').trim();
    if (code.isEmpty) return null;
    try {
      final script = WebJsService.instance.buildRunScript(code, fn, args);
      final raw = await _controller.runJavaScriptReturningResult(script);
      final r = WebJsService.parseResultRaw(raw);
      if (r.ok) return (true, r.data);
      return (false, r.data ?? r.msg);
    } catch (_) {
      return (false, null);
    }
  }

  Future<void> _extractText() async {
    var cleaned = '';
    var sourceNote = '内置选择器';
    // 书源级 WebView 往返：优先调用 `js:` 书源的 content 函数。
    final jsResult = await _runSourceFn('content', [widget.url]);
    if (jsResult != null && jsResult.$1 && jsResult.$2 != null) {
      final v = jsResult.$2;
      final s = v is String ? v : jsonEncode(v);
      if (s.trim().isNotEmpty) {
        cleaned = s;
        sourceNote = '书源 content 函数';
      }
    }
    if (cleaned.isEmpty) {
      final text = await _controller.runJavaScriptReturningResult(_extractJs);
      cleaned = _unquote(text.toString());
    }
    final display = cleaned.trim().isEmpty ? '（未能提取到正文）' : cleaned;
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('提取正文（$sourceNote）· $cleaned 字'),
        content: SizedBox(
          width: double.maxFinite,
          height: 300,
          child: SingleChildScrollView(child: SelectableText(display)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
          if (cleaned.trim().isNotEmpty)
            TextButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: cleaned));
                if (ctx.mounted) Navigator.pop(ctx);
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('已复制正文到剪贴板')),
                  );
                }
              },
              child: const Text('复制正文'),
            ),
        ],
      ),
    );
  }

  static String _unquote(String s) {
    if (s.length >= 2 && s.startsWith('"') && s.endsWith('"')) {
      // JSON 字符串，转义解码
      try {
        final v = RegExp(r'^"(.*)"$', dotAll: true).firstMatch(s)!;
        return const JsonUnescape().apply(v.group(1)!);
      } catch (_) {
        return s.substring(1, s.length - 1);
      }
    }
    return s;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          if (_loading)
            const Padding(
              padding: EdgeInsets.only(right: 12),
              child: Center(
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.text_snippet_outlined),
            tooltip: '提取正文',
            onPressed: _extractText,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => _controller.reload(),
          ),
        ],
      ),
      body: WebViewWidget(controller: _controller),
    );
  }
}

/// 极简 JSON 字符串转义解码（\n、\uXXXX、\"、\\ 等）。
class JsonUnescape {
  const JsonUnescape();
  String apply(String s) {
    final out = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      final c = s[i];
      if (c != r'\') {
        out.write(c);
        continue;
      }
      if (i + 1 >= s.length) {
        out.write(r'\');
        break;
      }
      final n = s[i + 1];
      i++;
      switch (n) {
        case 'n': out.write('\n');
        case 't': out.write('\t');
        case 'r': out.write('\r');
        case 'b': out.write('\b');
        case 'f': out.write('\f');
        case '"': out.write('"');
        case r'\': out.write(r'\');
        case '/': out.write('/');
        case 'u':
          if (i + 4 < s.length) {
            final hex = s.substring(i + 1, i + 5);
            final code = int.tryParse(hex, radix: 16);
            if (code != null) {
              out.writeCharCode(code);
              i += 4;
            } else {
              out.write(r'\u$hex');
            }
          } else {
            out.write(s.substring(i));
          }
        default: out.write(n);
      }
    }
    return out.toString();
  }
}