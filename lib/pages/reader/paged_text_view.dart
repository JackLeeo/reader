import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../book_source/analyze/text_pager.dart';
import '../../book_source/services/highlight_service.dart';
import '../search/search_page.dart';

/// 点击区域类型（左右两侧翻页、中间唤菜单）。
enum PageTapZone { left, middle, right }

/// 分页正文视图：把章节正文按视口切成多页并用 [PageView] 渲染。
///
/// 支持三种真实换页模式（区别于旧的单一滚动）：
/// - 纵向(3)：垂直翻页
/// - 覆盖(1)：横向滑动，下一页覆盖（默认 PageView slide）
/// - 仿真(0)：横向，近似书页翻开（出页略缩放 + 页沿阴影）
/// 滚动(2) 模式不在本组件内实现，由阅读器走原来的滚动视图。
///
/// 正文支持三指/长按选中，选中菜单提供「复制、查词典、添加高亮」；
/// 同时叠加 [highlightBuilder] 返回的高亮区间（背景色）渲染。
class PagedTextView extends StatefulWidget {
  const PagedTextView({
    super.key,
    required this.body,
    required this.style,
    required this.pageMode,
    required this.padding,
    required this.onTap,
    required this.onPageChanged,
    this.onZoneTap,
    this.initialPage = 0,
    this.highlightBuilder,
    this.onDictQuery,
    this.onAddHighlight,
  });

  final String body;
  final TextStyle style;
  final int pageMode;
  final double padding;
  final VoidCallback onTap;

  /// 点击区域回调：启用「点击区域动作」时由阅读器按 [PageTapZone] 响应；
  /// 为 null 时退回 [onTap]（整屏切换菜单）。
  final void Function(PageTapZone zone)? onZoneTap;

  /// 页码变化回调 (当前页, 总页数)。
  final void Function(int page, int total) onPageChanged;

  /// 起始页（续读时传入）。
  final int initialPage;

  /// 对单个页面文本计算要加背景高亮的区间（可为 null 关闭高亮渲染）。
  final List<HighlightMatch> Function(String pageText)? highlightBuilder;

  /// 划词「查词典」，参数为选中的词。
  final void Function(String word)? onDictQuery;

  /// 划词「添加高亮」，参数为选中的词。
  final void Function(String word)? onAddHighlight;

  @override
  PagedTextViewState createState() => PagedTextViewState();
}

class PagedTextViewState extends State<PagedTextView> {
  TextPaginator? _pager;
  PageController? _ctrl;
  int _page = 0;
  String _cacheKey = '';

  // ---- 点击识别（用 Listener 绕过 SelectableText 的手势竞技场）----
  Offset? _downPos;
  Duration _downTime = Duration.zero;
  bool _moved = false;

  bool get isVertical => widget.pageMode == 3;

  @override
  void dispose() {
    _ctrl?.dispose();
    super.dispose();
  }

  void _ensurePager(String body, TextStyle style, Size box) {
    final key = '${body.hashCode}|${style.fontSize}|${style.height}|'
        '${box.width}|${box.height}|${style.letterSpacing}';
    if (_pager != null && _cacheKey == key) return;
    _pager = TextPaginator(body: body, style: style, size: box)
      ..paginate();
    _cacheKey = key;
    final count = _pager!.pages.isEmpty ? 1 : _pager!.pages.length;
    final target = widget.initialPage.clamp(0, count - 1);
    _page = target;
    _ctrl?.dispose();
    _ctrl = PageController(initialPage: target);
  }

  int get pageCount => _pager?.pages.length ?? 0;
  int get currentPage => _page;

  /// 自动翻页：下一页，到底返回 false（由调用方决定是否翻章）。
  bool goNextPage() {
    if (_pager == null || _ctrl == null) return false;
    if (_page < _pager!.pages.length - 1) {
      _ctrl!.nextPage(
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOut,
      );
      return true;
    }
    return false;
  }

  /// 自动/点击回翻：上一页，到顶返回 false。
  bool goPrevPage() {
    if (_pager == null || _ctrl == null) return false;
    if (_page > 0) {
      _ctrl!.previousPage(
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOut,
      );
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final box = Size(
        (c.maxWidth - 2 * widget.padding).clamp(1.0, double.infinity),
        (c.maxHeight - 2 * widget.padding).clamp(1.0, double.infinity),
      );
      _ensurePager(widget.body, widget.style, box);
      final pages = _pager!.pages;
      final count = pages.length;
      if (count == 0) return const SizedBox.shrink();

      Widget builder(BuildContext _, int i) => _buildPage(pages[i], count);
      return PageView.builder(
        key: ValueKey(_cacheKey),
        controller: _ctrl,
        scrollDirection: isVertical ? Axis.vertical : Axis.horizontal,
        itemCount: count,
        onPageChanged: (i) {
          _page = i;
          widget.onPageChanged(i, count);
        },
        itemBuilder: (ctx, i) =>
            widget.pageMode == 0 ? _simulatePage(ctx, i, builder, count) : builder(ctx, i),
      );
    });
  }

  Widget _buildPage(String text, int count) {
    final word = widget.style;
    // 叠加高亮渲染（若有）→ 构造富文本 TextSpan。
    final base = TextSpan(text: text, style: word);
    TextSpan span = base;
    final matches = widget.highlightBuilder?.call(text) ?? const [];
    if (matches.isNotEmpty) {
      final children = <InlineSpan>[];
      var pos = 0;
      for (final m in matches) {
        if (m.start > pos) {
          children.add(TextSpan(text: text.substring(pos, m.start)));
        }
        children.add(TextSpan(
          text: text.substring(m.start, m.end.clamp(0, text.length)),
          style: _spanStyle(m),
        ));
        pos = m.end;
      }
      if (pos < text.length) children.add(TextSpan(text: text.substring(pos)));
      span = TextSpan(style: word, children: children);
    }
    return LayoutBuilder(builder: (ctx, box) {
      final width = box.maxWidth;
      // 用 Listener：SelectableText 内部的手势识别器会吞掉外层 GestureDetector 的
      // onTapUp/onTap，导致点击唤不出菜单。Pointer 事件不参与手势竞技场，必定收到。
      return Listener(
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
          // 位移小且按下时间短于长按阈值 → 视为点按，否则是滑动翻页 / 划词 / 长按选中。
          final isTap = !_moved && (e.timeStamp - _downTime) < const Duration(milliseconds: 500);
          if (!isTap) return;
          _handleTapUp(e.position.dx, width);
        },
        child: Padding(
          padding: EdgeInsets.all(widget.padding),
          child: Align(
            alignment: Alignment.topLeft,
            child: SelectableText.rich(
              span,
              style: word,
              contextMenuBuilder: (ctx, editableTextState) =>
                  _buildSelectionMenu(ctx, editableTextState),
            ),
          ),
        ),
      );
    });
  }

  /// 点击命中：根据横坐标把页面分成左/中/右三区。
  /// 启用「点击区域动作」时按区响应，否则整屏切换菜单。
  void _handleTapUp(double dx, double width) {
    if (width <= 0) {
      widget.onTap();
      return;
    }
    if (widget.onZoneTap == null) {
      widget.onTap();
      return;
    }
    final zone = dx < width / 3
        ? PageTapZone.left
        : (dx > width * 2 / 3 ? PageTapZone.right : PageTapZone.middle);
    widget.onZoneTap?.call(zone);
  }

  /// 选中菜单：复制 / 查词典 / 添加高亮。
  Widget _buildSelectionMenu(
      BuildContext ctx, EditableTextState editableTextState) {
    final actions = <ContextMenuButtonItem>[
      ContextMenuButtonItem(
        label: '复制',
        onPressed: () {
          final selected = editableTextState.textEditingValue.selection;
          if (selected.isValid) {
            Clipboard.setData(ClipboardData(
                text: editableTextState.textEditingValue.text
                    .substring(selected.start, selected.end)));
          }
          editableTextState.hideToolbar();
        },
      ),
    ];
    void wordAction(void Function(String) fn) {
      final selected = editableTextState.textEditingValue.selection;
      if (!selected.isValid) return;
      final w = editableTextState.textEditingValue.text
          .substring(selected.start, selected.end)
          .trim();
      editableTextState.hideToolbar();
      if (w.isNotEmpty) fn(w);
    }

    // 搜索：选中跳转搜索页
    actions.add(ContextMenuButtonItem(
      label: '搜索',
      onPressed: () => wordAction((word) {
        if (word.trim().isEmpty) return;
        Navigator.push(
          ctx,
          MaterialPageRoute(
            builder: (_) => SearchPage(initialText: word),
          ),
        );
      }),
    ));

    if (widget.onDictQuery != null) {
      actions.add(ContextMenuButtonItem(
        label: '查词典',
        onPressed: () => wordAction(widget.onDictQuery!),
      ));
    }
    if (widget.onAddHighlight != null) {
      actions.add(ContextMenuButtonItem(
        label: '添加高亮',
        onPressed: () => wordAction(widget.onAddHighlight!),
      ));
    }
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: editableTextState.contextMenuAnchors,
      buttonItems: actions,
    );
  }

  Color _parseColor(String hex) {
    var h = hex.replaceAll('#', '');
    if (h.length == 6) h = 'FF$h';
    final v = int.tryParse(h, radix: 16);
    if (v == null) return const Color(0x33FFFF00);
    return Color(v);
  }

  /// 按高亮样式生成 TextStyle：背景高亮 / 下划线 / 删除线。
  TextStyle _spanStyle(HighlightMatch m) {
    final color = _parseColor(m.colorHex);
    switch (m.style) {
      case HighlightDrawStyle.underline:
        return TextStyle(
          decoration: TextDecoration.underline,
          decorationColor: color,
        );
      case HighlightDrawStyle.strikethrough:
        return TextStyle(
          decoration: TextDecoration.lineThrough,
          decorationColor: color,
        );
      case HighlightDrawStyle.highlight:
        return TextStyle(backgroundColor: color);
    }
  }

  /// 仿真：出页略缩放 + 页沿渐变阴影，近似书页翻开。
  Widget _simulatePage(
      BuildContext context, int i, Widget Function(BuildContext, int) inner, int count) {
    return AnimatedBuilder(
      animation: _ctrl!,
      builder: (context, child) {
        final pos = _ctrl!.hasClients && _ctrl!.position.hasPixels
            ? (_ctrl!.page ?? i.toDouble())
            : i.toDouble();
        final delta = pos - i; // 出/入偏移，范围约 [-1, 1]
        final outgoing = delta.abs();
        final scale = 1 - 0.05 * outgoing;
        return Opacity(
          opacity: (1 - 0.15 * outgoing).clamp(0.0, 1.0),
          child: Transform.scale(scale: scale, child: child),
        );
      },
      child: inner(context, i),
    );
  }
}