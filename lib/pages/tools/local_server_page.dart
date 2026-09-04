import 'package:flutter/material.dart';

import '../../book_source/services/local_server_service.dart';

/// 本地 Web 服务管理。对应官方「Web 服务」：局域网查询本机书源合辑。
class LocalServerPage extends StatefulWidget {
  const LocalServerPage({super.key});

  @override
  State<LocalServerPage> createState() => _LocalServerPageState();
}

class _LocalServerPageState extends State<LocalServerPage> {
  @override
  Widget build(BuildContext context) {
    final svc = LocalServerService.instance;
    final running = svc.running;
    return Scaffold(
      appBar: AppBar(title: const Text('本地 Web 服务')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              leading: Icon(
                running ? Icons.cloud_done : Icons.cloud_off,
                color: running ? Colors.green : null,
              ),
              title: Text(running ? '服务已开启' : '服务未开启'),
              subtitle: Text(
                running
                    ? '地址：${_addr(svc)}\n局域网内其它设备可按如上接口查询。'
                    : '开启后，同一局域网设备可通过 HTTP 接口查询书源、搜索结果、目录与正文。',
              ),
              trailing: FilledButton(
                onPressed: () async {
                  if (running) {
                    await svc.stop();
                  } else {
                    await svc.start();
                  }
                  if (mounted) setState(() {});
                },
                child: Text(running ? '停止' : '开启'),
              ),
            ),
          ),
          const SizedBox(height: 12),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 4),
            child: Text('常用接口', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          _endpoint('GET  /search?key=书名', '聚合搜索全部启用书源'),
          _endpoint('GET  /book?bookUrl=&origin=', '书籍详情'),
          _endpoint('GET  /toc?bookUrl=&origin=', '章节目录'),
          _endpoint('GET  /content?url=&origin=', '章节正文'),
          _endpoint('GET  /shelf', '书架书列表'),
          _endpoint('GET  /clock', '本机时间'),
          const SizedBox(height: 12),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 4),
            child: Text('WebSocket / MCP', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          _endpoint('WS   /ws', '实时 RPC：发送 {"id","method","params"} 调用工具'),
          _endpoint('POST /mcp', 'MCP over HTTP（JSON-RPC：initialize / tools/list / tools/call）'),
          _endpoint('GET  /tools', '查看可用工具定义'),
          const SizedBox(height: 12),
          const Text(
            '工具：search / get_book / get_toc / get_content / get_shelf / clock。'
            '仅在可信局域网使用：本服务不设鉴权，会暴露本机已配置的书源能力。',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ],
      ),
    );
  }

  String _addr(LocalServerService svc) {
    final host = svc.host ?? '127.0.0.1';
    return 'http://$host:${svc.port}/';
  }

  Widget _endpoint(String path, String desc) => ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.code, size: 18),
        title: Text(path, style: const TextStyle(fontFamily: 'monospace')),
        subtitle: Text(desc),
      );
}