import 'package:flutter/material.dart';

import '../../book_source/services/proxy_service.dart';

/// 全局代理设置（对应官方「代理」）。
class ProxyPage extends StatefulWidget {
  const ProxyPage({super.key});

  @override
  State<ProxyPage> createState() => _ProxyPageState();
}

class _ProxyPageState extends State<ProxyPage> {
  final TextEditingController _host = TextEditingController();
  final TextEditingController _port = TextEditingController();
  final TextEditingController _username = TextEditingController();
  final TextEditingController _password = TextEditingController();
  bool _enabled = false;
  String _type = ProxyService.kTypeHttp;

  @override
  void initState() {
    super.initState();
    final p = ProxyService.instance;
    _enabled = p.enabled;
    _host.text = p.host;
    _port.text = p.port > 0 ? '${p.port}' : '';
    _type = p.type;
    _username.text = p.username;
    _password.text = p.password;
  }

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final port = int.tryParse(_port.text.trim()) ?? 0;
    if (port <= 0 || port > 65535) {
      _toast('端口无效（1-65535）');
      return;
    }
    await ProxyService.instance.save(
      enabled: _enabled,
      host: _host.text.trim(),
      port: port,
      type: _type,
      username: _username.text.trim(),
      password: _password.text,
    );
    if (!mounted) return;
    _toast(_enabled ? '代理已启用' : '已保存');
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('代理设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('启用代理'),
            subtitle: const Text('所有书源网络请求将通过该代理'),
            value: _enabled,
            onChanged: (v) => setState(() => _enabled = v),
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            initialValue: _type,
            decoration: const InputDecoration(
              labelText: '代理类型',
              border: OutlineInputBorder(),
            ),
            items: const [
              DropdownMenuItem(value: 'http', child: Text('HTTP / HTTPS')),
              DropdownMenuItem(value: 'socks5', child: Text('SOCKS5')),
            ],
            onChanged: _enabled
                ? (v) => setState(() => _type = v ?? ProxyService.kTypeHttp)
                : null,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _host,
            enabled: _enabled,
            decoration: const InputDecoration(
              labelText: '代理主机',
              hintText: '127.0.0.1 或 proxy.example.com',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _port,
            enabled: _enabled,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: '代理端口',
              hintText: '7890',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _username,
            enabled: _enabled,
            decoration: const InputDecoration(
              labelText: '用户名（认证时填）',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _password,
            enabled: _enabled,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: '密码',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.save_outlined),
            label: const Text('保存'),
          ),
          const SizedBox(height: 12),
          Text(
            '支持 HTTP/HTTPS 与 SOCKS5 代理（经 dart:io findProxy 分发）。'
            '账号密码用于 HTTP 代理认证，部分代理需在服务器端放行。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
