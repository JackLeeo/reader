import 'package:flutter/painting.dart';

/// 文本分页引擎：按视口高度把长正文切成 N 页。
///
/// 用 [TextPainter] 度量每段子串在既定宽度下线高，二分查找「能放入
/// [size] 高度」的最大字符数，从而得到每页正文。消费方在每个布局周期
/// 传入新的 [size] 重新 [paginate]。
class TextPaginator {
  TextPaginator({
    required this.body,
    required this.style,
    required this.size,
    this.lookBackForWrap = 40,
  });

  String body;
  TextStyle style;
  Size size;

  /// 断行时向前回看的字节窗口（把断点回退到最近的空白，避免切断英文单词）。
  final int lookBackForWrap;

  final List<String> _pages = [];

  /// 分页结果（每页一段文本）。
  List<String> get pages => List.unmodifiable(_pages);

  /// 重新分页。
  void paginate() {
    _pages.clear();
    if (body.isEmpty) {
      _pages.add('');
      return;
    }
    var start = 0;
    while (start < body.length) {
      final breakLen = _findBreakLength(start);
      _pages.add(body.substring(start, start + breakLen));
      final next = start + breakLen;
      if (next <= start) return; // 防死循环：极端小视口
      start = next;
    }
  }

  /// 从 [startFrom] 起，求出「恰好放满一页」的切片长度。
  int _findBreakLength(int startFrom) {
    final text = body.substring(startFrom);
    if (text.isEmpty) return 0;

    // 二分查找最大 len，使 substring(0, len) 排版高度 <= size.height。
    var lo = 1, hi = text.length;
    var ans = 1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (_fitsHeight(text.substring(0, mid))) {
        ans = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }

    // 断点回退到最近空白，避免切断英文单词（CJK 自动按字符换行，不受影响）。
    if (lookBackForWrap > 0) {
      final from = (ans - lookBackForWrap).clamp(1, text.length);
      for (var i = ans - 1; i >= from; i--) {
        if (text.codeUnitAt(i) == 0x20) {
          ans = i; // 切到空格后一位
          return ans + 1;
        }
      }
    }
    return ans < 1 ? 1 : ans;
  }

  /// 指定子串在 [size.width] 下排版后高度是否不超过 [size.height]。
  bool _fitsHeight(String sub) {
    final painter = TextPainter(
      text: TextSpan(text: sub, style: style),
      textDirection: TextDirection.ltr,
    )..layout(minWidth: size.width, maxWidth: size.width);
    final fits = painter.height <= size.height;
    painter.dispose();
    return fits;
  }
}