import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 书架角标设置：每个封面右上角显示阅读进度角标 + 底部进度条。
///
/// 独立于阅读偏好，属于应用级 UI 设置。
class ShelfBadgeController {
  ShelfBadgeController._();

  static final ShelfBadgeController instance = ShelfBadgeController._();

  static const String _prefsKey = 'app.shelfBadge';

  /// 0=关闭, 1=显示进度百分比角标, 2=角标+封面底部进度条。
  final ValueNotifier<int> mode = ValueNotifier<int>(0);

  static const List<String> kNames = ['关闭', '进度角标', '角标+进度条'];

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    mode.value = p.getInt(_prefsKey) ?? 0;
  }

  Future<void> setMode(int value) async {
    final v = value < 0 ? 0 : (value > 2 ? 2 : value);
    mode.value = v;
    final p = await SharedPreferences.getInstance();
    await p.setInt(_prefsKey, v);
  }
}