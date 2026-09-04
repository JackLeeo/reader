import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/legado_colors.dart';

/// 全局主题模式控制器（跟随系统 / 浅色 / 深色）。
///
/// 持久化到本地；应用根组件 [ValueListenableBuilder] 监听以实时切换主题。
class ThemeController {
  ThemeController._();

  static final ThemeController instance = ThemeController._();

  static const String _prefsKey = 'app.themeMode';
  static const String _accentKey = 'app.themeAccent';

  /// 0=跟随系统, 1=浅色, 2=深色。
  static const List<String> kNames = ['跟随系统', '浅色', '深色'];

  final ValueNotifier<int> mode = ValueNotifier<int>(0);

  /// 自定义主色（ARGB 整数，0 = 未自定义，用默认主色）。
  final ValueNotifier<int> accent = ValueNotifier<int>(0);

  /// 是否有自定义主色。
  bool get hasCustomAccent => accent.value != 0;

  /// 当前生效主色：自定义优先，否则用默认。
  Color get themeSeed => hasCustomAccent
      ? Color(accent.value)
      : (mode.value == 2 ? LegadoColors.primaryDarkTheme : LegadoColors.primary);

  ThemeMode get themeMode {
    switch (mode.value) {
      case 1:
        return ThemeMode.light;
      case 2:
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    mode.value = p.getInt(_prefsKey) ?? 0;
    accent.value = p.getInt(_accentKey) ?? 0;
  }

  Future<void> setMode(int value) async {
    mode.value = value.clamp(0, 2);
    final p = await SharedPreferences.getInstance();
    await p.setInt(_prefsKey, mode.value);
  }

  Future<void> setAccent(Color color) async {
    accent.value = color.toARGB32();
    final p = await SharedPreferences.getInstance();
    await p.setInt(_accentKey, accent.value);
  }

  Future<void> resetAccent() async {
    accent.value = 0;
    final p = await SharedPreferences.getInstance();
    await p.setInt(_accentKey, 0);
  }
}