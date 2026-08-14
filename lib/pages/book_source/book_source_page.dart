// 书源管理页
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/book_source.dart';
import '../../services/book_source_service.dart';
import '../../services/settings_service.dart';
import '../../services/source_health_service.dart';
import '../../utils/extensions.dart';
import '../../widgets/empty_state.dart';
import 'add_source_page.dart';

class BookSourcePage extends StatelessWidget {
  const BookSourcePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('书源管理'),
        centerTitle: false,
        actions: [
          Consumer<SourceHealthService>(
            builder: (context, health, _) {
              if (health.isChecking) {
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Center(
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        value: health.totalCount == 0
                            ? null
                            : health.checkedCount / health.totalCount,
                      ),
                    ),
                  ),
                );
              }
              return IconButton(
                icon: const Icon(Icons.network_check),
                tooltip: '重新检测全部',
                onPressed: () => _runCheckAll(context),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.add_link),
            tooltip: '导入',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const AddSourcePage()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.check_circle_outline),
            tooltip: '全部启用',
            onPressed: () => context.read<BookSourceService>().enableAll(),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Consumer<BookSourceService>(
          builder: (context, svc, _) {
            if (svc.sources.isEmpty) return const SizedBox.shrink();
            final disabledCount =
                svc.sources.where((s) => !s.isEnabled).length;
            if (disabledCount == 0) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Row(
                children: [
                  Icon(Icons.info_outline,
                      size: 16, color: context.colors.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '已禁用 $disabledCount 个书源',
                      style: context.textStyles.bodySmall?.copyWith(
                            color: context.colors.onSurfaceVariant,
                          ),
                    ),
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('重新启用'),
                    onPressed: () async {
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: const Text('重新启用所有书源'),
                          content: const Text(
                              '将启用所有被禁用的书源, 包括检测失效的源'),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, false),
                              child: const Text('取消'),
                            ),
                            FilledButton(
                              onPressed: () => Navigator.pop(ctx, true),
                              child: const Text('启用'),
                            ),
                          ],
                        ),
                      );
                      if (ok == true) {
                        await svc.enableAll();
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('已启用所有书源'),
                            duration: Duration(seconds: 2),
                          ),
                        );
                      }
                    },
                  ),
                ],
              ),
            );
          },
        ),
      ),
      body: Consumer<BookSourceService>(
        builder: (context, svc, _) {
          if (svc.sources.isEmpty) {
            return EmptyState(
              icon: Icons.source_outlined,
              message: '暂无书源',
              action: FilledButton.icon(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const AddSourcePage()),
                ),
                icon: const Icon(Icons.add),
                label: const Text('导入书源'),
              ),
            );
          }

          // 按分组归类
          final grouped = <String, List<BookSource>>{};
          for (final s in svc.sources) {
            final g = s.bookSourceGroup.isEmpty ? '默认' : s.bookSourceGroup;
            grouped.putIfAbsent(g, () => []).add(s);
          }
          final groups = grouped.keys.toList()..sort();

          return ListView.builder(
            padding: const EdgeInsets.only(bottom: 80),
            itemCount: groups.length,
            itemBuilder: (context, gi) {
              final group = groups[gi];
              final items = grouped[group]!;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                    child: Text(
                      group,
                      style: context.textStyles.labelMedium?.copyWith(
                            color: context.colors.primary,
                          ),
                    ),
                  ),
                  for (final src in items) _SourceTile(source: src),
                ],
              );
            },
          );
        },
      ),
    );
  }

  void _runCheckAll(BuildContext context) {
    final settings = context.read<SettingsService>();
    context.read<SourceHealthService>().checkAll(
          autoDisableWhenFail: settings.invalidAutoDisable,
        );
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('开始检测全部书源...'),
        duration: Duration(seconds: 2),
      ),
    );
  }
}

class _SourceTile extends StatelessWidget {
  final BookSource source;
  const _SourceTile({required this.source});

  @override
  Widget build(BuildContext context) {
    return Consumer<SourceHealthService>(
      builder: (context, health, _) {
        return SwitchListTile(
          title: Row(
            children: [
              Expanded(
                child: Text(
                  source.bookSourceName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              _HealthBadge(status: source.healthStatus, error: source.healthError),
            ],
          ),
          subtitle: Text(
            source.bookSourceUrl,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.textStyles.bodySmall?.copyWith(
                  color: context.colors.onSurfaceVariant,
                ),
          ),
          secondary: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.refresh, size: 18),
                tooltip: '重新检测',
                onPressed: health.isChecking
                    ? null
                    : () async {
                        final r =
                            await health.recheckOne(source);
                        if (!context.mounted) return;
                        final msg = r.ok
                            ? '正常 (${r.statusCode})'
                            : '失效: ${r.error ?? "?"}';
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('${source.bookSourceName} - $msg'),
                            duration: const Duration(seconds: 2),
                          ),
                        );
                      },
              ),
              IconButton(
                icon: const Icon(Icons.copy, size: 18),
                tooltip: '复制地址',
                onPressed: () {
                  Clipboard.setData(
                      ClipboardData(text: source.bookSourceUrl));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('已复制书源地址'),
                      duration: Duration(seconds: 2),
                    ),
                  );
                },
              ),
            ],
          ),
          value: source.isEnabled,
          onChanged: (v) {
            context.read<BookSourceService>().toggleSource(source.id, v);
          },
        );
      },
    );
  }
}

/// 书源健康状态徽标
class _HealthBadge extends StatelessWidget {
  final int status; // 0=未检测, 1=正常, 2=失效
  final String? error;
  const _HealthBadge({required this.status, this.error});

  @override
  Widget build(BuildContext context) {
    Color color;
    IconData icon;
    String text;
    switch (status) {
      case 1:
        color = Colors.green;
        icon = Icons.check_circle;
        text = '正常';
        break;
      case 2:
        color = Colors.red;
        icon = Icons.error;
        text = '失效';
        break;
      default:
        color = Colors.grey;
        icon = Icons.help_outline;
        text = '待检测';
    }
    return Tooltip(
      message: error ?? text,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: color.withValues(alpha: 0.4), width: 0.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12, color: color),
            const SizedBox(width: 3),
            Text(
              text,
              style: TextStyle(fontSize: 11, color: color),
            ),
          ],
        ),
      ),
    );
  }
}
