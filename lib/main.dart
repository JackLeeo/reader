// 应用入口
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'app.dart';
import 'services/book_source_service.dart';
import 'services/shelf_service.dart';
import 'services/history_service.dart';
import 'services/settings_service.dart';
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

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => SettingsService()..init()),
        ChangeNotifierProvider(create: (_) => BookSourceService()..init()),
        ChangeNotifierProvider(create: (_) => ShelfService()..init()),
        ChangeNotifierProvider(create: (_) => HistoryService()..init()),
      ],
      child: const ReaderApp(),
    ),
  );
}
