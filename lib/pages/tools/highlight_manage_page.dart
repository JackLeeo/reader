import 'package:flutter/material.dart';

import '../../book_source/services/highlight_service.dart';

/// 正文高亮规则管理。对应官方「高亮规则」：增删改查 + 颜色 + 关键字/正则。
class HighlightManagePage extends StatefulWidget {
  const HighlightManagePage({super.key});

  @override
  State<HighlightManagePage> createState() => _HighlightManagePageState();
}

class _HighlightManagePageState extends State<HighlightManagePage> {
  @override
  void initState() {
    super.initState();
    HighlightService.instance.init();
  }

  Future<void> _edit(HighlightRule? existing) async {
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final kwCtrl = TextEditingController(text: existing?.keyword ?? '');
    final patCtrl = TextEditingController(text: existing?.pattern ?? '');
    final noteCtrl = TextEditingController(text: existing?.note ?? '');
    var color = _parseColor(existing?.colorHex ?? '#FFFF00');
    var style = existing?.style ?? HighlightDrawStyle.highlight;
    var enabled = existing?.enabled ?? true;

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          title: Text(existing == null ? '添加高亮' : '编辑高亮'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(labelText: '名称'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: kwCtrl,
                  decoration: const InputDecoration(
                    labelText: '关键词（精确匹配）',
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: patCtrl,
                  decoration: const InputDecoration(
                    labelText: '自定义正则（优先于关键词）',
                    hintText: '可选，如 \\bWord\\b',
                  ),
                ),
                const SizedBox(height: 8),
                InkWell(
                  onTap: () async {
                    final picked = await showDialog<Color>(
                      context: ctx,
                      builder: (_) => SimpleDialog(
                        title: const Text('高亮颜色'),
                        children: [
                          for (final c in _kColors)
                            SimpleDialogOption(
                              child: Row(
                                children: [
                                  Container(
                                    width: 20,
                                    height: 20,
                                    color: c,
                                    margin: const EdgeInsets.only(right: 8),
                                  ),
                                  Text(_hex(c)),
                                ],
                              ),
                              onPressed: () => Navigator.pop(ctx, c),
                            ),
                        ],
                      ),
                    );
                    if (picked != null) setDialog(() => color = picked);
                  },
                  child: Row(
                    children: [
                      Container(
                        width: 24,
                        height: 24,
                        color: color,
                        margin: const EdgeInsets.only(right: 8),
                      ),
                      Text('颜色：${_hex(color)}'),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                const Text('样式'),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final (label, s) in const [
                      ('高亮', HighlightDrawStyle.highlight),
                      ('下划线', HighlightDrawStyle.underline),
                      ('删除线', HighlightDrawStyle.strikethrough),
                    ])
                      ChoiceChip(
                        label: Text(label),
                        selected: style == s,
                        onSelected: (_) => setDialog(() => style = s),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: noteCtrl,
                  decoration: const InputDecoration(
                    labelText: '笔记（可选）',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  title: const Text('启用'),
                  value: enabled,
                  onChanged: (v) => setDialog(() => enabled = v),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            FilledButton(
              onPressed: () {
                if (nameCtrl.text.trim().isEmpty) return;
                Navigator.pop(ctx, true);
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (saved != true || !mounted) return;
    final note = noteCtrl.text.trim();
    HighlightService.instance.addRule(HighlightRule(
      name: nameCtrl.text.trim(),
      keyword: kwCtrl.text.trim(),
      pattern: patCtrl.text.trim(),
      colorHex: _hex(color),
      style: style,
      note: note.isEmpty ? null : note,
      enabled: enabled,
    ));
    setState(() {});
  }

  static const _kColors = <Color>[
    Color(0xFFFFEB3B),
    Color(0xFFFF9800),
    Color(0xFFF44336),
    Color(0xFF4CAF50),
    Color(0xFF2196F3),
    Color(0xFF9C27B0),
  ];

  static Color _parseColor(String hex) {
    try {
      return Color(int.parse(hex.replaceFirst('#', '0xFF')));
    } catch (_) {
      return const Color(0xFFFFEB3B);
    }
  }

  static String _hex(Color c) =>
      '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

  @override
  Widget build(BuildContext context) {
    final svc = HighlightService.instance;
    final rules = svc.rules;
    return Scaffold(
      appBar: AppBar(title: const Text('正文高亮')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(null),
        icon: const Icon(Icons.add),
        label: const Text('添加高亮'),
      ),
      body: rules.isEmpty
          ? const Center(child: Text('暂无高亮规则，点击右下角添加'))
          : ListView.builder(
              itemCount: rules.length,
              itemBuilder: (_, i) {
                final r = rules[i];
                return ListTile(
                  leading: Icon(
                    Icons.format_color_fill,
                    color: _parseColor(r.colorHex),
                  ),
                  title: Text(r.name,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text([
                  if (r.pattern.isNotEmpty) '正则：${r.pattern}',
                  if (r.pattern.isEmpty) '关键词：${r.keyword}',
                  if (r.note != null && r.note!.isNotEmpty) '笔记：${r.note}',
                ].join('，')),
                  trailing: Switch(
                    value: r.enabled,
                    onChanged: (v) {
                      r.enabled = v;
                      svc.save();
                      setState(() {});
                    },
                  ),
                  onTap: () => _edit(r),
                );
              },
            ),
    );
  }
}