import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../services/tts_service.dart';

/// 朗读扬声器抽象（对应官方多种 TTS 阅读引擎：系统 TTS / HTTP 网络 TTS）。
///
/// 阅读器只依赖该接口，具体由配置决定使用哪个引擎：
/// - [SystemTtsSpeaker]：走系统 TTS（FlutterTts）
/// - [HttpTtsSpeaker]：把文本替换进 HTTP TTS 引擎 URL，拉取音频后播放（audioplayers）
abstract class TtsSpeaker {
  const TtsSpeaker();

  String get name;

  /// 朗读 [text]。
  Future<void> speak(String text);

  /// 停止朗读。
  Future<void> stop();

  /// 调整朗读参数（语速/音量）。由朗读配置对话框调用，实时生效。
  Future<void> setParams({double? speechRate, double? volume});

  /// 一次朗读结束事件（用于支持的引擎触发连续朗读到下一章）。
  Stream<void> get onComplete;

  /// 释放资源。
  Future<void> dispose();
}

/// 系统 TTS（FlutterTts）扬声器。
class SystemTtsSpeaker extends TtsSpeaker {
  SystemTtsSpeaker();

  FlutterTts? _tts;
  final _completeCtrl = StreamController<void>.broadcast();

  @override
  Stream<void> get onComplete => _completeCtrl.stream;

  @override
  String get name => '系统TTS';

  /// 初始化系统 TTS；不支持时返回 null（上层回退）。
  static Future<SystemTtsSpeaker?> create() async {
    try {
      final tts = FlutterTts();
      await tts.setLanguage('zh-CN');
      await tts.setSpeechRate(0.5);
      final s = SystemTtsSpeaker._(tts);
      try {
        tts.setCompletionHandler(() => s._completeCtrl.add(null));
      } catch (_) {}
      return s;
    } catch (_) {
      return null;
    }
  }

  SystemTtsSpeaker._(this._tts);

  @override
  Future<void> setParams({double? speechRate, double? volume}) async {
    try {
      if (speechRate != null) await _tts?.setSpeechRate(speechRate);
      if (volume != null) await _tts?.setVolume(volume);
    } catch (_) {}
  }

  @override
  Future<void> speak(String text) async {
    try {
      await _tts?.speak(text);
    } catch (_) {}
  }

  @override
  Future<void> stop() async {
    try {
      await _tts?.stop();
    } catch (_) {}
  }

  @override
  Future<void> dispose() async {
    try {
      await _tts?.stop();
    } catch (_) {}
    await _completeCtrl.close();
  }
}

/// HTTP 网络 TTS 扬声器：把文本代入引擎 URL 并播放返回的音频。
class HttpTtsSpeaker extends TtsSpeaker {
  final TtsEngine _engine;
  final AudioPlayer _player = AudioPlayer();
  final _completeCtrl = StreamController<void>.broadcast();
  double _volume = 1.0;

  HttpTtsSpeaker(this._engine) {
    _player.onPlayerComplete.listen((_) => _completeCtrl.add(null));
  }

  @override
  Stream<void> get onComplete => _completeCtrl.stream;

  @override
  String get name => _engine.name;

  @override
  Future<void> setParams({double? speechRate, double? volume}) async {
    // HTTP TTS 由引擎 URL 决定语速，音量仅可通过播放器调节。
    if (volume != null) {
      _volume = volume.clamp(0.0, 1.0);
      try {
        await _player.setVolume(_volume);
      } catch (_) {}
    }
  }

  @override
  Future<void> speak(String text) async {
    final audioUrl = _engine.buildUrl(text);
    if (audioUrl.isEmpty) return;
    try {
      await _player.stop();
      await _player.setVolume(_volume);
      await _player.play(UrlSource(audioUrl));
    } catch (_) {}
  }

  @override
  Future<void> stop() async {
    try {
      await _player.stop();
    } catch (_) {}
  }

  @override
  Future<void> dispose() async {
    try {
      await _player.dispose();
    } catch (_) {}
    await _completeCtrl.close();
  }
}