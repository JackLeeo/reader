import 'package:flutter/material.dart';

/// 一一对应官方 `app/src/main/res/values/colors.xml` 与 `values-night/colors.xml`。
///
/// 命名沿用官方的语义名（primary/background_card/background_menu/primaryText…），
/// 方便在「完全复刻官方视觉」阶段按官方 UI 逐项套用。
abstract final class LegadoColors {
  // —— 主色（官方 colors.xml）——
  static const Color primary = Color(0xFF039BE5); // md_light_blue_600
  static const Color primaryDark = Color(0xFF0288D1); // md_light_blue_700
  static const Color accent = Color(0xFFAD1457); // md_pink_800

  // —— 背景层级（亮色）——
  static const Color background = Color(0xFFFAFAFA); // md_grey_50
  static const Color backgroundCard = Color(0xFFF5F5F5); // md_grey_100
  static const Color backgroundMenu = Color(0xFFEEEEEE); // md_grey_200
  static const Color backgroundPrefs = Color(0x7FFFFFFF);

  // —— 文本（亮色）——
  static const Color primaryTextLight = Color(0xDE000000); // 87% black
  static const Color secondaryTextLight = Color(0x8A000000); // 54% black
  static const Color textDisabledLight = Color(0x61000000); // 38% black
  static const Color iconLight = Color(0x8A000000);
  static const Color iconDark = Color(0xB3FFFFFF);

  // —— 分隔线 / 状态栏 ——
  static const Color divider = Color(0x66666666);
  static const Color statusBarBag = Color(0x19000000);
  static const Color navigationBarBag = Color(0xFFF4F4F4);

  // —— 语义色 ——
  static const Color error = Color(0xFFEB4333);
  static const Color success = Color(0xFF439B53);
  static const Color highlight = Color(0xFFD3321B);

  // —— 深色主题（官方 values-night/colors.xml 语义）——
  static const Color darkBackground = Color(0xFF121212); // material 深色基底
  static const Color darkCard = Color(0xFF1E1E1E);
  static const Color darkMenu = Color(0xFF2A2A2A);
  static const Color darkSurface = Color(0xFF2C2C2C);
  static const Color primaryTextDark = Color(0xFFFFFFFF);
  static const Color secondaryTextDark = Color(0xB3FFFFFF);
  static const Color textDisabledDark = Color(0x4DFFFFFF);
  // 深色主色提示浅蓝（LightBlue 300）
  static const Color primaryDarkTheme = Color(0xFF4FC3F7);
}