import 'package:flutter/material.dart';

import '../../book_source/services/dict_service.dart';

/// 词典源管理。对应官方「词典」配置：增删改查 + 启用开关。
class DictManagePage extends StatefulWidget {
  const DictManagePage({super.key});

  @override
  State<DictManagePage> createState() => _DictManagePageState();
}

class _DictManagePageState extends State<DictManagePage> {
  @override
  void initState() {
    super.initState();
    DictService.instance.init();
  }

  Future<void> _edit(DictSource? existing) async {
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final urlCtrl = TextEditingController(text: existing?.url ?? '');
    final ruleCtrl = TextEditingController(text: existing?.rule ?? '');
    var method = existing?.method ?? 'GET';
    var enabled = existing?.enabled ?? true;

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          title: Text(existing == null ? '添加词典源' : '编辑词典源'),
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
                  controller: urlCtrl,
                  decoration: const InputDecoration(
                    labelText: '查询地址',
                    hintText: 'https://...?w={word}',
                  ),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: method,
                  decoration: const InputDecoration(labelText: '方法'),
                  items: const [
                    DropdownMenuItem(value: 'GET', child: Text('GET')),
                    DropdownMenuItem(value: 'POST', child: Text('POST')),
                  ],
                  onChanged: (v) => setDialog(() => method = v ?? 'GET'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: ruleCtrl,
                  decoration: const InputDecoration(
                    labelText: '释义提取规则（CSS/XPath/JSONPath 等）',
                    hintText: '留空返回整页正文',
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
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
    DictService.instance.addSource(DictSource(
      name: nameCtrl.text.trim(),
      url: urlCtrl.text.trim(),
      method: method,
      rule: ruleCtrl.text.trim(),
      enabled: enabled,
    ));
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final svc = DictService.instance;
    final sources = svc.sources;
    return Scaffold(
      appBar: AppBar(title: const Text('词典')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(null),
        icon: const Icon(Icons.add),
        label: const Text('添加词典源'),
      ),
      body: sources.isEmpty
          ? const Center(child: Text('暂无词典源，点击右下角添加'))
          : ListView.builder(
              itemCount: sources.length,
              itemBuilder: (_, i) {
                final s = sources[i];
                return ListTile(
                  leading: const Icon(Icons.menu_book_outlined),
                  title: Text(s.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(s.url, maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: Switch(
                    value: s.enabled,
                    onChanged: (v) {
                      s.enabled = v;
                      svc.save();
                      setState(() {});
                    },
                  ),
                  onTap: () => _edit(s),
                );
              },
            ),
    );
  }
}