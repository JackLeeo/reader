import 'package:flutter/material.dart';

import 'legado_colors.dart';

/// 对应官方 `styles.xml` 的 Base.AppTheme（AppCompat.DayNight）。
///
/// 亮/暗主题统一由官方主色 LightBlue 派生，同时把灰色系背景层级显式铺上，
/// 以贴近官方「浅灰背景 + 白色卡片」的观感（Material2 时代观感，非强 Material3）。
abstract final class LegadoTheme {
  static ThemeData light({Color? seed}) => _build(
        brightness: Brightness.light,
        seed: seed,
        primary: LegadoColors.primary,
        primaryDark: LegadoColors.primaryDark,
        accent: LegadoColors.accent,
        background: LegadoColors.background,
        surface: LegadoColors.backgroundCard,
        onSurfaceHigh: LegadoColors.primaryTextLight,
        onSurfaceMedium: LegadoColors.secondaryTextLight,
        scaffoldBackground: LegadoColors.background,
      );

  static ThemeData dark({Color? seed}) => _build(
        brightness: Brightness.dark,
        seed: seed,
        primary: LegadoColors.primaryDarkTheme,
        primaryDark: LegadoColors.primaryDarkTheme,
        accent: LegadoColors.accent,
        background: LegadoColors.darkBackground,
        surface: LegadoColors.darkCard,
        onSurfaceHigh: LegadoColors.primaryTextDark,
        onSurfaceMedium: LegadoColors.secondaryTextDark,
        scaffoldBackground: LegadoColors.darkBackground,
      );

  static ThemeData _build({
    required Brightness brightness,
    required Color? seed,
    required Color primary,
    required Color primaryDark,
    required Color accent,
    required Color background,
    required Color surface,
    required Color onSurfaceHigh,
    required Color onSurfaceMedium,
    required Color scaffoldBackground,
  }) {
    // 自定义主色：用 seed 覆盖默认主色与强调色。
    final Color p = seed ?? primary;
    final Color a = seed ?? accent;
    final scheme = ColorScheme.fromSeed(
      seedColor: p,
      brightness: brightness,
      primary: p,
      secondary: a,
      surface: background,
      onSurface: onSurfaceHigh,
    ).copyWith(
      surface: surface,
      onSurface: onSurfaceHigh,
      onSurfaceVariant: onSurfaceMedium,
      outline: LegadoColors.divider,
    );

    final theme = ThemeData(colorScheme: scheme, useMaterial3: false);

    final baseText = theme.textTheme;

    return theme.copyWith(
      scaffoldBackgroundColor: scaffoldBackground,
      appBarTheme: AppBarTheme(
        backgroundColor: scaffoldBackground,
        foregroundColor: onSurfaceHigh,
        elevation: 0,
        titleTextStyle: baseText.titleLarge?.copyWith(
          fontSize: 20,
          fontWeight: FontWeight.w500,
          color: onSurfaceHigh,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scaffoldBackground,
        indicatorColor: p.withValues(alpha: 0.12),
        surfaceTintColor: Colors.transparent,
      ),
      dividerColor: LegadoColors.divider,
      textTheme: baseText.apply(
        bodyColor: onSurfaceHigh,
        displayColor: onSurfaceHigh,
      ),
    );
  }
}