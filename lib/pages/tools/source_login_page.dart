import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../book_source/models/book_source.dart';
import '../../book_source/services/login_service.dart';

/// 书源登录页（对应官方 `LoginActivity`）。
///
/// 用 WebView 加载 [BookSource.loginUrl]，用户在此完成账号登录；
/// 完成后点顶部「完成」，执行 [BookSource.loginCheckJs] 检测登录态，
/// 通过则抓取 `document.cookie` 写入 [CookieService] 持久化，并 pop(true)。
/// 之后书源请求会自动携带该 cookie（见 HttpService）。
class SourceLoginPage extends StatefulWidget {
  const SourceLoginPage({
    super.key,
    required this.source,
    this.initialUrl,
    this.captureOnStart = false,
  });

  final BookSource source;

  /// 默认跳转 [source.loginUrl]，可覆盖（如从详情页传入具体登录页）。
  final String? initialUrl;

  /// 是否进入即在当前页执行一次检测（来源已配置 loginUi 自动表单时）。
  final bool captureOnStart;

  @override
  State<SourceLoginPage> createState() => _SourceLoginPageState();
}

class _SourceLoginPageState extends State<SourceLoginPage> {
  late final WebViewController _controller;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    final url = (widget.initialUrl?.isNotEmpty ?? false)
        ? widget.initialUrl!
        : (widget.source.loginUrl ?? '');
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (_) {
          if (mounted) setState(() => _ready = true);
        },
      ))
      ..loadRequest(Uri.parse(url));
  }

  /// 抓取 document.cookie 并持久化；返回是否成功写入。
  Future<bool> _capture() async {
    final raw = await _controller
        .runJavaScriptReturningResult(LoginService.instance.captureCookieJs)
        .catchError((Object _) => '');
    var cookie = raw.toString();
    if (cookie == 'null') cookie = '';
    if (cookie.isEmpty) return false;
    // 还原 WebView 返回的字符串转义。
    cookie = cookie
        .replaceAll(r'\;', ';')
        .replaceAll(r'\&', '&')
        .replaceAll(r'\"', '"');
    if (cookie.trim().isEmpty) return false;
    await LoginService.instance.captureDocumentCookie(widget.source, cookie);
    return true;
  }

  Future<void> _finish(bool saveCookie) async {
    var cookieSaved = false;
    if (saveCookie) {
      cookieSaved = await _capture();
    }
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    if (cookieSaved) {
      messenger.showSnackBar(
        const SnackBar(content: Text('已登录，cookie 已保存')),
      );
    } else {
      messenger.showSnackBar(
        const SnackBar(content: Text('未捕获到 cookie，未保存登录信息')),
      );
    }
    Navigator.pop(context, cookieSaved);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final navigator = Navigator.of(this.context);
        final canGoBack = await _controller.canGoBack();
        if (canGoBack) {
          await _controller.goBack();
        } else {
          navigator.pop(_ready);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.source.bookSourceName,
              maxLines: 1, overflow: TextOverflow.ellipsis),
          actions: [
            if (!_ready)
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
              tooltip: '刷新',
              onPressed: () => _controller.reload(),
            ),
            IconButton(
              icon: const Icon(Icons.done_outline),
              tooltip: '完成（检测登录并保存）',
              onPressed: _ready ? () => _finish(true) : null,
            ),
            IconButton(
              icon: const Icon(Icons.logout),
              tooltip: '仅检测',
              onPressed: _ready ? () => _finish(false) : null,
            ),
          ],
        ),
        body: WebViewWidget(controller: _controller),
      ),
    );
  }
}