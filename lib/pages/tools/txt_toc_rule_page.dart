import 'package:flutter/material.dart';

import '../../book_source/services/txt_toc_rule_service.dart';

/// TXT 目录规则管理页（对齐官方「TXT目录规则」）。
///
/// 每行规则用正则匹配章节标题，导入本地书时按启用的规则切分章节。
class TxtTocRulePage extends StatefulWidget {
  const TxtTocRulePage({super.key});

  @override
  State<TxtTocRulePage> createState() => _TxtTocRulePageState();
}

class _TxtTocRulePageState extends State<TxtTocRulePage> {
  @override
  void initState() {
    super.initState();
    TxtTocRuleService.instance.init();
  }

  Future<void> _edit([TxtTocRule? existing]) async {
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final patternCtrl =
        TextEditingController(text: existing?.patternField ?? '');
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(existing == null ? '新建目录规则' : '编辑目录规则'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(labelText: '规则名称'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: patternCtrl,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: '分章正则（匹配章节标题的一行）',
                alignLabelWithHint: true,
                hintText: r'^第\s*[零一二三四五六七八九十百千0-9]+\s*章节',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (saved != true) return;
    final name = nameCtrl.text.trim();
    final pattern = patternCtrl.text.trim();
    if (name.isEmpty || pattern.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('名称与正则不能为空')));
      return;
    }
    TxtTocRuleService.instance.upsert(TxtTocRule(
      name: name,
      patternField: pattern,
      enabled: existing?.enabled ?? true,
      defaultRule: existing?.defaultRule ?? false,
    ));
    setState(() {});
  }

  void _toggle(String name, bool value) {
    final svc = TxtTocRuleService.instance;
    final rule = svc.rules.firstWhere((r) => r.name == name);
    svc.upsert(TxtTocRule(
      name: rule.name,
      patternField: rule.patternField,
      enabled: value,
      defaultRule: rule.defaultRule,
    ));
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final rules = TxtTocRuleService.instance.rules;
    final active = TxtTocRuleService.instance.activePattern;
    return Scaffold(
      appBar: AppBar(
        title: const Text('TXT 目录规则'),
        actions: [
          if (active != null)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Center(
                child: Text('生效：${rules.firstWhere((r) => r.enabled).name}',
                    style: Theme.of(context).textTheme.labelMedium),
              ),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(),
        icon: const Icon(Icons.add),
        label: const Text('新建'),
      ),
      body: ListView(
        children: [
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text(
              '导入 TXT 时按为正则匹配的章节标题切分正文。同时启用多条时取第一条生效。',
              style: TextStyle(fontSize: 12),
            ),
          ),
          for (final rule in rules)
            ListTile(
              leading: Switch(
                value: rule.enabled,
                onChanged: (v) => _toggle(rule.name, v),
              ),
              title: Text(rule.name,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(rule.patternField,
                  maxLines: 2, overflow: TextOverflow.ellipsis),
              trailing: rule.defaultRule
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () {
                        TxtTocRuleService.instance.remove(rule.name);
                        setState(() {});
                      },
                    ),
              onTap: () => _edit(rule),
            ),
        ],
      ),
    );
  }
}