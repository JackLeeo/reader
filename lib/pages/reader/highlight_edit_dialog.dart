import 'package:flutter/material.dart';

import '../../book_source/services/highlight_service.dart';

/// 高亮样式编辑对话框（对齐官方 HighlightStyle + 笔记）。
///
/// 支持：颜色色板、绘制样式（背景高亮/下划线/删除线）、可选笔记。
/// 传入 [rule] 表示编辑既有高亮；否则用 [keyword] 新建。
/// 返回编辑后的 [HighlightRule]；取消返回 null。
Future<HighlightRule?> showHighlightEditDialog(
  BuildContext context, {
  HighlightRule? rule,
  String? keyword,
}) {
  return showDialog<HighlightRule>(
    context: context,
    builder: (_) => _HighlightEditDialog(
      initial: rule ??
          HighlightRule(
            name: 'highlight-${DateTime.now().millisecondsSinceEpoch}',
            keyword: keyword ?? '',
          ),
    ),
  );
}

const _palette = <Color>[
  Color(0x66FFEB3B), // 黄
  Color(0x6666BB6A), // 绿
  Color(0x66FF7043), // 橙
  Color(0x6627C4F5), // 青
  Color(0x667C4DFF), // 紫
  Color(0x66F06292), // 粉
];

class _HighlightEditDialog extends StatefulWidget {
  const _HighlightEditDialog({required this.initial});
  final HighlightRule initial;

  @override
  State<_HighlightEditDialog> createState() => _HighlightEditDialogState();
}

class _HighlightEditDialogState extends State<_HighlightEditDialog> {
  late Color _color;
  late HighlightDrawStyle _style;
  late final TextEditingController _noteCtrl;

  @override
  void initState() {
    super.initState();
    _color = _hexToColor(widget.initial.colorHex);
    // 色板里没有则补进当前色
    if (!_palette.any((c) => c == _color)) {
      _paletteNoDefault = [..._palette, _color];
    }
    _style = widget.initial.style;
    _noteCtrl = TextEditingController(text: widget.initial.note ?? '');
  }

  List<Color> _paletteNoDefault = _palette;

  String _colorToHex(Color c) {
    final argb = c.toARGB32();
    String comp(int v) =>
        (v & 0xFF).toRadixString(16).padLeft(2, '0').toUpperCase();
    return '#${comp(argb >> 24)}${comp(argb >> 16)}${comp(argb >> 8)}${comp(argb)}';
  }

  Color _hexToColor(String hex) {
    var h = hex.replaceAll('#', '');
    if (h.length == 6) h = 'FF$h';
    return Color(int.tryParse(h, radix: 16) ?? 0x66FFEB3B);
  }

  @override
  void dispose() {
    _noteCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('高亮样式'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if ((widget.initial.keyword.isNotEmpty) ||
                (widget.initial.note ?? '').isNotEmpty) ...[
              Text('词条：「${widget.initial.keyword}」',
                  style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 12),
            ],
            const Text('颜色'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final c in _paletteNoDefault)
                  GestureDetector(
                    onTap: () => setState(() => _color = c),
                    child: Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: c,
                        shape: BoxShape.circle,
                        border: Border.all(
                          width: 2,
                          color: _color == c
                              ? Theme.of(context).colorScheme.primary
                              : Colors.transparent,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            const Text('样式'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                _styleChip('高亮', HighlightDrawStyle.highlight),
                _styleChip('下划线', HighlightDrawStyle.underline),
                _styleChip('删除线', HighlightDrawStyle.strikethrough),
              ],
            ),
            const SizedBox(height: 16),
            const Text('笔记（可选）'),
            const SizedBox(height: 8),
            TextField(
              controller: _noteCtrl,
              maxLines: 3,
              decoration: const InputDecoration(
                hintText: '写点笔记…',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            final note = _noteCtrl.text.trim();
            Navigator.pop(
              context,
              widget.initial.copyWithRaw(
                colorHex: _colorToHex(_color),
                style: _style,
                note: note.isEmpty ? null : note,
              ),
            );
          },
          child: const Text('确定'),
        ),
      ],
    );
  }

  Widget _styleChip(String label, HighlightDrawStyle s) {
    final on = _style == s;
    return ChoiceChip(
      label: Text(label),
      selected: on,
      onSelected: (_) => setState(() => _style = s),
    );
  }
}

extension on HighlightRule {
  /// 保留 name/keyword/enabled，覆盖颜色/样式/笔记。
  HighlightRule copyWithRaw({
    String? colorHex,
    HighlightDrawStyle? style,
    String? note,
  }) {
    return HighlightRule(
      name: name,
      keyword: keyword,
      pattern: pattern,
      colorHex: colorHex ?? this.colorHex,
      style: style ?? this.style,
      note: note,
      enabled: enabled,
    );
  }
}