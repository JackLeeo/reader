import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// TTS 引擎（朗读用）。
class TtsEngine {
  TtsEngine({
    required this.name,
    required this.url,
    this.param = '',
    this.enabled = false,
  });

  final String name;
  final String url;
  final String param;
  final bool enabled;

  /// 用朗读文本替换 URL 占位（官方 HttpTTS 的 `{{speakText}}` / `{speakText}`），
  /// 且按 `${param}` 把附加参数并入 query。
  String buildUrl(String text) {
    final encoded = Uri.encodeComponent(text);
    var r = url
        .replaceAll('{{speakText}}', encoded)
        .replaceAll('{speakText}', encoded)
        .replaceAll('{key}', encoded);
    if (param.trim().isNotEmpty) {
      // param 形如 `a=1&b=2`：并入 query，已存在的占位不为空则不重复覆盖。
      final uri = Uri.tryParse(r);
      if (uri != null && uri.hasScheme) {
        final q = <String, String>{...uri.queryParameters};
        for (final seg in param.split('&')) {
          final eq = seg.indexOf('=');
          final k = eq > 0 ? seg.substring(0, eq).trim() : '';
          if (k.isEmpty) continue;
          final v = eq > 0 ? seg.substring(eq + 1).trim() : '';
          if (!q.containsKey(k)) q[k] = v;
        }
        r = uri.replace(queryParameters: q).toString();
      }
    }
    return r;
  }

  factory TtsEngine.fromJson(Map<String, dynamic> m) => TtsEngine(
        name: (m['name'] ?? '') as String,
        url: (m['url'] ?? '') as String,
        param: (m['param'] ?? '') as String,
        enabled: (m['enabled'] ?? false) as bool,
      );

  Map<String, dynamic> toJson() =>
      {'name': name, 'url': url, 'param': param, 'enabled': enabled};
}

/// TTS 引擎管理（对应官方 TTS 设置，基础版：维护引擎列表）。
///
/// 朗读实际调用引擎接口（HTTP GET 文本→音频）留待桌面/真机音频播放验证，
/// 这里先提供引擎的增删改与持久化。
class TtsEngineService {
  TtsEngineService._();

  static final TtsEngineService instance = TtsEngineService._();

  static const String _prefsKey = 'tts_engines_v1';

  final List<TtsEngine> _engines = [];
  bool initialized = false;

  List<TtsEngine> get engines => List.unmodifiable(_engines);

  TtsEngine? get enabledEngine {
    for (final e in _engines) {
      if (e.enabled) return e;
    }
    return null;
  }

  Future<void> init() async {
    if (initialized) return;
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_prefsKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        _engines
          ..clear()
          ..addAll((jsonDecode(raw) as List)
              .map((e) => TtsEngine.fromJson(e as Map<String, dynamic>)));
      } catch (_) {
        _engines.clear();
      }
    }
    initialized = true;
  }

  void upsert(TtsEngine engine) {
    final idx = _engines.indexWhere((e) => e.name == engine.name);
    if (idx >= 0) {
      _engines[idx] = engine;
    } else {
      _engines.add(engine);
    }
    save();
  }

  void remove(String name) {
    _engines.removeWhere((e) => e.name == name);
    save();
  }

  void setEnabled(String name, bool enabled) {
    for (var i = 0; i < _engines.length; i++) {
      final on = _engines[i].name == name && enabled;
      _engines[i] = TtsEngine(
        name: _engines[i].name,
        url: _engines[i].url,
        param: _engines[i].param,
        enabled: on,
      );
    }
    save();
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_prefsKey, jsonEncode(_engines.map((e) => e.toJson()).toList()));
  }

  void clear() {
    _engines.clear();
  }
}