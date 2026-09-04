import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// 视频章节阅读视图。
///
/// 面向视频书源（type=4）：每个章节是一个视频地址。用官方 [VideoPlayerController]
/// 播放，支持播放/暂停、进度条拖动、上一章/下一章。
class VideoReaderView extends StatefulWidget {
  const VideoReaderView({
    super.key,
    required this.urls,
    required this.title,
    required this.fg,
    required this.bg,
    required this.onNextChapter,
    required this.onPrevChapter,
  });

  /// 视频地址列表（通常单集单条）。
  final List<String> urls;
  final String title;
  final Color fg;
  final Color bg;
  final VoidCallback onNextChapter;
  final VoidCallback onPrevChapter;

  @override
  State<VideoReaderView> createState() => _VideoReaderViewState();
}

class _VideoReaderViewState extends State<VideoReaderView> {
  VideoPlayerController? _controller;
  bool _initialized = false;
  bool _error = false;
  int _urlIndex = 0;
  bool _showControls = true;

  String get _currentUrl =>
      widget.urls.isEmpty ? '' : widget.urls[_urlIndex];

  @override
  void initState() {
    super.initState();
    _load(_currentUrl);
  }

  Future<void> _load(String url) async {
    if (url.isEmpty) {
      setState(() => _error = true);
      return;
    }
    setState(() {
      _initialized = false;
      _error = false;
    });
    try {
      final old = _controller;
      final c = VideoPlayerController.networkUrl(Uri.parse(url));
      await c.initialize();
      await old?.dispose();
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() {
        _controller = c;
        _initialized = true;
        _error = false;
      });
      await c.play();
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = true);
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  void _togglePlay() {
    final c = _controller;
    if (c == null) return;
    setState(() {
      c.value.isPlaying ? c.pause() : c.play();
    });
  }

  void _next() {
    if (_urlIndex < widget.urls.length - 1) {
      setState(() => _urlIndex++);
      _load(_currentUrl);
    } else {
      widget.onNextChapter();
    }
  }

  void _prev() {
    if (_urlIndex > 0) {
      setState(() => _urlIndex--);
      _load(_currentUrl);
    } else {
      widget.onPrevChapter();
    }
  }

  @override
  Widget build(BuildContext context) {
    final bg = widget.bg;
    if (_error) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('视频加载失败：$_currentUrl',
                textAlign: TextAlign.center, style: TextStyle(color: widget.fg)),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () => _load(_currentUrl),
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    if (!_initialized || _controller == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 12),
            Text('加载视频…', style: TextStyle(color: widget.fg)),
          ],
        ),
      );
    }
    final c = _controller!;
    return Column(
      children: [
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _showControls = !_showControls),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Container(color: Colors.black),
                Center(child: VideoPlayer(c)),
                if (_showControls)
                  Center(
                    child: IconButton(
                      iconSize: 56,
                      icon: Icon(
                        c.value.isPlaying ? Icons.pause_circle : Icons.play_circle,
                        color: Colors.white,
                      ),
                      onPressed: _togglePlay,
                    ),
                  ),
              ],
            ),
          ),
        ),
        // 控件区
        Container(
          color: bg.withValues(alpha: 0.85),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.title,
                style: TextStyle(color: widget.fg, fontSize: 13),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 4),
              VideoProgressIndicator(c, allowScrubbing: true, colors: VideoProgressColors(
                playedColor: Theme.of(context).colorScheme.primary,
                bufferedColor: Colors.grey,
              )),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  IconButton(
                    icon: const Icon(Icons.skip_previous),
                    onPressed: _prev,
                    color: widget.fg,
                  ),
                  Text(
                    '${_fmt(c.value.position)} / ${_fmt(c.value.duration)}',
                    style: TextStyle(color: widget.fg, fontSize: 12),
                  ),
                  IconButton(
                    icon: const Icon(Icons.skip_next),
                    onPressed: _next,
                    color: widget.fg,
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  static String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final h = d.inHours;
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }
}