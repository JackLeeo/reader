import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import '../../utils/reader_themes.dart';

/// 漫画/图片章节阅读视图：全屏 PageView 浏览网络图片，
/// 支持点击翻页、双指缩放、页码指示与章节边界切换。
class BookSourceImageChapterView extends StatefulWidget {
  const BookSourceImageChapterView({
    super.key,
    required this.imageUrls,
    required this.chapterTitle,
    required this.hasPreviousChapter,
    required this.hasNextChapter,
    required this.onPreviousChapter,
    required this.onNextChapter,
    required this.theme,
    required this.onToggleControls,
    this.httpHeaders = const {},
  });

  final List<String> imageUrls;
  final String chapterTitle;
  final bool hasPreviousChapter;
  final bool hasNextChapter;
  final VoidCallback onPreviousChapter;
  final VoidCallback onNextChapter;
  final ReaderThemePalette theme;
  final VoidCallback onToggleControls;
  final Map<String, String> httpHeaders;

  @override
  State<BookSourceImageChapterView> createState() =>
      _BookSourceImageChapterViewState();
}

class _BookSourceImageChapterViewState
    extends State<BookSourceImageChapterView> {
  late final PageController _controller;
  int _index = 0;
  double _scale = 1;

  @override
  void initState() {
    super.initState();
    _controller = PageController();
  }

  @override
  void didUpdateWidget(BookSourceImageChapterView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 章节切换后重置到第一页。
    if (oldWidget.imageUrls != widget.imageUrls && _controller.hasClients) {
      _controller.jumpToPage(0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _goTo(int target) {
    if (target < 0) {
      if (widget.hasPreviousChapter) widget.onPreviousChapter();
      return;
    }
    if (target >= widget.imageUrls.length) {
      if (widget.hasNextChapter) widget.onNextChapter();
      return;
    }
    _controller.animateToPage(
      target,
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
    );
  }

  void _handleTap(Offset position, Size size) {
    final zone = size.width / 3;
    if (position.dx < zone) {
      _goTo(_index - 1);
    } else if (position.dx > zone * 2) {
      _goTo(_index + 1);
    } else {
      // 中间区域切换阅读器控制栏（返回/目录/设置入口）。
      widget.onToggleControls();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    return Scaffold(
      backgroundColor: Colors.black,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final size = constraints.biggest;
          return Stack(
            children: [
              // 捏合缩放由 InteractiveViewer 承担；放大时锁定翻页。
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: (details) {
                  if (_scale <= 1.02) _handleTap(details.localPosition, size);
                },
                child: InteractiveViewer(
                  minScale: 1,
                  maxScale: 5,
                  onInteractionUpdate: (details) {
                    final scale = details.scale;
                    if ((scale - _scale).abs() > 0.01) {
                      setState(() => _scale = scale);
                    }
                  },
                  onInteractionEnd: (_) => setState(() => _scale = 1),
                  child: PageView.builder(
                    controller: _controller,
                    physics: _scale > 1.02
                        ? const NeverScrollableScrollPhysics()
                        : const PageScrollPhysics(),
                    itemCount: widget.imageUrls.length,
                    onPageChanged: (index) => setState(() => _index = index),
                    itemBuilder: (context, index) => Center(
                      child: Image.network(
                        widget.imageUrls[index],
                        fit: BoxFit.contain,
                        gaplessPlayback: true,
                        headers: widget.httpHeaders,
                        loadingBuilder: (context, child, progress) {
                          if (progress == null) return child;
                          return Center(
                            child: CircularProgressIndicator(
                              value: progress.expectedTotalBytes != null
                                  ? progress.cumulativeBytesLoaded /
                                        progress.expectedTotalBytes!
                                  : null,
                              color: theme.accent,
                            ),
                          );
                        },
                        errorBuilder: (context, error, stackTrace) => Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.broken_image_rounded,
                                size: 48,
                                color: theme.secondaryText,
                              ),
                              const SizedBox(height: 12),
                              Text(
                                '第 ${index + 1} 页加载失败',
                                style: TextStyle(color: theme.secondaryText),
                              ),
                              const SizedBox(height: 8),
                              TextButton(
                                onPressed: () => setState(() {}),
                                child: const Text('重试'),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              // 顶部信息条
              Positioned(
                top: MediaQuery.paddingOf(context).top + 8,
                left: 16,
                right: 16,
                child: IgnorePointer(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      '${widget.chapterTitle} · ${_index + 1}/'
                      '${widget.imageUrls.length}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// 听书章节播放视图：内嵌 audioplayers 播放章节音频，
/// 支持播放/暂停、进度拖动、倍速、自动连播下一章。
class BookSourceAudioChapterView extends StatefulWidget {
  const BookSourceAudioChapterView({
    super.key,
    required this.audioUrls,
    required this.chapterTitle,
    required this.bookTitle,
    required this.hasPreviousChapter,
    required this.hasNextChapter,
    required this.onPreviousChapter,
    required this.onNextChapter,
    required this.theme,
    required this.onShowCatalog,
  });

  final List<String> audioUrls;
  final String chapterTitle;
  final String bookTitle;
  final bool hasPreviousChapter;
  final bool hasNextChapter;
  final VoidCallback onPreviousChapter;
  final VoidCallback onNextChapter;
  final ReaderThemePalette theme;
  final VoidCallback onShowCatalog;

  @override
  State<BookSourceAudioChapterView> createState() =>
      _BookSourceAudioChapterViewState();
}

class _BookSourceAudioChapterViewState
    extends State<BookSourceAudioChapterView> {
  late final AudioPlayer _player;
  int _trackIndex = 0;
  bool _playing = false;
  bool _completed = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double _speed = 1.0;
  String? _error;
  StreamSubscription? _onComplete;
  StreamSubscription? _onPosition;
  StreamSubscription? _onDuration;
  StreamSubscription? _onState;

  @override
  void initState() {
    super.initState();
    _player = AudioPlayer();
    _player.setReleaseMode(ReleaseMode.stop);
    _onComplete = _player.onPlayerComplete.listen((_) {
      _playNextTrackOrChapter();
    });
    _onPosition = _player.onPositionChanged.listen((position) {
      if (mounted) setState(() => _position = position);
    });
    _onDuration = _player.onDurationChanged.listen((duration) {
      if (mounted) setState(() => _duration = duration);
    });
    _onState = _player.onPlayerStateChanged.listen((state) {
      if (mounted) {
        setState(() {
          _playing = state == PlayerState.playing;
        });
      }
    });
    unawaited(_playTrack(0));
  }

  @override
  void didUpdateWidget(BookSourceAudioChapterView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.audioUrls != widget.audioUrls) {
      unawaited(_playTrack(0));
    }
  }

  Future<void> _playTrack(int index) async {
    if (index < 0) {
      if (widget.hasPreviousChapter) widget.onPreviousChapter();
      return;
    }
    if (index >= widget.audioUrls.length) {
      if (widget.hasNextChapter) widget.onNextChapter();
      return;
    }
    setState(() {
      _trackIndex = index;
      _error = null;
      _completed = false;
      _position = Duration.zero;
      _duration = Duration.zero;
    });
    try {
      await _player.play(UrlSource(widget.audioUrls[index]));
      await _player.setPlaybackRate(_speed);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  void _playNextTrackOrChapter() {
    if (_trackIndex + 1 < widget.audioUrls.length) {
      unawaited(_playTrack(_trackIndex + 1));
    } else if (widget.hasNextChapter) {
      setState(() => _completed = true);
      widget.onNextChapter();
    } else {
      setState(() => _completed = true);
    }
  }

  Future<void> _togglePlay() async {
    if (_playing) {
      await _player.pause();
    } else {
      if (_completed && _position >= _duration) {
        await _playTrack(_trackIndex);
        return;
      }
      await _player.resume();
    }
  }

  Future<void> _cycleSpeed() async {
    const speeds = [1.0, 1.25, 1.5, 2.0, 0.75];
    final next = speeds[(speeds.indexOf(_speed) + 1) % speeds.length];
    setState(() => _speed = next);
    await _player.setPlaybackRate(next);
  }

  @override
  void dispose() {
    unawaited(_onComplete?.cancel());
    unawaited(_onPosition?.cancel());
    unawaited(_onDuration?.cancel());
    unawaited(_onState?.cancel());
    unawaited(_player.dispose());
    super.dispose();
  }

  String _format(Duration value) {
    final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '${value.inHours > 0 ? '${value.inHours}:' : ''}$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    return Scaffold(
      backgroundColor: theme.background,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(),
              Container(
                height: 220,
                decoration: BoxDecoration(
                  color: theme.surface,
                  borderRadius: BorderRadius.circular(28),
                  border: Border.all(color: theme.border),
                ),
                child: Icon(
                  _playing
                      ? Icons.graphic_eq_rounded
                      : Icons.headphones_rounded,
                  size: 88,
                  color: theme.accent,
                ),
              ),
              const SizedBox(height: 32),
              Text(
                widget.bookTitle,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: theme.secondaryText,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                widget.chapterTitle,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: theme.text,
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (widget.audioUrls.length > 1) ...[
                const SizedBox(height: 8),
                Text(
                  '音轨 ${_trackIndex + 1}/${widget.audioUrls.length}',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: theme.secondaryText, fontSize: 12),
                ),
              ],
              const SizedBox(height: 28),
              if (_error != null) ...[
                Text(
                  '播放失败：$_error',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.redAccent, fontSize: 13),
                ),
                const SizedBox(height: 12),
              ],
              Row(
                children: [
                  Text(_format(_position), style: TextStyle(color: theme.secondaryText, fontSize: 12)),
                  Expanded(
                    child: Slider(
                      value: _duration.inMilliseconds > 0
                          ? _position.inMilliseconds
                                .clamp(0, _duration.inMilliseconds)
                                .toDouble()
                          : 0,
                      max: _duration.inMilliseconds > 0
                          ? _duration.inMilliseconds.toDouble()
                          : 1,
                      activeColor: theme.accent,
                      onChanged: _duration.inMilliseconds > 0
                          ? (value) {
                              unawaited(
                                _player.seek(
                                  Duration(milliseconds: value.round()),
                                ),
                              );
                            }
                          : null,
                    ),
                  ),
                  Text(_format(_duration), style: TextStyle(color: theme.secondaryText, fontSize: 12)),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    onPressed: widget.hasPreviousChapter
                        ? widget.onPreviousChapter
                        : null,
                    icon: const Icon(Icons.skip_previous_rounded),
                    color: theme.text,
                    iconSize: 36,
                  ),
                  const SizedBox(width: 24),
                  SizedBox(
                    width: 84,
                    height: 84,
                    child: FilledButton(
                      onPressed: _togglePlay,
                      style: FilledButton.styleFrom(
                        shape: const CircleBorder(),
                        backgroundColor: theme.accent,
                        foregroundColor: theme.onAccent,
                      ),
                      child: Icon(
                        _playing
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        size: 44,
                      ),
                    ),
                  ),
                  const SizedBox(width: 24),
                  IconButton(
                    onPressed: _playNextTrackOrChapter,
                    icon: const Icon(Icons.skip_next_rounded),
                    color: theme.text,
                    iconSize: 36,
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  TextButton.icon(
                    onPressed: _cycleSpeed,
                    icon: Icon(Icons.speed_rounded, color: theme.secondaryText),
                    label: Text(
                      '${_speed}x',
                      style: TextStyle(color: theme.secondaryText),
                    ),
                  ),
                  const SizedBox(width: 12),
                  TextButton.icon(
                    onPressed: widget.onShowCatalog,
                    icon: Icon(
                      Icons.format_list_bulleted_rounded,
                      color: theme.secondaryText,
                    ),
                    label: Text(
                      '目录',
                      style: TextStyle(color: theme.secondaryText),
                    ),
                  ),
                ],
              ),
              const Spacer(),
            ],
          ),
        ),
      ),
    );
  }
}
