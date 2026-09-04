import 'package:flutter/material.dart';

import '../../book_source/services/tts_service.dart';

/// TTS 引擎管理页（对应官方「朗读设置-引擎管理」）。
///
/// 支持新增/编辑/删除/启用引擎。基础版维护引擎配置列表；
/// 实际朗读合成在桌面/真机音频链路接入后生效。
class TtsManagePage extends StatefulWidget {
  const TtsManagePage({super.key});

  @override
  State<TtsManagePage> createState() => _TtsManagePageState();
}

class _TtsManagePageState extends State<TtsManagePage> {
  @override
  Widget build(BuildContext context) {
    final engines = TtsEngineService.instance.engines;
    return Scaffold(
      appBar: AppBar(title: const Text('TTS 引擎管理')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _editEngine(context),
        icon: const Icon(Icons.add),
        label: const Text('添加引擎'),
      ),
      body: engines.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.record_voice_over_outlined, size: 64),
                  const SizedBox(height: 12),
                  const Text('暂无 TTS 引擎'),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: () => _editEngine(context),
                    icon: const Icon(Icons.add),
                    label: const Text('添加引擎'),
                  ),
                ],
              ),
            )
          : ListView(
              children: [
                RadioGroup<String>(
                  groupValue: TtsEngineService.instance.enabledEngine?.name,
                  onChanged: (value) {
                    if (value != null) {
                      TtsEngineService.instance.setEnabled(value, true);
                      setState(() {});
                    }
                  },
                  child: Column(
                    children: [
                      for (final e in engines) _engineTile(e),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  Widget _engineTile(TtsEngine e) {
    return ListTile(
      leading: Radio<String>(value: e.name),
      title: Text(e.name),
      subtitle: Text(e.url, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: PopupMenuButton<String>(
        onSelected: (v) {
          if (v == 'edit') _editEngine(context, engine: e);
          if (v == 'delete') {
            TtsEngineService.instance.remove(e.name);
            setState(() {});
          }
        },
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'edit', child: Text('编辑')),
          PopupMenuItem(value: 'delete', child: Text('删除')),
        ],
      ),
    );
  }

  Future<void> _editEngine(BuildContext context, {TtsEngine? engine}) async {
    final nameC = TextEditingController(text: engine?.name ?? '');
    final urlC = TextEditingController(text: engine?.url ?? '');
    final paramC = TextEditingController(text: engine?.param ?? '');
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(engine == null ? '添加引擎' : '编辑引擎'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameC,
              decoration: const InputDecoration(labelText: '名称'),
            ),
            TextField(
              controller: urlC,
              decoration: const InputDecoration(labelText: 'URL'),
            ),
            TextField(
              controller: paramC,
              decoration: const InputDecoration(labelText: '参数（可选）'),
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
    if (saved != true || !mounted) return;
    final isFirst = TtsEngineService.instance.engines.isEmpty && engine == null;
    TtsEngineService.instance.upsert(TtsEngine(
      name: nameC.text.trim(),
      url: urlC.text.trim(),
      param: paramC.text.trim(),
      enabled: engine?.enabled ?? isFirst,
    ));
    setState(() {});
  }
}