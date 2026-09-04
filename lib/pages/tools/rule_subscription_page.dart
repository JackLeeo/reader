import 'package:flutter/material.dart';

import '../../book_source/services/rule_subscription_service.dart';

/// 规则订阅管理（对应官方「规则订阅」）。
class RuleSubscriptionPage extends StatefulWidget {
  const RuleSubscriptionPage({super.key});

  @override
  State<RuleSubscriptionPage> createState() => _RuleSubscriptionPageState();
}

class _RuleSubscriptionPageState extends State<RuleSubscriptionPage> {
  final TextEditingController _url = TextEditingController();

  Future<void> _add() async {
    final url = _url.text.trim();
    if (url.isEmpty) {
      _toast('请输入订阅地址');
      return;
    }
    try {
      final r = await RuleSubscriptionService.instance.fetch(url);
      if (!mounted) return;
      _url.clear();
      _toast('订阅成功：${r.message}');
    } catch (e) {
      if (!mounted) return;
      _toast('订阅失败：$e');
    }
  }

  Future<void> _refresh(RuleSubscription sub) async {
    try {
      final r = await RuleSubscriptionService.instance.fetch(sub.url);
      if (!mounted) return;
      _toast('刷新成功：${r.message}');
    } catch (e) {
      if (!mounted) return;
      _toast('刷新失败：$e');
    }
  }

  void _remove(RuleSubscription sub) {
    RuleSubscriptionService.instance.remove(sub.url);
    setState(() {});
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final items = RuleSubscriptionService.instance.items;
    return Scaffold(
      appBar: AppBar(title: const Text('规则订阅')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('添加订阅',
              style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _url,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    hintText: 'https://example.com/booksource.json',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: _add,
                icon: const Icon(Icons.add),
                label: const Text('订阅'),
              ),
            ],
          ),
          const Divider(height: 32),
          if (items.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: Text('暂无订阅')),
            )
          else
            for (final sub in items)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.rss_feed),
                title: Text(sub.name.isEmpty ? sub.url : sub.name,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(
                  sub.lastFetchTime > 0
                      ? '上次同步 ${_fmtTime(sub.lastFetchTime)}'
                      : '尚未同步',
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.refresh),
                      tooltip: '刷新',
                      onPressed: () => _refresh(sub),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline),
                      tooltip: '删除',
                      onPressed: () => _remove(sub),
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }

  static String _fmtTime(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    if (d.year == now.year && d.month == now.month && d.day == now.day) {
      return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    }
    return '${d.month}/${d.day}';
  }
}
