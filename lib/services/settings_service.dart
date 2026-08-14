// 应用设置
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsService extends ChangeNotifier {
  static const _themeKey = 'theme_mode';
  static const _fontSizeKey = 'reader_font_size';
  static const _lineHeightKey = 'reader_line_height';
  static const _bgColorKey = 'reader_bg_color';
  static const _textColorKey = 'reader_text_color';
  static const _pageTurnKey = 'reader_page_turn';
  static const _keepScreenOnKey = 'reader_keep_screen_on';
  static const _invalidAutoDisableKey = 'invalid_auto_disable';
  static const _sourceCheckOnStartupKey = 'source_check_on_startup';
  static const _firstRunDoneKey = 'first_run_done';

  ThemeMode _themeMode = ThemeMode.system;
  double _fontSize = 18.0;
  double _lineHeight = 1.6;
  String _bgColor = '#FFF8E1'; // 羊皮纸
  String _textColor = '#3E2723';
  String _pageTurn = 'slide'; // slide / curl / none
  bool _keepScreenOn = true;
  // 默认关闭: 自动禁用可能误杀正常源, 让用户主动开
  bool _invalidAutoDisable = false;
  // 默认关闭: 启动时自动检测书源 (用户主动开才跑, 避免误禁)
  bool _sourceCheckOnStartup = false;
  // 首次运行未完成 (用于 SourceHealthService 跳过检测)
  bool _firstRunDone = false;

  ThemeMode get themeMode => _themeMode;
  double get fontSize => _fontSize;
  double get lineHeight => _lineHeight;
  String get bgColor => _bgColor;
  String get textColor => _textColor;
  String get pageTurn => _pageTurn;
  bool get keepScreenOn => _keepScreenOn;
  bool get invalidAutoDisable => _invalidAutoDisable;
  bool get sourceCheckOnStartup => _sourceCheckOnStartup;
  bool get firstRunDone => _firstRunDone;

  /// 启动自动检测开关: 真正决定 SourceHealthService.runOnStartupIfNeeded 是否跑
  /// 替代原 _sourceCheckOnStartup 的语义, 名字更清晰
  bool get autoHealthCheckEnabled => _sourceCheckOnStartup;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final theme = prefs.getString(_themeKey);
    if (theme == 'light') {
      _themeMode = ThemeMode.light;
    } else if (theme == 'dark') {
      _themeMode = ThemeMode.dark;
    }
    _fontSize = prefs.getDouble(_fontSizeKey) ?? 18.0;
    _lineHeight = prefs.getDouble(_lineHeightKey) ?? 1.6;
    _bgColor = prefs.getString(_bgColorKey) ?? '#FFF8E1';
    _textColor = prefs.getString(_textColorKey) ?? '#3E2723';
    _pageTurn = prefs.getString(_pageTurnKey) ?? 'slide';
    _keepScreenOn = prefs.getBool(_keepScreenOnKey) ?? true;
    // 关键: 默认值从 true 改为 false, 避免老用户被持久化的 true 误禁
    _invalidAutoDisable = prefs.getBool(_invalidAutoDisableKey) ?? false;
    // 启动自动检测默认关闭: 用户主动开才会触发
    _sourceCheckOnStartup = prefs.getBool(_sourceCheckOnStartupKey) ?? false;
    _firstRunDone = prefs.getBool(_firstRunDoneKey) ?? false;
    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    _themeMode = mode;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_themeKey, mode == ThemeMode.dark
        ? 'dark'
        : mode == ThemeMode.light
            ? 'light'
            : 'system');
  }

  Future<void> setFontSize(double size) async {
    _fontSize = size;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_fontSizeKey, size);
  }

  Future<void> setLineHeight(double h) async {
    _lineHeight = h;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_lineHeightKey, h);
  }

  Future<void> setBgColor(String hex) async {
    _bgColor = hex;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_bgColorKey, hex);
  }

  Future<void> setTextColor(String hex) async {
    _textColor = hex;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_textColorKey, hex);
  }

  Future<void> setPageTurn(String mode) async {
    _pageTurn = mode;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_pageTurnKey, mode);
  }

  Future<void> setKeepScreenOn(bool v) async {
    _keepScreenOn = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keepScreenOnKey, v);
  }

  Future<void> setInvalidAutoDisable(bool v) async {
    _invalidAutoDisable = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_invalidAutoDisableKey, v);
  }

  Future<void> setSourceCheckOnStartup(bool v) async {
    _sourceCheckOnStartup = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_sourceCheckOnStartupKey, v);
  }

  /// 标记首次运行完成 (由 BookSourceService 加载完成时调用)
  Future<void> markFirstRunDone() async {
    if (_firstRunDone) return;
    _firstRunDone = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_firstRunDoneKey, true);
  }
}
