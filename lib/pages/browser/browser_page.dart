import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// 内置浏览器页（自带 WebView）。
///
/// 用于：打开外部链接 / RSS 文章阅读 / 复杂 JS 源登录页访问。
/// 头部带返回/前进/刷新/在当前页打开地址栏。
class BrowserPage extends StatefulWidget {
  const BrowserPage({super.key, required this.url, this.title = ''});

  final String url;
  final String title;

  @override
  State<BrowserPage> createState() => _BrowserPageState();
}

class _BrowserPageState extends State<BrowserPage> {
  late final WebViewController _controller;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) => setState(() => _loading = true),
          onPageFinished: (_) => setState(() => _loading = false),
        ),
      )
      ..loadRequest(Uri.parse(widget.url));
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        if (await _controller.canGoBack()) {
          await _controller.goBack();
        } else if (mounted && context.mounted) {
          Navigator.of(context).pop(result);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          actions: [
            if (_loading)
              const Padding(
                padding: EdgeInsets.only(right: 16),
                child: Center(
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () => _controller.reload(),
            ),
          ],
        ),
        body: WebViewWidget(controller: _controller),
      ),
    );
  }
}