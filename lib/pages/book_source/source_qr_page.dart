import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../book_source/models/book_source.dart';
import '../../book_source/services/book_source_service.dart';
import '../../book_source/utils/source_import_parser.dart';
import '../../book_source/utils/source_sharer.dart';
import '../tools/source_import_page.dart';
import '../tools/source_import_preview.dart';

/// 书源二维码。对应官方 `ui/qrcode`：把单个/多个书源编码成二维码分享，
/// 或用相机扫码 / 粘贴文本导入。
class SourceQrPage extends StatefulWidget {
  const SourceQrPage({super.key});

  @override
  State<SourceQrPage> createState() => _SourceQrPageState();
}

class _SourceQrPageState extends State<SourceQrPage> {
  void _importText(String text) {
    final t = text.trim();
    if (t.isEmpty) return;
    // 口令加密串：先请求口令解密再解析。
    if (SourceSharer.isEncrypted(t)) {
      _promptPassword(t);
      return;
    }
    final parsed = SourceImportParser.parse(t);
    if (parsed.isEmpty) {
      _toast('未能从输入解析到书源');
      return;
    }
    _runPreview(parsed);
  }

  /// 针对口令加密串弹出口令输入框。
  Future<void> _promptPassword(String payload) async {
    final controller = TextEditingController();
    final password = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('口令书源'),
        content: TextField(
          controller: controller,
          obscureText: true,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '请输入分享口令',
            suffixIcon: Icon(Icons.lock_outline),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (password == null || password.isEmpty || !mounted) return;
    final parsed = SourceImportParser.parseWithPassword(payload, password);
    if (parsed == null) {
      _toast('口令错误，无法解密');
      return;
    }
    if (parsed.isEmpty) {
      _toast('口令正确但未能解析到书源');
      return;
    }
    _runPreview(parsed);
  }

  /// 弹出口令输入框，确认后返回加密串（用于生成分享二维码）。
  Future<String?> _promptSharePassword() async {
    final controller = TextEditingController();
    final password = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('口令加密分享'),
        content: TextField(
          controller: controller,
          obscureText: true,
          decoration: const InputDecoration(hintText: '设置分享口令'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('生成'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (password == null || password.trim().isEmpty) return null;
    return password.trim();
  }

  Future<void> _runPreview(List<BookSource> parsed) async {
    final n = await SourceImportPreview.show(context, parsed);
    if (n == null) return;
    if (!mounted) return;
    _toast('已导入/更新 $n 个书源');
    setState(() {});
  }

  Future<void> _goImportPage() async {
    final result = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const SourceImportPage()),
    );
    if (result != null && result.trim().isNotEmpty && mounted) {
      _importText(result);
    }
  }

  void _toast(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(m), duration: const Duration(milliseconds: 1200)));
  }

  @override
  Widget build(BuildContext context) {
    final sources = BookSourceService.instance.sources;
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('书源二维码'),
          bottom: const TabBar(
            tabs: [
              Tab(text: '生成'),
              Tab(icon: Icon(Icons.qr_code_scanner), text: '扫码'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _buildGenerate(sources),
            _buildScan(sources.isEmpty),
          ],
        ),
      ),
    );
  }

  Widget _buildGenerate(List<BookSource> sources) {
    return ListView(
      children: [
        const Padding(
          padding: EdgeInsets.all(8),
          child: Text('选择一个书源生成二维码，供其它设备扫码导入（也可复制文本）。'),
        ),
        for (final s in sources)
          ListTile(
            dense: true,
            title: Text(s.bookSourceName,
                maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(s.bookSourceUrl,
                maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: const Icon(Icons.qr_code),
            onTap: () => _showShareOptions(_singlePayload(s)),
          ),
        ListTile(
          leading: const Icon(Icons.paste),
          title: const Text('粘贴导入'),
          trailing: const Icon(Icons.chevron_right),
          onTap: _goImportPage,
        ),
      ],
    );
  }

  String _singlePayload(BookSource s) =>
      jsonEncode(s.toJson());

  /// 提供「普通分享 QR」「口令加密分享 QR」两种方式。
  Future<void> _showShareOptions(String payload) async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.qr_code),
              title: const Text('生成普通二维码'),
              onTap: () {
                Navigator.pop(ctx);
                _showQr(payload, encrypted: false);
              },
            ),
            ListTile(
              leading: const Icon(Icons.lock_outline),
              title: const Text('口令加密生成二维码'),
              subtitle: const Text('对方需输入同一口令才能导入'),
              onTap: () async {
                Navigator.pop(ctx);
                final pw = await _promptSharePassword();
                if (pw == null || !mounted) return;
                _showQr(SourceSharer.encrypt(payload, pw), encrypted: true);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showQr(String payload, {required bool encrypted}) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              QrImageView(
                data: payload,
                version: QrVersions.auto,
                size: 260,
                backgroundColor: Colors.white,
              ),
              const SizedBox(height: 12),
              TextButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: payload));
                  _toast('已复制书源文本');
                },
                icon: const Icon(Icons.copy),
                label: const Text('复制文本'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildScan(bool empty) {
    if (empty) {
      return const Center(child: Text('请在书源管理中添加书源后再扫码'));
    }
    return MobileScanner(
      onDetect: (capture) {
        for (final b in capture.barcodes) {
          final raw = b.rawValue;
          if (raw != null && raw.isNotEmpty) {
            _importText(raw);
            return;
          }
        }
      },
    );
  }
}