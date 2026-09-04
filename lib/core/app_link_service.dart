import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';

import '../book_source/services/book_source_service.dart';
import '../book_source/services/http_service.dart';
import '../book_source/utils/source_import_parser.dart';

/// 系统分享 → 应用的链接接收：处理 `legado://import?url=<源地址>`。
///
/// 冷启动取初始链接，热启动监听流；命中 `legado://import` 时拉取该书源内容
/// 并导入。导入结果通过全局 [navigatorKey] 以 SnackBar 提示。仅当 App 内
/// 已授权此链接（合法书源内容）才导入，其余链接忽略。均静默降级，不抛异常。
class AppLinkService {
  AppLinkService._();
  static final AppLinkService instance = AppLinkService._();

  /// 由根 [MaterialApp] 注入，用于全局提示。
  GlobalKey<NavigatorState>? navigatorKey;

  final AppLinks _links = AppLinks();
  StreamSubscription<Uri>? _sub;
  bool _started = false;

  /// 启动监听（App 启动时调用一次）。
  Future<void> init() async {
    if (_started) return;
    _started = true;
    try {
      final initial = await _links.getInitialLink();
      if (initial != null) _handle(initial);
      _sub = _links.uriLinkStream.listen(_handle);
    } catch (_) {
      _started = false;
    }
  }

  void dispose() {
    _sub?.cancel();
    _sub = null;
    _started = false;
  }

  void _handle(Uri uri) {
    if (uri.scheme != 'legado') return;
    final cmd = uri.host.isEmpty ? (uri.pathSegments.isNotEmpty ? uri.pathSegments.first : '') : uri.host;
    if (cmd != 'import') return;
    final url = uri.queryParameters['url']?.trim();
    if (url == null || url.isEmpty) return;
    unawaited(_import(url));
  }

  Future<void> _import(String url) async {
    try {
      final resp = await HttpService.instance.get(url);
      if (!resp.ok) {
        _toast('导入失败：请求失败（${resp.statusCode}）');
        return;
      }
      final sources = SourceImportParser.parse(resp.body);
      if (sources.isEmpty) {
        _toast('链接内容不含可导入的书源');
        return;
      }
      await BookSourceService.instance.init(); // 确保已加载
      final n = BookSourceService.instance.importAll(sources);
      await BookSourceService.instance.save();
      _toast('已导入/更新 $n 个书源');
    } catch (e) {
      _toast('导入失败：$e');
    }
  }

  void _toast(String msg) {
    final ctx = navigatorKey?.currentContext;
    if (ctx == null) return;
    ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text(msg)));
  }
}