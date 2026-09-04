import 'package:flutter/material.dart';

import '../../book_source/services/replace_rule_service.dart';

/// 替换规则管理页（对应官方「净化-替换规则」）。
///
/// 支持增删改替换规则：正则/文本、作用范围（标题/正文）、按书源限定。
class ReplaceRulePage extends StatefulWidget {
  const ReplaceRulePage({super.key});

  @override
  State<ReplaceRulePage> createState() => _ReplaceRulePageState();
}

class _ReplaceRulePageState extends State<ReplaceRulePage> {
  @override
  Widget build(BuildContext context) {
    final rules = ReplaceRuleService.instance.rules;
    return Scaffold(
      appBar: AppBar(title: const Text('替换规则')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(context),
        icon: const Icon(Icons.add),
        label: const Text('添加规则'),
      ),
      body: rules.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.find_replace_outlined, size: 64),
                  const SizedBox(height: 12),
                  const Text('暂无替换规则\n用于净化阅读正文（去广告/修正排版）'),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: () => _edit(context),
                    icon: const Icon(Icons.add),
                    label: const Text('添加规则'),
                  ),
                ],
              ),
            )
          : ListView(
              children: [
                for (final r in rules) _tile(context, r),
              ],
            ),
    );
  }

  Widget _tile(BuildContext context, ReplaceRule r) {
    return ListTile(
      leading: const Icon(Icons.find_replace_outlined),
      title: Text(r.name.isEmpty ? '(未命名)' : r.name,
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${r.isRegex ? '正则' : '文本'} · ${r.scopeTitle && r.scopeContent ? '正文+标题' : (r.scopeContent ? '正文' : '标题')}'
        '${r.sourceUrl.isEmpty ? ' · 全局' : ' · 源:${r.sourceUrl}'}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Switch(
        value: r.enabled,
        onChanged: (v) {
          setState(() {
            r.enabled = v;
            ReplaceRuleService.instance.upsert(r);
          });
        },
      ),
      onTap: () => _menu(context, r),
      onLongPress: () => _menu(context, r),
    );
  }

  void _menu(BuildContext context, ReplaceRule r) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(title: Text(r.name)),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('编辑'),
              onTap: () {
                Navigator.pop(ctx);
                _edit(context, rule: r);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('删除'),
              onTap: () {
                Navigator.pop(ctx);
                setState(() => ReplaceRuleService.instance.remove(r.name));
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _edit(BuildContext context, {ReplaceRule? rule}) async {
    final nameC = TextEditingController(text: rule?.name ?? '');
    final patternC = TextEditingController(text: rule?.pattern ?? '');
    final replC = TextEditingController(text: rule?.replacement ?? '');
    final sourceC = TextEditingController(text: rule?.sourceUrl ?? '');
    var isRegex = rule?.isRegex ?? true;
    var scopeTitle = rule?.scopeTitle ?? true;
    var scopeContent = rule?.scopeContent ?? true;

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          title: Text(rule == null ? '添加规则' : '编辑规则'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: nameC, decoration: const InputDecoration(labelText: '名称')),
                TextField(
                  controller: patternC,
                  decoration: const InputDecoration(labelText: '匹配（正则或文本）'),
                ),
                TextField(
                  controller: replC,
                  decoration: const InputDecoration(labelText: '替换为'),
                ),
                TextField(
                  controller: sourceC,
                  decoration: const InputDecoration(labelText: '限定书源 URL（留空=全局）'),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('使用正则'),
                  value: isRegex,
                  onChanged: (v) => setDialog(() => isRegex = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('作用于正文'),
                  value: scopeContent,
                  onChanged: (v) => setDialog(() => scopeContent = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('作用于标题'),
                  value: scopeTitle,
                  onChanged: (v) => setDialog(() => scopeTitle = v),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('保存')),
          ],
        ),
      ),
    );
    if (saved != true || !mounted) return;
    setState(() {
      ReplaceRuleService.instance.upsert(ReplaceRule(
        name: nameC.text.trim().isEmpty ? '规则 ${DateTime.now().millisecondsSinceEpoch}' : nameC.text.trim(),
        pattern: patternC.text,
        replacement: replC.text,
        isRegex: isRegex,
        scopeTitle: scopeTitle,
        scopeContent: scopeContent,
        sourceUrl: sourceC.text.trim(),
      ));
    });
  }
}