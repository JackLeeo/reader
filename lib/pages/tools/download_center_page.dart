import 'package:flutter/material.dart';

import '../../book_source/services/download_queue_service.dart';

/// 下载中心。对应官方「下载任务」队列：展示排队/下载中/暂停/完成的书本批量任务，
/// 支持逐个暂停/恢复/移除与清空已完成。
class DownloadCenterPage extends StatefulWidget {
  const DownloadCenterPage({super.key});

  @override
  State<DownloadCenterPage> createState() => _DownloadCenterPageState();
}

class _DownloadCenterPageState extends State<DownloadCenterPage> {
  final DownloadQueueService _q = DownloadQueueService.instance;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('下载中心'),
        actions: [
          IconButton(
            tooltip: '清空已完成',
            onPressed: () {
              _q.clearFinished();
            },
            icon: const Icon(Icons.clear_all),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: _q,
        builder: (_, _) {
          final items = _q.items;
          if (items.isEmpty) {
            return const Center(child: Text('暂无下载任务'));
          }
          return ListView.separated(
            itemCount: items.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (_, i) => _buildTile(items[i]),
          );
        },
      ),
    );
  }

  Widget _buildTile(DownloadTask task) {
    final progress = task.totalCount == 0
        ? '0%'
        : '${(task.done * 100 ~/ task.totalCount)}%';
    return ListTile(
      leading: const Icon(Icons.menu_book_outlined),
      title: Text(task.book.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: LinearProgressIndicator(
                  value: task.totalCount == 0
                      ? 0
                      : (task.done / task.totalCount).clamp(0.0, 1.0),
                ),
              ),
              const SizedBox(width: 8),
              Text('$progress  ${_statusText(task.status)}',
                  style: Theme.of(context).textTheme.labelSmall),
            ],
          ),
          if (task.error != null)
            Text('失败：${task.error}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.error, fontSize: 12)),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _actionFor(task),
          IconButton(
            tooltip: '移除',
            onPressed: () => _q.remove(task),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
      isThreeLine: task.error != null,
    );
  }

  Widget _actionFor(DownloadTask task) {
    switch (task.status) {
      case DownloadStatus.downloading:
        return IconButton(
          tooltip: '暂停',
          onPressed: () => _q.pause(task),
          icon: const Icon(Icons.pause_circle_outline),
        );
      case DownloadStatus.paused:
        return IconButton(
          tooltip: '继续',
          onPressed: () => _q.resume(task),
          icon: const Icon(Icons.play_circle_outline),
        );
      case DownloadStatus.waiting:
        return IconButton(
          tooltip: '暂停',
          onPressed: () => _q.pause(task),
          icon: const Icon(Icons.pause_circle_outline),
        );
      case DownloadStatus.error:
        return IconButton(
          tooltip: '重试',
          onPressed: () => _q.resume(task),
          icon: const Icon(Icons.replay),
        );
      case DownloadStatus.done:
        return Icon(
          Icons.check_circle_outline,
          color: Colors.green,
        );
    }
  }

  String _statusText(DownloadStatus s) {
    switch (s) {
      case DownloadStatus.waiting:
        return '排队中';
      case DownloadStatus.downloading:
        return '下载中';
      case DownloadStatus.paused:
        return '已暂停';
      case DownloadStatus.done:
        return '已完成';
      case DownloadStatus.error:
        return '出错';
    }
  }
}