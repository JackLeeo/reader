// 添加书源页
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../services/book_source_service.dart';
import '../../utils/extensions.dart';
import '../../utils/log.dart';

class AddSourcePage extends StatefulWidget {
  const AddSourcePage({super.key});

  @override
  State<AddSourcePage> createState() => _AddSourcePageState();
}

class _AddSourcePageState extends State<AddSourcePage> {
  final _urlController = TextEditingController();
  final _jsonController = TextEditingController();
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _loadFromClipboard();
  }

  Future<void> _loadFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text ?? '';
    final t = text.trim();
    if (t.startsWith('http')) {
      _urlController.text = t;
    } else if (t.startsWith('[') || t.startsWith('{')) {
      _jsonController.text = t;
    }
  }

  @override
  void dispose() {
    _urlController.dispose();
    _jsonController.dispose();
    super.dispose();
  }

  Future<void> _addFromUrl() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;
    setState(() => _loading = true);
    try {
      final added = await context.read<BookSourceService>().addFromUrl(url);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('成功添加 $added 个书源')),
      );
      Navigator.pop(context);
    } catch (e, st) {
      Log.e('添加失败', error: e, stack: st);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('添加失败: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _addFromJson() async {
    final text = _jsonController.text.trim();
    if (text.isEmpty) return;
    setState(() => _loading = true);
    try {
      final added = await context.read<BookSourceService>().addFromJsonText(text);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('成功添加 $added 个书源')),
      );
      Navigator.pop(context);
    } catch (e, st) {
      Log.e('解析失败', error: e, stack: st);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('解析失败: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('导入书源'),
        actions: [
          IconButton(
            icon: const Icon(Icons.paste),
            tooltip: '粘贴剪贴板',
            onPressed: _loadFromClipboard,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('方式一: 远程URL', style: context.textStyles.titleMedium),
          const SizedBox(height: 8),
          TextField(
            controller: _urlController,
            decoration: const InputDecoration(
              hintText: 'https://example.com/sources.json',
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.url,
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _loading ? null : _addFromUrl,
            icon: const Icon(Icons.cloud_download),
            label: const Text('下载并导入'),
          ),
          const Divider(height: 32),
          Text('方式二: 粘贴JSON', style: context.textStyles.titleMedium),
          const SizedBox(height: 8),
          TextField(
            controller: _jsonController,
            maxLines: 8,
            decoration: const InputDecoration(
              hintText: '粘贴Legado格式的书源JSON...',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _loading ? null : _addFromJson,
            icon: const Icon(Icons.add),
            label: const Text('导入JSON'),
          ),
          if (_loading) ...[
            const SizedBox(height: 16),
            const Center(child: CircularProgressIndicator()),
          ],
        ],
      ),
    );
  }
}
