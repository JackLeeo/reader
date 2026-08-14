// 应用入口
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'app.dart';
import 'services/book_source_service.dart';
import 'services/bookmark_service.dart';
import 'services/chapter_cache_service.dart';
import 'services/history_service.dart';
import 'services/local_book_service.dart';
import 'services/settings_service.dart';
import 'services/shelf_service.dart';
import 'services/source_health_service.dart';
import 'services/stats_service.dart';
import 'utils/log.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // 沉浸式状态栏
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
    statusBarBrightness: Brightness.light,
  ));

  Log.i('应用启动');

  // 共享章节缓存实例
  final chapterCache = ChapterCacheService();
  final bookSourceService = BookSourceService();
  final sourceHealthService = SourceHealthService(bookSourceService);
  final settingsService = SettingsService();
  final localBookService = LocalBookService();

  // 先 runApp 让 UI 立即显示, 避免白屏
  // 然后在后台串行初始化所有 service, **严格按依赖顺序**:
  // settings -> book sources (读 1.98MB JSON, 慢) -> source health (依赖 book sources 列表)
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: settingsService),
        ChangeNotifierProvider.value(value: bookSourceService),
        ChangeNotifierProvider.value(value: sourceHealthService),
        ChangeNotifierProvider(create: (_) => ShelfService()),
        ChangeNotifierProvider(create: (_) => HistoryService()),
        ChangeNotifierProvider(create: (_) => BookmarkService()),
        ChangeNotifierProvider(create: (_) => StatsService()),
        ChangeNotifierProvider.value(value: chapterCache),
        ChangeNotifierProvider.value(value: localBookService),
      ],
      child: const ReaderApp(),
    ),
  );

  // 后台串行初始化 (顺序很重要: 必须 book sources 加载完才能跑 health check)
  () async {
    try {
      // 1. 设置 (快)
      await settingsService.init();
      Log.i('settingsService 初始化完成');

      // 2. 本地书 (快)
      await localBookService.init();

      // 3. 书源 (慢, 读 1.98MB JSON, 必须等)
      await bookSourceService.init();
      Log.i('bookSourceService 初始化完成: ${bookSourceService.sources.length} 个源');

      // 标记首次运行完成 (书源加载完才视为"首次运行结束")
      await settingsService.markFirstRunDone();

      // 4. 健康检查 (必须等书源加载完)
      await sourceHealthService.init();
      Log.i('sourceHealthService 初始化完成');

      // 5. 触发自动检测 (默认关闭, 三重保险防误禁)
      if (settingsService.autoHealthCheckEnabled) {
        await sourceHealthService.runOnStartupIfNeeded(
          autoHealthCheckEnabled: settingsService.autoHealthCheckEnabled,
          firstRunDone: settingsService.firstRunDone,
          autoDisableWhenFail: settingsService.invalidAutoDisable,
        );
      }
    } catch (e, st) {
      Log.e('初始化失败', error: e, stack: st);
    }
  }();
}
