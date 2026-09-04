import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../book_source/services/backup_service.dart';
import 'webdav_page.dart';

/// 数据管理页（对应官方「备份与恢复」）。
///
/// 支持：复制到剪贴板、保存到本地文件、从剪贴板/本地文件恢复，以及 WebDAV 云同步。
class BackupPage extends StatefulWidget {
  const BackupPage({super.key});

  @override
  State<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends State<BackupPage> {
  final TextEditingController _importController = TextEditingController();

  static const XTypeGroup _jsonType = XTypeGroup(
    label: 'json',
    extensions: ['json'],
    uniformTypeIdentifiers: ['public.json'],
  );

  @override
  void dispose() {
    _importController.dispose();
    super.dispose();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _export() async {
    await Clipboard.setData(
        ClipboardData(text: BackupService.instance.export()));
    _toast('备份已复制到剪贴板');
  }

  Future<void> _exportFile() async {
    final json = BackupService.instance.export();
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final dest = await getSaveLocation(
      suggestedName: 'legado_backup_$stamp.json',
      acceptedTypeGroups: const [_jsonType],
    );
    if (dest == null) return;
    await File(dest.path).writeAsString(json, flush: true);
    if (!mounted) return;
    _toast('已保存到 ${dest.path}');
  }

  Future<void> _importFile() async {
    final file = await openFile(acceptedTypeGroups: const [_jsonType]);
    if (file == null) return;
    final text = await file.readAsString();
    _restore(text);
  }

  void _import() {
    final text = _importController.text.trim();
    if (text.isEmpty) {
      _toast('请先粘贴备份内容');
      return;
    }
    _restore(text);
  }

  void _restore(String text) {
    try {
      final r = BackupService.instance.import(text);
      _importController.clear();
      _toast('恢复成功：书源 ${r.sources} 个，书架 ${r.shelf} 本');
    } catch (e) {
      _toast('恢复失败：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('备份与恢复')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          FilledButton.icon(
            onPressed: _export,
            icon: const Icon(Icons.copy_outlined),
            label: const Text('导出备份（复制到剪贴板）'),
          ),
          const SizedBox(height: 8),
          FilledButton.tonalIcon(
            onPressed: _exportFile,
            icon: const Icon(Icons.save_alt_outlined),
            label: const Text('保存备份到本地文件'),
          ),
          const Divider(height: 24),
          Text('从内容恢复',
              style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          TextField(
            controller: _importController,
            maxLines: 8,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: '粘贴备份 JSON',
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: _import,
                  icon: const Icon(Icons.download_outlined),
                  label: const Text('从粘贴恢复'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: _importFile,
                  icon: const Icon(Icons.folder_open_outlined),
                  label: const Text('从本地文件恢复'),
                ),
              ),
            ],
          ),
          const Divider(height: 32),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.cloud_outlined),
            title: const Text('WebDAV 云同步'),
            subtitle: const Text('配置 WebDAV 服务器，上传/下载备份'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const WebDavPage()),
            ),
          ),
        ],
      ),
    );
  }
}