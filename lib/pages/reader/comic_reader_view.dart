import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/reading_pref.dart';
import '../../widgets/comic_image_filter.dart';

/// 漫画/图片阅读视图。
///
/// 以 [PageView] 逐张（或双页）展示章节图片，支持多点触控缩放（最大 5x）、点击切换
/// 阅读器 chrome、左右翻页。到达章节首/末页继续滑动时切换上一个/下一个章节。
/// [offline] 为 true 时 [imageUrls] 是本地文件路径，用 `Image.file` 渲染。
class ComicReaderView extends StatefulWidget {
  const ComicReaderView({
    super.key,
    required this.imageUrls,
    required this.chapterIndex,
    required this.chapterCount,
    required this.chapterTitle,
    required this.fg,
    required this.bg,
    required this.onToggleChrome,
    required this.onNextChapter,
    required this.onPrevChapter,
    this.imageFit = 0,
    this.offline = false,
    this.brightness = 1.0,
    this.contrast = 1.0,
    this.saturation = 1.0,
    this.filter = ComicFilter.none,
    this.doublePage = false,
    this.scrollMode = false,
    this.onlyLarge = false,
  });

  final List<String> imageUrls;
  final int chapterIndex;
  final int chapterCount;
  final String chapterTitle;
  final Color fg;
  final Color bg;
  final VoidCallback onToggleChrome;
  final VoidCallback onNextChapter;
  final VoidCallback onPrevChapter;
  final int imageFit;

  /// 是否渲染本地已下载文件（离线缓存）。
  final bool offline;

  /// 显示亮度：0.3 ~ 1.8，1.0 = 原样。
  final double brightness;

  /// 对比度：0.5 ~ 2.0，1.0 = 原样。
  final double contrast;

  /// 饱和度：0.0 ~ 2.0，1.0 = 原样，0 = 灰度。
  final double saturation;

  /// 色彩滤镜。
  final ComicFilter filter;

  /// 双页模式（一页放两张图）。
  final bool doublePage;

  /// 拼接/连续滚动模式：一列纵向渲染全部图片。
  final bool scrollMode;

  /// 只显示大图：过滤掉过小（占位/长条缩略）的图片。
  final bool onlyLarge;

  /// 判定为“小图”的像素阈值（宽或高低于它则隐藏）。
  static const double kOnlyLargeMin = 96;

  @override
  State<ComicReaderView> createState() => _ComicReaderViewState();
}

class _ComicReaderViewState extends State<ComicReaderView> {
  late final PageController _controller = PageController();
  late int _page = 0;

  // ---- 点击识别（用 Listener 绕过 InteractiveViewer 的手势竞技场）----
  // InteractiveViewer 的 ScaleGestureRecognizer 会在竞技场里吞掉外层 GestureDetector.onTap，
  // 导致点击唤不出设置栏。Pointer 事件不参与竞技场，必定收到。
  Offset? _downPos;
  Duration _downTime = Duration.zero;
  bool _moved = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bg = widget.bg;
    if (widget.imageUrls.isEmpty) {
      return Center(
        child: Text('本章暂无图片', style: TextStyle(color: widget.fg)),
      );
    }
    Widget content;
    if (widget.scrollMode) {
      // 拼接/连续滚动模式：一列纵向全部图片。
      content = ListView.builder(
        padding: EdgeInsets.zero,
        itemCount: widget.imageUrls.length,
        itemBuilder: (_, i) => _buildStretchImage(bg, widget.imageUrls[i]),
      );
    } else {
      content = PageView.builder(
        controller: _controller,
        itemCount: _itemCount,
        onPageChanged: (i) => setState(() => _page = i),
        itemBuilder: (_, i) => _buildPage(bg, i),
      );
    }
    // 色彩/亮度/对比度滤镜整页叠加。
    final filter = comicColorFilter(
      brightness: widget.brightness,
      contrast: widget.contrast,
      saturation: widget.saturation,
      filter: widget.filter,
    );
    if (filter != null) {
      content = ColorFiltered(colorFilter: filter, child: content);
    }
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragEnd: widget.scrollMode
                ? null
                : (d) {
                    if (d.primaryVelocity != null && d.primaryVelocity! < -300) {
                      _nextChapter();
                    } else if (d.primaryVelocity != null &&
                        d.primaryVelocity! > 300) {
                      _prevChapter();
                    }
                  },
            // Listener 负责点击唤 chrome：InteractiveViewer 会吞掉外层 onTap，
            // 这里用 Pointer 事件手动判断「点按」，避免点按无响应。
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: (e) {
                _downPos = e.position;
                _downTime = e.timeStamp;
                _moved = false;
              },
              onPointerMove: (e) {
                final d = _downPos;
                if (d != null && (e.position - d).distance > 12) _moved = true;
              },
              onPointerUp: (e) {
                final d = _downPos;
                if (d == null) return;
                _downPos = null;
                // 位移小且少于长按阈值 → 点按唤 chrome；否则是缩放/平移/翻页/滚动画。
                final isTap = !_moved &&
                    (e.timeStamp - _downTime) < const Duration(milliseconds: 500);
                if (isTap) widget.onToggleChrome();
              },
              child: content,
            ),
          ),
        ),
        // 页码指示
        Positioned(
          left: 0,
          right: 0,
          bottom: 16,
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: bg.withValues(alpha: 0.82),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                widget.scrollMode
                    ? '${widget.chapterTitle}  ${widget.imageUrls.length} 图'
                    : widget.doublePage
                        ? '${widget.chapterTitle}  ${(_page * 2 + 1) - widget.imageUrls.length}…${(_page + 1) * 2} / ${widget.imageUrls.length}'
                        : '${widget.chapterTitle}  ${_page + 1}/${widget.imageUrls.length}',
                style: TextStyle(
                  fontSize: 12,
                  color: widget.fg,
                  overflow: TextOverflow.ellipsis,
                ),
                maxLines: 1,
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 拼接模式下单张图片：宽度撑满，高度自适应。
  Widget _buildStretchImage(Color bg, String url) {
    return Container(
      color: bg,
      alignment: Alignment.topCenter,
      child: _renderImage(bg, url, BoxFit.fitWidth, stretch: true),
    );
  }

  /// 双页模式下每屏两张图，屏数约减半。
  int get _itemCount => widget.doublePage
      ? (widget.imageUrls.length + 1) ~/ 2
      : widget.imageUrls.length;

  int _leftOf(int displayIndex) => widget.doublePage ? displayIndex * 2 : displayIndex;

  Widget _buildPage(Color bg, int displayIndex) {
    final left = _leftOf(displayIndex);
    final images = <Widget>[
      Flexible(
        child: _buildImage(bg, widget.imageUrls[left], stretch: false),
      ),];
    if (widget.doublePage) {
      final right = left + 1;
      if (right < widget.imageUrls.length) {
        images.add(Flexible(
          child: _buildImage(bg, widget.imageUrls[right], stretch: false),
        ));
      } else {
        // 末屏左页单图时，占位保持居中感。
        images.add(const SizedBox.shrink());
      }
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: images,
    );
  }

  Widget _buildImage(Color bg, String url, {required bool stretch}) {
    return LayoutBuilder(
      builder: (_, constraints) => InteractiveViewer(
        maxScale: 5,
        minScale: 0.8,
        clipBehavior: Clip.hardEdge,
        child: Center(
          child: _renderImage(
            bg,
            url,
            widget.imageFit == 1 ? BoxFit.fitWidth : BoxFit.contain,
            stretch: stretch,
          ),
        ),
      ),
    );
  }

  /// 统一渲染单张图片：支持“只显示大图”过滤（帧尺寸过小则隐藏）。
  /// [stretch] 为 true 时代表拼接/滚动模式，无外框约束，需自带加载/错误态。
  Widget _renderImage(Color bg, String url, BoxFit fit, {required bool stretch}) {
    final image = widget.offline
        ? Image.file(
            File(url),
            fit: fit,
            errorBuilder: (_, _, _) => _errorBox(),
            width: stretch ? double.infinity : null,
            height: stretch ? null : double.infinity,
          )
        : Image.network(
            url,
            fit: fit,
            width: stretch ? double.infinity : null,
            height: stretch ? null : double.infinity,
            loadingBuilder: _comicLoading(stretch),
            errorBuilder: (_, _, _) => _errorBox(),
          );
    if (!widget.onlyLarge) return image;
    // 只显示大图：解码后拦下小图。
    return _OnlyLargeGate(
      provider: widget.offline ? FileImage(File(url)) : NetworkImage(url),
      min: ComicReaderView.kOnlyLargeMin,
      placeholder: stretch
          ? Container(
              height: 120,
              alignment: Alignment.center,
              child: CircularProgressIndicator(color: widget.fg))
          : const SizedBox.shrink(),
      child: image,
    );
  }

  /// 拼接/分页的加载态。
  ImageLoadingBuilder _comicLoading(bool stretch) {
    return stretch
        ? (_, child, progress) => progress == null
            ? Container(
                height: 120,
                alignment: Alignment.center,
                child: CircularProgressIndicator(color: widget.fg))
            : child
        : (_, child, progress) => progress == null
            ? child
            : Center(child: CircularProgressIndicator(color: widget.fg));
  }

  Widget _errorBox() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.broken_image_outlined, color: widget.fg, size: 48),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              widget.offline ? '离线图片缺失' : '图片加载失败',
              style: TextStyle(color: widget.fg),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  void _nextChapter() {
    if (_page < _itemCount - 1) {
      _controller.nextPage(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    } else {
      widget.onNextChapter();
    }
  }

  void _prevChapter() {
    if (_page > 0) {
      _controller.previousPage(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    } else {
      widget.onPrevChapter();
    }
  }
}

/// “只显示大图”门：解码图片字节拿到真实尺寸，过小则隐藏子组件。
///
/// 通过 [ImageProvider] 走图片缓存解析，命中后复用于下方 [Image] 渲染，
/// 不会重复下载。
class _OnlyLargeGate extends StatefulWidget {
  const _OnlyLargeGate({
    required this.provider,
    required this.min,
    required this.placeholder,
    required this.child,
  });

  final ImageProvider provider;
  final double min;
  final Widget placeholder;
  final Widget child;

  @override
  State<_OnlyLargeGate> createState() => _OnlyLargeGateState();
}

class _OnlyLargeGateState extends State<_OnlyLargeGate> {
  bool? _large; // null=解码中；true/false=结果

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(covariant _OnlyLargeGate old) {
    super.didUpdateWidget(old);
    if (old.provider != widget.provider) {
      _large = null;
      _resolve();
    }
  }

  Future<void> _resolve() async {
    ImageStream? stream;
    late ImageStreamListener listener;
    bool done = false;
    void finish(bool big) {
      if (done || !mounted) return;
      done = true;
      stream?.removeListener(listener);
      setState(() => _large = big);
    }

    stream = widget.provider.resolve(ImageConfiguration.empty);
    listener = ImageStreamListener(
      (info, _) {
        final w = info.image.width.toDouble();
        final h = info.image.height.toDouble();
        finish(w >= widget.min && h >= widget.min);
      },
      onError: (_, _) => finish(true),
    );
    stream.addListener(listener);
  }

  @override
  Widget build(BuildContext context) {
    final big = _large;
    if (big == null) return widget.placeholder;
    return big ? widget.child : const SizedBox.shrink();
  }
}