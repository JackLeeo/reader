import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import '../../core/audio_playback_service.dart';

/// 听书阅读视图。
///
/// 拉取音频流地址列表，默认播放首条；多条时列表可切换。支持：
/// - 跳过片头（[skipIntro] 秒内不播放，起始 seek）
/// - 倍速播放（[speed]）
/// - 进度条拖动 / 上一段 / 下一段
/// - 整章列表播完自动进入下一章（[onFinish]）
/// 视图生命周期结束时释放 [AudioPlayer]，避免后台常驻。
class AudioReaderView extends StatefulWidget {
  const AudioReaderView({
    super.key,
    required this.urls,
    required this.title,
    required this.fg,
    this.skipIntro = 0.0,
    this.speed = 1.0,
    this.onFinish,
  });

  final List<String> urls;
  final String title;
  final Color fg;

  /// 跳过片头秒数。
  final double skipIntro;

  /// 播放倍速。
  final double speed;

  /// 整章播完（最后一集结束）回调，用于切到下一章。
  final VoidCallback? onFinish;

  @override
  State<AudioReaderView> createState() => _AudioReaderViewState();
}

class _AudioReaderViewState extends State<AudioReaderView> {
  late final AudioPlayer _player;

  /// 预载播放器：预热下一段的源，减少切段时的停顿/缓冲。
  AudioPlayer? _prefetch;
  PlayerState _state = PlayerState.stopped;
  String? _playingUrl;
  bool _failed = false;
  bool _ready = false;
  Duration _pos = Duration.zero;
  Duration _duration = Duration.zero;

  int get _index => widget.urls.indexOf(_playingUrl ?? '');

  @override
  void initState() {
    super.initState();
    _initPlayback();
  }

  /// 解析后台播放（优先）或回退本地播放器，绑定事件流后启动播放。
  Future<void> _initPlayback() async {
    final ok = await AudioPlaybackService.instance.init();
    final servicePlayer = AudioPlaybackService.instance.player;
    final player = ok && servicePlayer != null ? servicePlayer : AudioPlayer();
    _player = player;
    _bindListeners(player);
    if (!mounted) return;
    setState(() => _ready = true);
    if (widget.urls.isNotEmpty) {
      _play(widget.urls.first, seekIntro: true);
    }
  }

  void _bindListeners(AudioPlayer p) {
    p.onPlayerStateChanged.listen((s) {
      if (!mounted) return;
      setState(() => _state = s);
    });
    p.onPlayerComplete.listen((_) {
      if (!mounted) return;
      _playNext();
    });
    p.onPositionChanged.listen((pos) {
      if (!mounted) return;
      setState(() => _pos = pos);
    });
    p.onDurationChanged.listen((d) {
      if (!mounted) return;
      setState(() => _duration = d);
    });
  }

  @override
  void didUpdateWidget(covariant AudioReaderView old) {
    super.didUpdateWidget(old);
    // 倍速变化实时生效。
    if (old.speed != widget.speed && _state == PlayerState.playing) {
      _player.setPlaybackRate(widget.speed);
    }
  }

  @override
  void dispose() {
    if (AudioPlaybackService.instance.player == _player) {
      // 共享的后台播放器由服务统一释放，此处仅做轻量停止。
      AudioPlaybackService.instance.stop();
    } else {
      _player.dispose();
    }
    _prefetch?.dispose();
    _prefetch = null;
    super.dispose();
  }

  /// 预热下一段：如果还有下一段，用预载播放器加载以触发缓冲。
  Future<void> _prefetchNext() async {
    final nextIdx = _index + 1;
    if (nextIdx < 0 || nextIdx >= widget.urls.length) return;
    final next = widget.urls[nextIdx];
    try {
      _prefetch ??= AudioPlayer();
      if (_prefetch!.state != PlayerState.playing) {
        await _prefetch!.setSourceUrl(next);
      }
    } catch (_) {
      // 预载失败不影响主播放。
    }
  }

  Future<void> _play(String url, {bool seekIntro = false}) async {
    if (!_ready) return;
    setState(() {
      _playingUrl = url;
      _failed = false;
      _pos = Duration.zero;
      _duration = Duration.zero;
    });
    // 后台播放：主播放器即后台服务播放器，同时更新系统媒体信息与控制回调。
    if (AudioPlaybackService.instance.player == _player) {
      await AudioPlaybackService.instance.play(
        url: url,
        title: widget.title,
        artist: '听书',
        onNext: () => _playNext(),
        onPrev: () => _playPrev(),
      );
      try {
        await _player.setPlaybackRate(widget.speed);
      } catch (_) {}
    } else {
      try {
        await _player.stop();
        await _player.setPlaybackRate(widget.speed);
        await _player.play(UrlSource(url));
      } catch (e) {
        if (!mounted) return;
        setState(() => _failed = true);
      }
    }
    // 跳过片头：开播后跳到指定秒数。
    if (seekIntro && widget.skipIntro > 0) {
      try {
        await _player.seek(Duration(seconds: widget.skipIntro.round()));
      } catch (_) {}
    }
    // 开播后预载下一段，切段时可免缓冲。
    unawaited(_prefetchNext());
  }

  Future<void> _playNext() async {
    final i = _index;
    if (i >= 0 && i < widget.urls.length - 1) {
      _play(widget.urls[i + 1]);
    } else if (i == widget.urls.length - 1) {
      widget.onFinish?.call();
    }
  }

  Future<void> _playPrev() async {
    final i = _index;
    if (i > 0) {
      _play(widget.urls[i - 1]);
    }
  }

  Future<void> _toggle() async {
    if (_playingUrl == null) return;
    try {
      if (_state == PlayerState.playing) {
        await _player.pause();
      } else {
        await _player.resume();
        // 恢复时若处于片头内且未跳过，补跳一次。
        if (widget.skipIntro > 0 &&
            _pos.inMilliseconds < widget.skipIntro * 1000) {
          await _player.seek(Duration(seconds: widget.skipIntro.round()));
        }
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _failed = true);
    }
  }

  Future<void> _seekTo(Duration d) async {
    try {
      await _player.seek(d);
      setState(() => _pos = d);
      if (_state != PlayerState.playing) {
        await _player.resume();
        setState(() => _state = PlayerState.playing);
      }
    } catch (_) {}
  }

  String _fmt(Duration d) {
    final s = d.inSeconds;
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    final sec = s % 60;
    String two(int v) => v.toString().padLeft(2, '0');
    return h > 0 ? '$h:${two(m)}:${two(sec)}' : '${two(m)}:${two(sec)}';
  }

  @override
  Widget build(BuildContext context) {
    if (widget.urls.isEmpty) {
      return Center(
        child: Text('本章暂无音频', style: TextStyle(color: widget.fg)),
      );
    }
    if (!_ready) {
      return Center(
        child: Text('音频播放就绪中…', style: TextStyle(color: widget.fg)),
      );
    }
    final playing = _state == PlayerState.playing;
    final progress = _duration.inMilliseconds > 0
        ? (_pos.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

    return Column(
      children: [
        const Spacer(),
        Icon(
          playing ? Icons.graphic_eq : Icons.headset_outlined,
          color: widget.fg,
          size: 64,
        ),
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Text(
            widget.title,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                color: widget.fg, fontSize: 16, fontWeight: FontWeight.w600),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          playing ? '播放中' : _failed ? '播放失败' : '已就绪',
          style: TextStyle(color: widget.fg.withValues(alpha: 0.6)),
        ),
        const SizedBox(height: 12),
        // 进度条
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Row(
            children: [
              Text(_fmt(_pos), style: TextStyle(fontSize: 11, color: widget.fg)),
              Expanded(
                child: Slider(
                  value: progress,
                  onChanged: (v) =>
                      _seekTo(Duration(milliseconds: (v * _duration.inMilliseconds).round())),
                ),
              ),
              Text(_fmt(_duration),
                  style: TextStyle(fontSize: 11, color: widget.fg)),
            ],
          ),
        ),
        const SizedBox(height: 8),
        // 上一段 / 播放暂停 / 下一段
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              onPressed: (_index > 0) ? _playPrev : null,
              iconSize: 32,
              icon: Icon(Icons.skip_previous, color: widget.fg),
            ),
            const SizedBox(width: 16),
            IconButton.filled(
              onPressed: _toggle,
              iconSize: 48,
              icon: Icon(playing ? Icons.pause : Icons.play_arrow),
            ),
            const SizedBox(width: 16),
            IconButton(
              onPressed: (_index >= 0 && _index < widget.urls.length)
                  ? _playNext
                  : null,
              iconSize: 32,
              icon: Icon(Icons.skip_next, color: widget.fg),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          '倍速 ×${widget.speed.toStringAsFixed(1)}'
          '${widget.skipIntro > 0 ? ' · 跳过片头 ${widget.skipIntro.round()}s' : ''}',
          style: TextStyle(fontSize: 12, color: widget.fg.withValues(alpha: 0.6)),
        ),
        const SizedBox(height: 20),
        if (widget.urls.length > 1) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('音频列表（${widget.urls.length} 段）',
                  style: TextStyle(
                      color: widget.fg.withValues(alpha: 0.7), fontSize: 12)),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              itemCount: widget.urls.length,
              itemBuilder: (_, i) {
                final selected = widget.urls[i] == _playingUrl;
                return ListTile(
                  dense: true,
                  selected: selected,
                  leading: Icon(
                    selected ? Icons.play_circle : Icons.music_note,
                    color: widget.fg,
                  ),
                  title: Text(
                    '第 ${i + 1} 段',
                    style: TextStyle(color: widget.fg),
                  ),
                  onTap: () => _play(widget.urls[i]),
                );
              },
            ),
          ),
        ] else
          const Spacer(),
      ],
    );
  }
}