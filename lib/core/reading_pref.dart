import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 漫画色彩滤镜。
enum ComicFilter {
  none('无'),
  grayscale('灰度'),
  warmth('暖色'),
  cool('冷色'),
  sepia('老旧');

  const ComicFilter(this.label);
  final String label;
}

/// 简繁转换类型。
const int kConvNone = 0;
const int kConvToTraditional = 1;
const int kConvToSimplified = 2;

/// 阅读偏好（对齐官方 `ReadConfig`）。
///
/// 覆盖核心排版与扩展项：字号/行距/页边距/字距/段距/翻页/主题/背景图片/
/// 简繁/亮度/字体/字重/下划线/自动翻页/点击区域/首行缩进，以及朗读、听书、
/// 漫画(滤镜/双页/拼接滚动)等扩展配置。
class ReadingPref {
  ReadingPref._();

  static final ReadingPref instance = ReadingPref._();

  static const String _kFontSize = 'read.fontSize';
  static const String _kLineHeight = 'read.lineHeight';
  static const String _kPagePadding = 'read.pagePadding';
  static const String _kPageMode = 'read.pageMode';
  static const String _kThemeIndex = 'read.themeIndex';
  static const String _kLetterSpacing = 'read.letterSpacing';
  static const String _kParagraphSpacing = 'read.paragraphSpacing';
  static const String _kConvertType = 'read.convertType';
  static const String _kBrightness = 'read.brightness';
  static const String _kReverseOrder = 'read.reverseOrder';
  static const String _kImageFit = 'read.imageFit';
  static const String _kFontFamily = 'read.fontFamily';
  static const String _kTtsSpeechRate = 'read.ttsSpeechRate';
  static const String _kTtsVolume = 'read.ttsVolume';
  static const String _kFontWeight = 'read.fontWeight';
  static const String _kFontUnderline = 'read.fontUnderline';
  static const String _kAutoReadInterval = 'read.autoReadInterval';
  static const String _kTapZone = 'read.tapZone';
  static const String _kParagraphIndent = 'read.paragraphIndent';
  static const String _kComicBrightness = 'read.comicBrightness';
  static const String _kComicContrast = 'read.comicContrast';
  static const String _kComicSaturation = 'read.comicSaturation';
  static const String _kComicFilter = 'read.comicFilter';
  static const String _kComicDoublePage = 'read.comicDoublePage';
  static const String _kAudioSkipIntro = 'read.audioSkipIntro';
  static const String _kAudioSpeed = 'read.audioSpeed';
  static const String _kAloudTimeout = 'read.aloudTimeout';
  static const String _kAloudOnPageTurn = 'read.aloudOnPageTurn';
  static const String _kComicScroll = 'read.comicScroll';
  static const String _kComicOnlyLarge = 'read.comicOnlyLarge';
  static const String _kComicInvert = 'read.comicInvert';
  static const String _kComicLock = 'read.comicLock';

  /// 阅读字体（FontService 注册后的 family 名，空 = 系统默认）。
  String _fontFamily = '';

  static const List<int> kFontSizes = [14, 16, 18, 20, 22, 24, 28];

  /// 翻页模式：0 仿真翻页, 1 覆盖滚动, 2 滚动, 3 纵向翻页。
  static const List<String> kPageModeNames = ['仿真', '覆盖', '滚动', '纵向'];

  /// 阅读背景主题（name, foreground, background）。
  static const List<({String name, Color fg, Color bg})> kThemes = [
    (name: '白天', fg: Colors.black87, bg: Colors.white),
    (name: '羊皮纸', fg: Color(0xFF4E342E), bg: Color(0xFFF7F3E9)),
    (name: '护眼绿', fg: Color(0xFF2E3E2E), bg: Color(0xFFE8F0E8)),
    (name: '夜间', fg: Color(0xFFB0B0B0), bg: Color(0xFF1E1E1E)),
  ];

  int _fontSize = 18;
  int _indexOfFont = 3;
  double _lineHeight = 1.7;
  int _pagePadding = 20;
  int _pageMode = 0;
  int _themeIndex = 0;
  double _letterSpacing = 0.0;
  double _paragraphSpacing = 8.0;
  int _convertType = kConvNone;

  /// 应用内亮度（1.0 = 原样；<1 压暗，>1 提亮）。
  double _brightness = 1.0;

  /// 正文反转（倒序阅读整章）。
  bool _reverseOrder = false;

  /// 漫画/图片查看器里图片填充方式：0 铺满(cover), 1 适应宽度(fitWidth)。
  int _imageFit = 0;

  /// 朗读语速。系统 TTS 取值 0.1~1.0（越大越快）；HTTP TTS 通常忽略，保留统一。
  double _ttsSpeechRate = 0.5;

  /// 朗读音量 0~1（系统 TTS 生效）。
  double _ttsVolume = 1.0;

  /// 字重（0=normal, 1=medium, 2=bold；映射 FontWeight）。
  int _fontWeight = 0;

  /// 正文下划线。
  bool _fontUnderline = false;

  /// 自动翻页间隔（秒）。
  double _autoReadInterval = 3.0;

  /// 点击区域翻页（左/右翻章，中间唤菜单）。默认关，保持「点击切换菜单」。
  bool _tapZone = false;

  /// 首行缩进（滚动模式段首两个全角空格）。默认开。
  bool _paragraphIndent = true;

  /// 漫画亮度（0.3~1.8，1.0=原样）。
  double _comicBrightness = 1.0;

  /// 漫画对比度（0.5~2.0，1.0=原样）。
  double _comicContrast = 1.0;

  /// 漫画饱和度（0~2，1=原样，0=去色）。
  double _comicSaturation = 1.0;

  /// 漫画色彩滤镜。
  ComicFilter _comicFilter = ComicFilter.none;

  /// 漫画双页模式（平铺两页）。
  bool _comicDoublePage = false;

  /// 听书跳过片头秒数（0 = 不跳过）。
  double _audioSkipIntro = 0.0;

  /// 听书播放倍速（0.5 ~ 3.0）。
  double _audioSpeed = 1.0;

  /// 朗读定时停止（分钟，0 = 不限时）。
  int _aloudTimeout = 0;

  /// 朗读时手动翻页策略：0 停止朗读, 1 忽略(继续), 2 重读本章。
  int _aloudOnPageTurn = 0;

  /// 漫画拼接/连续滚动模式（一列纵向全部图片，可滚动浏览）。
  bool _comicScroll = false;
  bool _comicOnlyLarge = false;

  /// 漫画深色反色（夜间阅读漫画时反转明暗）。
  bool _comicInvert = false;

  /// 漫画视图锁定（禁用缩放/平移）。
  bool _comicLock = false;

  bool _loaded = false;

  int get fontSize => _fontSize;
  double get lineHeight => _lineHeight;
  int get pagePadding => _pagePadding;
  int get pageMode => _pageMode;
  int get themeIndex => _themeIndex;
  double get letterSpacing => _letterSpacing;
  double get paragraphSpacing => _paragraphSpacing;
  int get convertType => _convertType;
  double get brightness => _brightness;
  ({String name, Color fg, Color bg}) get theme => kThemes[_themeIndex];
  bool get reverseOrder => _reverseOrder;
  int get imageFit => _imageFit;
  String get fontFamily => _fontFamily;
  double get ttsSpeechRate => _ttsSpeechRate;
  double get ttsVolume => _ttsVolume;
  int get fontWeight => _fontWeight;
  bool get fontUnderline => _fontUnderline;
  double get autoReadInterval => _autoReadInterval;
  bool get tapZone => _tapZone;
  bool get paragraphIndent => _paragraphIndent;
  double get comicBrightness => _comicBrightness;
  double get comicContrast => _comicContrast;
  double get comicSaturation => _comicSaturation;
  ComicFilter get comicFilter => _comicFilter;
  bool get comicDoublePage => _comicDoublePage;
  double get audioSkipIntro => _audioSkipIntro;
  double get audioSpeed => _audioSpeed;
  int get aloudTimeout => _aloudTimeout;
  int get aloudOnPageTurn => _aloudOnPageTurn;
  bool get comicScroll => _comicScroll;
  bool get comicOnlyLarge => _comicOnlyLarge;
  bool get comicInvert => _comicInvert;
  bool get comicLock => _comicLock;

  FontWeight get fontWeightValue {
    switch (_fontWeight) {
      case 1:
        return FontWeight.w500;
      case 2:
        return FontWeight.bold;
      default:
        return FontWeight.normal;
    }
  }

  Future<void> load() async {
    if (_loaded) return;
    final p = await SharedPreferences.getInstance();
    _fontSize = p.getInt(_kFontSize) ?? 18;
    _lineHeight = p.getDouble(_kLineHeight) ?? 1.7;
    _pagePadding = p.getInt(_kPagePadding) ?? 20;
    _pageMode = p.getInt(_kPageMode) ?? 0;
    _themeIndex = p.getInt(_kThemeIndex) ?? 0;
    _letterSpacing = p.getDouble(_kLetterSpacing) ?? 0.0;
    _paragraphSpacing = p.getDouble(_kParagraphSpacing) ?? 8.0;
    _convertType = p.getInt(_kConvertType) ?? kConvNone;
    _brightness = p.getDouble(_kBrightness) ?? 1.0;
    _reverseOrder = p.getBool(_kReverseOrder) ?? false;
    _imageFit = p.getInt(_kImageFit) ?? 0;
    _fontFamily = p.getString(_kFontFamily) ?? '';
    _ttsSpeechRate = p.getDouble(_kTtsSpeechRate) ?? 0.5;
    _ttsVolume = p.getDouble(_kTtsVolume) ?? 1.0;
    _fontWeight = p.getInt(_kFontWeight) ?? 0;
    _fontUnderline = p.getBool(_kFontUnderline) ?? false;
    _autoReadInterval = p.getDouble(_kAutoReadInterval) ?? 3.0;
    _tapZone = p.getBool(_kTapZone) ?? false;
    _paragraphIndent = p.getBool(_kParagraphIndent) ?? true;
    _comicBrightness = p.getDouble(_kComicBrightness) ?? 1.0;
    _comicContrast = p.getDouble(_kComicContrast) ?? 1.0;
    _comicSaturation = p.getDouble(_kComicSaturation) ?? 1.0;
    _comicFilter = ComicFilter
        .values[(p.getInt(_kComicFilter) ?? 0).clamp(0, ComicFilter.values.length - 1)];
    _comicDoublePage = p.getBool(_kComicDoublePage) ?? false;
    _audioSkipIntro = p.getDouble(_kAudioSkipIntro) ?? 0.0;
    _audioSpeed = p.getDouble(_kAudioSpeed) ?? 1.0;
    _aloudTimeout = p.getInt(_kAloudTimeout) ?? 0;
    _aloudOnPageTurn = p.getInt(_kAloudOnPageTurn) ?? 0;
    _comicScroll = p.getBool(_kComicScroll) ?? false;
    _comicOnlyLarge = p.getBool(_kComicOnlyLarge) ?? false;
    _comicInvert = p.getBool(_kComicInvert) ?? false;
    _comicLock = p.getBool(_kComicLock) ?? false;
    _indexOfFont = kFontSizes.indexOf(_fontSize);
    if (_indexOfFont < 0) _indexOfFont = 3;
    _loaded = true;
  }

  Future<void> setFontSize(int v) async {
    _fontSize = v;
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kFontSize, v);
  }

  Future<void> setLineHeight(double v) async {
    _lineHeight = v;
    final p = await SharedPreferences.getInstance();
    await p.setDouble(_kLineHeight, v);
  }

  Future<void> setPagePadding(int v) async {
    _pagePadding = v;
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kPagePadding, v);
  }

  Future<void> setPageMode(int v) async {
    _pageMode = v;
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kPageMode, v);
  }

  Future<void> setThemeIndex(int v) async {
    _themeIndex = v;
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kThemeIndex, v);
  }

  Future<void> setLetterSpacing(double v) async {
    _letterSpacing = v;
    final p = await SharedPreferences.getInstance();
    await p.setDouble(_kLetterSpacing, v);
  }

  Future<void> setParagraphSpacing(double v) async {
    _paragraphSpacing = v;
    final p = await SharedPreferences.getInstance();
    await p.setDouble(_kParagraphSpacing, v);
  }

  Future<void> setConvertType(int v) async {
    _convertType = v;
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kConvertType, v);
  }

  Future<void> setBrightness(double v) async {
    _brightness = v.clamp(0.3, 1.8);
    final p = await SharedPreferences.getInstance();
    await p.setDouble(_kBrightness, _brightness);
  }

  Future<void> setReverseOrder(bool v) async {
    _reverseOrder = v;
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kReverseOrder, v);
  }

  Future<void> setImageFit(int v) async {
    _imageFit = v;
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kImageFit, v);
  }

  Future<void> setFontFamily(String v) async {
    _fontFamily = v;
    final p = await SharedPreferences.getInstance();
    await p.setString(_kFontFamily, v);
  }

  Future<void> setTtsSpeechRate(double v) async {
    _ttsSpeechRate = v.clamp(0.1, 1.0);
    final p = await SharedPreferences.getInstance();
    await p.setDouble(_kTtsSpeechRate, _ttsSpeechRate);
  }

  Future<void> setTtsVolume(double v) async {
    _ttsVolume = v.clamp(0.0, 1.0);
    final p = await SharedPreferences.getInstance();
    await p.setDouble(_kTtsVolume, _ttsVolume);
  }

  Future<void> setFontWeight(int v) async {
    _fontWeight = v.clamp(0, 2);
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kFontWeight, _fontWeight);
  }

  Future<void> setFontUnderline(bool v) async {
    _fontUnderline = v;
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kFontUnderline, v);
  }

  Future<void> setAutoReadInterval(double v) async {
    _autoReadInterval = v.clamp(0.5, 60);
    final p = await SharedPreferences.getInstance();
    await p.setDouble(_kAutoReadInterval, _autoReadInterval);
  }

  Future<void> setTapZone(bool v) async {
    _tapZone = v;
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kTapZone, v);
  }

  Future<void> setParagraphIndent(bool v) async {
    _paragraphIndent = v;
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kParagraphIndent, v);
  }

  Future<void> setComicBrightness(double v) async {
    _comicBrightness = v.clamp(0.3, 1.8);
    final p = await SharedPreferences.getInstance();
    await p.setDouble(_kComicBrightness, _comicBrightness);
  }

  Future<void> setComicContrast(double v) async {
    _comicContrast = v.clamp(0.5, 2.0);
    final p = await SharedPreferences.getInstance();
    await p.setDouble(_kComicContrast, _comicContrast);
  }

  Future<void> setComicSaturation(double v) async {
    _comicSaturation = v.clamp(0.0, 2.0);
    final p = await SharedPreferences.getInstance();
    await p.setDouble(_kComicSaturation, _comicSaturation);
  }

  Future<void> setComicFilter(ComicFilter v) async {
    _comicFilter = v;
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kComicFilter, v.index);
  }

  Future<void> setComicDoublePage(bool v) async {
    _comicDoublePage = v;
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kComicDoublePage, v);
  }

  Future<void> setAudioSkipIntro(double v) async {
    _audioSkipIntro = v.clamp(0.0, 60.0);
    final p = await SharedPreferences.getInstance();
    await p.setDouble(_kAudioSkipIntro, _audioSkipIntro);
  }

  Future<void> setAudioSpeed(double v) async {
    _audioSpeed = v.clamp(0.5, 3.0);
    final p = await SharedPreferences.getInstance();
    await p.setDouble(_kAudioSpeed, _audioSpeed);
  }

  Future<void> setAloudTimeout(int v) async {
    _aloudTimeout = v < 0 ? 0 : (v > 120 ? 120 : v);
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kAloudTimeout, _aloudTimeout);
  }

  Future<void> setAloudOnPageTurn(int v) async {
    _aloudOnPageTurn = v < 0 ? 0 : (v > 2 ? 2 : v);
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kAloudOnPageTurn, _aloudOnPageTurn);
  }

  Future<void> setComicScroll(bool v) async {
    _comicScroll = v;
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kComicScroll, v);
  }

  Future<void> setComicOnlyLarge(bool v) async {
    _comicOnlyLarge = v;
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kComicOnlyLarge, v);
  }

  Future<void> setComicInvert(bool v) async {
    _comicInvert = v;
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kComicInvert, v);
  }

  Future<void> setComicLock(bool v) async {
    _comicLock = v;
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kComicLock, v);
  }
}