import 'package:flutter/material.dart';

import '../../book_source/services/auto_task_service.dart';

/// 自动任务管理。对应官方「自动任务」：启用/间隔/动作/立即执行。
class AutoTaskPage extends StatefulWidget {
  const AutoTaskPage({super.key});

  @override
  State<AutoTaskPage> createState() => _AutoTaskPageState();
}

class _AutoTaskPageState extends State<AutoTaskPage> {
  String _lastTick = '';

  @override
  void initState() {
    super.initState();
    AutoTaskService.instance.init();
  }

  Future<void> _add() async {
    final nameCtrl = TextEditingController();
    final scriptCtrl = TextEditingController();
    final cronCtrl = TextEditingController();
    var interval = 60;
    var action = 'refresh_rss';

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          title: const Text('添加任务'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(labelText: '名称'),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: action,
                  decoration: const InputDecoration(labelText: '动作'),
                  items: const [
                    DropdownMenuItem(
                        value: 'refresh_rss', child: Text('刷新全部 RSS')),
                    DropdownMenuItem(
                        value: 'check_shelf', child: Text('检测书架新章节')),
                    DropdownMenuItem(
                        value: 'run_js', child: Text('执行 JS 脚本')),
                    DropdownMenuItem(
                        value: 'notify', child: Text('占位（无操作）')),
                  ],
                  onChanged: (v) =>
                      setDialog(() => action = v ?? 'refresh_rss'),
                ),
                if (action == 'run_js') ...[
                  const SizedBox(height: 8),
                  TextField(
                    controller: scriptCtrl,
                    maxLines: 6,
                    decoration: const InputDecoration(
                      labelText: 'JS 脚本',
                      hintText: r'例如：$api.http({url:"https://..."})',
                      border: OutlineInputBorder(),
                      alignLabelWithHint: true,
                    ),
                  ),
                ],
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('间隔（分钟）'),
                  trailing: SizedBox(
                    width: 120,
                    child: TextField(
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(isDense: true),
                      controller: TextEditingController(text: '$interval'),
                      onChanged: (v) =>
                          setDialog(() => interval = int.tryParse(v) ?? 60),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                TextField(
                  controller: cronCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Cron（可选，留空按间隔执行）',
                    hintText: '分 时 日 月 周，如：0 8 * * *',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: (v) => setDialog(() {}),
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
    AutoTaskService.instance.addTask(AutoTask(
      name: nameCtrl.text.trim(),
      intervalMin: interval,
      action: action,
      script: action == 'run_js' ? scriptCtrl.text.trim() : null,
      cron: cronCtrl.text.trim().isEmpty ? null : cronCtrl.text.trim(),
    ));
    setState(() {});
  }

  Future<void> _runNow(AutoTask task) async {
    await AutoTaskService.instance.runTask(task);
    if (!mounted) return;
    setState(() => _lastTick = '已执行：${task.name}');
  }

  @override
  Widget build(BuildContext context) {
    final tasks = AutoTaskService.instance.tasks;
    return Scaffold(
      appBar: AppBar(title: const Text('自动任务')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _add,
        icon: const Icon(Icons.add),
        label: const Text('添加任务'),
      ),
      body: tasks.isEmpty
          ? const Center(child: Text('暂无任务，点击右下角添加'))
          : ListView(
              children: [
                if (_lastTick.isNotEmpty)
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.check_circle_outline),
                    title: Text(_lastTick),
                  ),
                for (final t in tasks)
                  ListTile(
                    key: ValueKey(t.name),
                    leading: const Icon(Icons.schedule_outlined),
                    title: Text(t.name,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                      '${_actionName(t.action)} · '
                      '每 ${t.intervalMin} 分钟${t.lastRunAt == null ? '' : ' · 上次 ${_fmt(t.lastRunAt!)}'}',
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.play_circle_outline),
                          tooltip: '立即执行',
                          onPressed: () => _runNow(t),
                        ),
                        Switch(
                          value: t.enabled,
                          onChanged: (v) {
                            AutoTaskService.instance
                                .addTask(t.copyWith(enabled: v));
                            setState(() {});
                          },
                        ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }

  static String _actionName(String action) {
    switch (action) {
      case 'refresh_rss':
        return '刷新 RSS';
      case 'check_shelf':
        return '检测书架新章节';
      case 'run_js':
        return '执行 JS 脚本';
      default:
        return '占位';
    }
  }

  static String _fmt(DateTime t) {
    final l = t.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${l.month}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
  }
}