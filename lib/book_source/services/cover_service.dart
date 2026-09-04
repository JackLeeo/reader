import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 封面覆盖服务（对齐官方「更换封面」）。
///
/// 按书去重键存储手动设置的封面，值为：
/// - `http(s)://...` 网络图片
/// - `file:///...` 本地图片
/// 覆盖优先于书源自带的 [coverUrl]，由 [CoverImage] 统一解析。
class CoverService {
  CoverService._();

  static final CoverService instance = CoverService._();

  static const String _prefsKey = 'book_cover_overrides_v1';

  /// bookKey -> 封面 uri 字符串。
  final Map<String, String> _overrides = {};
  bool initialized = false;

  Future<void> init() async {
    if (initialized) return;
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_prefsKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final map = (jsonDecode(raw) as Map)
            .map((k, v) => MapEntry(k.toString(), v.toString()));
        _overrides
          ..clear()
          ..addAll(map);
      } catch (_) {
        _overrides.clear();
      }
    }
    initialized = true;
  }

  /// 取覆盖封面；无则返回 [fallback]（书源自带 coverUrl）。
  Future<String?> coverFor(String bookKey, {String? fallback}) async {
    await init();
    return _overrides[bookKey] ?? fallback;
  }

  /// 设置（本地/网络）封面覆盖，null 表示清除。
  Future<void> setCover(String bookKey, String? uri) async {
    await init();
    if (uri == null || uri.trim().isEmpty) {
      _overrides.remove(bookKey);
    } else {
      _overrides[bookKey] = uri.trim();
    }
    final p = await SharedPreferences.getInstance();
    await p.setString(_prefsKey, jsonEncode(_overrides));
  }

  void clear() {
    _overrides.clear();
    initialized = false;
  }
}