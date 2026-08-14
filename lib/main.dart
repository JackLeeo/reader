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
  bookSourceService.init();
  final localBookService = LocalBookService();
  localBookService.init();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => SettingsService()..init()),
        ChangeNotifierProvider.value(value: bookSourceService),
        ChangeNotifierProvider(create: (_) => ShelfService()..init()),
        ChangeNotifierProvider(create: (_) => HistoryService()..init()),
        ChangeNotifierProvider(create: (_) => BookmarkService()..init()),
        ChangeNotifierProvider(create: (_) => StatsService()..init()),
        ChangeNotifierProvider.value(value: chapterCache),
        ChangeNotifierProvider.value(value: localBookService),
      ],
      child: const ReaderApp(),
    ),
  );
}
