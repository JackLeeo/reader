// 书源管理页
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/book_source.dart';
import '../../services/book_source_service.dart';
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
}

class _SourceTile extends StatelessWidget {
  final BookSource source;
  const _SourceTile({required this.source});

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      title: Text(source.bookSourceName),
      subtitle: Text(
        source.bookSourceUrl,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: context.textStyles.bodySmall?.copyWith(
              color: context.colors.onSurfaceVariant,
            ),
      ),
      secondary: IconButton(
        icon: const Icon(Icons.copy, size: 18),
        onPressed: () {
          Clipboard.setData(ClipboardData(text: source.bookSourceUrl));
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('已复制书源地址'),
              duration: Duration(seconds: 2),
            ),
          );
        },
      ),
      value: source.isEnabled,
      onChanged: (v) {
        context.read<BookSourceService>().toggleSource(source.id, v);
      },
    );
  }
}
