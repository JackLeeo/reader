import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/main_scaffold.dart';
import 'core/shelf_badge_store.dart';
import 'core/theme_mode_store.dart';
import 'core/app_link_service.dart';
import 'pages/onboarding/onboarding_page.dart';
import 'theme/legado_theme.dart';

/// Legado 跨平台版根组件。
///
/// 以官方 AppCompat.DayNight 的亮/暗主题壳为载体，挂载官方四页签主框架
/// （书库 / 发现 / 我的 / RSS）。主题模式支持跟随系统 / 浅色 / 深色切换。
class LegadoApp extends StatefulWidget {
  const LegadoApp({super.key});

  @override
  State<LegadoApp> createState() => _LegadoAppState();
}

class _LegadoAppState extends State<LegadoApp> {
  bool? _showOnboarding;
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    ThemeController.instance.load();
    ShelfBadgeController.instance.load();
    AppLinkService.instance.navigatorKey = _navigatorKey;
    _loadOnboarded();
  }

  Future<void> _loadOnboarded() async {
    final p = await SharedPreferences.getInstance();
    final shown = p.getBool(OnboardingPage.kOnboardedKey) ?? false;
    if (!mounted) return;
    setState(() => _showOnboarding = !shown);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        ThemeController.instance.mode,
        ThemeController.instance.accent,
      ]),
      builder: (_, _) {
        final ctrl = ThemeController.instance;
        final seed = ctrl.hasCustomAccent ? ctrl.themeSeed : null;
        return MaterialApp(
          title: 'Legado',
          debugShowCheckedModeBanner: false,
          navigatorKey: _navigatorKey,
          theme: LegadoTheme.light(seed: seed),
          darkTheme: LegadoTheme.dark(seed: seed),
          themeMode: ctrl.themeMode,
          routes: {'/home': (_) => const MainScaffold()},
          home: _showOnboarding == null
              ? const Scaffold(body: SizedBox.shrink())
              : (_showOnboarding! ? const OnboardingPage() : const MainScaffold()),
        );
      },
    );
  }
}