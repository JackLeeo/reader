// 根应用
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'pages/home/home_page.dart';
import 'services/settings_service.dart';
import 'utils/log.dart';

class ReaderApp extends StatelessWidget {
  const ReaderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<SettingsService>(
      builder: (context, settings, _) {
        Log.d('重建主题 themeMode=${settings.themeMode}');
        return MaterialApp(
          title: '换源阅读',
          debugShowCheckedModeBanner: false,
          themeMode: settings.themeMode,
          theme: ThemeData(
            useMaterial3: true,
            brightness: Brightness.light,
            colorSchemeSeed: const Color(0xFF1976D2),
            fontFamily: 'PingFang SC',
          ),
          darkTheme: ThemeData(
            useMaterial3: true,
            brightness: Brightness.dark,
            colorSchemeSeed: const Color(0xFF1976D2),
            fontFamily: 'PingFang SC',
          ),
          home: const HomePage(),
        );
      },
    );
  }
}
