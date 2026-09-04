import 'package:flutter/material.dart';

import '../../book_source/services/backup_service.dart';
import '../../book_source/services/webdav_service.dart';

/// WebDAV 设置 + 备份同步（对应官方「WebDAV 设置」+「备份到 WebDAV」）。
class WebDavPage extends StatefulWidget {
  const WebDavPage({super.key});

  @override
  State<WebDavPage> createState() => _WebDavPageState();
}

class _WebDavPageState extends State<WebDavPage> {
  final TextEditingController _server = TextEditingController();
  final TextEditingController _username = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final TextEditingController _dir = TextEditingController();

  bool _busy = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    final c = WebDavService.instance.config;
    _server.text = c.server;
    _username.text = c.username;
    _password.text = c.password;
    _dir.text = c.webdavDir;
  }

  @override
  void dispose() {
    _server.dispose();
    _username.dispose();
    _password.dispose();
    _dir.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    await WebDavService.instance.saveConfig(WebDavConfig(
      server: _server.text.trim(),
      username: _username.text.trim(),
      password: _password.text,
      webdavDir: _dir.text.trim().isEmpty ? '/Legado/' : _dir.text.trim(),
    ));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('配置已保存')));
  }

  Future<void> _run(Future<void> Function() task, String ok) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await task();
      if (!mounted) return;
      setState(() => _message = ok);
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = '失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _upload() {
    _run(() async {
      final name = await WebDavService.instance.uploadBackup(
        content: BackupService.instance.export(),
      );
      if (mounted) setState(() => _message = '已上传：$name');
    }, '上传成功');
  }

  void _download() {
    _run(() async {
      final content = await WebDavService.instance.downloadLatest();
      if (content == null) {
        if (mounted) setState(() => _message = '远端暂无备份');
        return;
      }
      final r = BackupService.instance.import(content);
      if (mounted) {
        setState(
            () => _message = '恢复成功：书源 ${r.sources} 个，书架 ${r.shelf} 本');
      }
    }, '下载成功');
  }

  @override
  Widget build(BuildContext context) {
    final configured = WebDavService.instance.isConfigured;
    return Scaffold(
      appBar: AppBar(title: const Text('WebDAV 同步')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _server,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: '服务器地址',
              hintText: 'https://dav.example.com/',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _username,
                  decoration: const InputDecoration(
                    labelText: '用户名（可选）',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _password,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: '密码（可选）',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _dir,
            decoration: const InputDecoration(
              labelText: '远端目录',
              hintText: '/Legado/',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _busy ? null : _save,
            icon: const Icon(Icons.save_outlined),
            label: const Text('保存配置'),
          ),
          const Divider(height: 32),
          Text('备份同步',
              style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: (_busy || !configured) ? null : _upload,
                  icon: const Icon(Icons.cloud_upload_outlined),
                  label: const Text('上传备份'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: (_busy || !configured) ? null : _download,
                  icon: const Icon(Icons.cloud_download_outlined),
                  label: const Text('下载恢复'),
                ),
              ),
            ],
          ),
          if (_message != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(_message!),
            ),
          if (!configured)
            const Padding(
              padding: EdgeInsets.only(top: 16),
              child: Text('请先填写服务器地址并保存配置',
                  style: TextStyle(color: Colors.orange)),
            ),
        ],
      ),
    );
  }
}
