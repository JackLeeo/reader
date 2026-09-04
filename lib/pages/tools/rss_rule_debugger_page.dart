import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../book_source/services/rss_service.dart';
import '../../widgets/code_editor.dart';

/// RSS 规则调试器（对应官方「RSS 调试」）。
///
/// 输入一个自定义 RSS 规则源的字段（或从已保存源选择），实际请求抓取后用
/// [RssService.parseByRule] 逐步解析，直观查看「匹配到几条」「每条各字段
/// 提取结果」与请求/解析错误，用于调校规则。
class RssRuleDebuggerPage extends StatefulWidget {
  const RssRuleDebuggerPage({super.key});

  @override
  State<RssRuleDebuggerPage> createState() => _RssRuleDebuggerPageState();
}

class _RssRuleDebuggerPageState extends State<RssRuleDebuggerPage> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _sourceUrl = TextEditingController();
  final TextEditingController _ruleArticles = TextEditingController();
  final TextEditingController _ruleTitle = TextEditingController();
  final TextEditingController _ruleLink = TextEditingController();
  final TextEditingController _ruleDescription = TextEditingController();
  final TextEditingController _rulePubDate = TextEditingController();
  final TextEditingController _ruleImage = TextEditingController();

  bool _running = false;
  String? _error;
  List<RssItem>? _items;

  @override
  void initState() {
    super.initState();
    // 默认加载第一个规则源（如有）。
    final src = RssService.instance.sources.isNotEmpty
        ? RssService.instance.sources.first
        : null;
    if (src != null) _fill(src);
  }

  void _fill(RssSource src) {
    _name.text = src.name;
    _sourceUrl.text = src.sourceUrl;
    _ruleArticles.text = src.ruleArticles;
    _ruleTitle.text = src.ruleTitle;
    _ruleLink.text = src.ruleLink;
    _ruleDescription.text = src.ruleDescription;
    _rulePubDate.text = src.rulePubDate;
    _ruleImage.text = src.ruleImage;
  }

  void _loadSaved() {
    final sources = RssService.instance.sources;
    if (sources.isEmpty) {
      _toast('暂无已保存的规则源');
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          children: [
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('选择规则源加载',
                  style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            for (final s in sources)
              ListTile(
                title: Text(s.name),
                subtitle: Text(s.sourceUrl,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                onTap: () {
                  Navigator.pop(ctx);
                  setState(() => _fill(s));
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _saveSource() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      _toast('请先填写规则源名称');
      return;
    }
    RssService.instance.addSource(_buildSource());
    await RssService.instance.save();
    _toast('已保存规则源「$name」');
  }

  RssSource _buildSource() => RssSource(
        name: _name.text.trim(),
        sourceUrl: _sourceUrl.text.trim(),
        ruleArticles: _ruleArticles.text.trim(),
        ruleTitle: _ruleTitle.text.trim(),
        ruleLink: _ruleLink.text.trim(),
        ruleDescription: _ruleDescription.text.trim(),
        rulePubDate: _rulePubDate.text.trim(),
        ruleImage: _ruleImage.text.trim(),
      );

  Future<void> _run() async {
    final url = _sourceUrl.text.trim();
    if (url.isEmpty) {
      setState(() => _error = '请填写规则源地址 sourceUrl');
      return;
    }
    setState(() {
      _running = true;
      _error = null;
      _items = null;
    });
    try {
      final resp = await http.get(Uri.parse(url));
      if (resp.statusCode != 200) {
        setState(() {
          _running = false;
          _error = 'HTTP ${resp.statusCode}';
        });
        return;
      }
      final items = await RssService.instance.parseByRule(resp.body, _buildSource());
      if (!mounted) return;
      setState(() {
        _running = false;
        _items = items;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _running = false;
        _error = '请求/解析出错：$e';
      });
    }
  }

  void _toast(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(m), duration: const Duration(milliseconds: 1200)));
  }

  @override
  void dispose() {
    for (final c in [
      _name, _sourceUrl, _ruleArticles, _ruleTitle, _ruleLink,
      _ruleDescription, _rulePubDate, _ruleImage,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('RSS 规则调试器'),
        actions: [
          IconButton(
            icon: const Icon(Icons.folder_open),
            tooltip: '加载已保存规则源',
            onPressed: _loadSaved,
          ),
          IconButton(
            icon: const Icon(Icons.save_outlined),
            tooltip: '保存规则源',
            onPressed: _saveSource,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _name,
            decoration: const InputDecoration(
              labelText: '规则源名称',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _sourceUrl,
            decoration: const InputDecoration(
              labelText: '规则源地址（sourceUrl）',
              border: OutlineInputBorder(),
              hintText: 'https://example.com/feed.php',
            ),
          ),
          const SizedBox(height: 12),
          const Text('文章列表规则（ruleArticles，必填）',
              style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          CodeEditor(
            controller: _ruleArticles,
            mode: CodeMode.none,
            minLines: 3,
            hintText: '如 class.item',
          ),
          const SizedBox(height: 12),
          _ruleField(_ruleTitle, '标题规则（ruleTitle）', '@className / .title 等'),
          _ruleField(_ruleLink, '链接规则（ruleLink）', '@href 等'),
          _ruleField(_ruleDescription, '摘要规则（ruleDescription）', '可选'),
          _ruleField(_rulePubDate, '时间规则（rulePubDate）', '可选'),
          _ruleField(_ruleImage, '图片规则（ruleImage）', '可选'),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _running ? null : _run,
            icon: _running
                ? const SizedBox(
                    width: 16, height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.play_arrow),
            label: Text(_running ? '运行中…' : '开始调试'),
          ),
          const SizedBox(height: 16),
          if (_error != null)
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(_error!, style: const TextStyle(color: Colors.white)),
              ),
            ),
          if (_items != null)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('解析到 ${_items!.length} 条',
                        style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 8),
                    for (var i = 0; i < _items!.length; i++)
                      _ItemPreview(
                        index: i + 1,
                        item: _items![i],
                        hasLink: _ruleLink.text.trim().isNotEmpty,
                      ),
                    if (_items!.isEmpty)
                      const Text('（规则未匹配到任何条目，请检查列表规则）'),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _ruleField(TextEditingController c, String label, String hint) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: c,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          hintText: hint,
        ),
      ),
    );
  }
}

class _ItemPreview extends StatelessWidget {
  const _ItemPreview({
    required this.index,
    required this.item,
    required this.hasLink,
  });

  final int index;
  final RssItem item;
  final bool hasLink;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('第 $index 条',
              style: const TextStyle(fontWeight: FontWeight.bold)),
          _kv('标题', item.title),
          if (hasLink) _kv('链接', item.link.isEmpty ? '（未提取到）' : item.link),
          if (item.pubDate != null) _kv('时间', item.pubDate!),
          if (item.image != null && item.image!.isNotEmpty)
            _kv('图片', item.image!),
          if (item.description.isNotEmpty)
            _kv(
                '摘要',
                item.description.replaceAll(RegExp(r'<[^>]+>'), ' ').trim()),
          const Divider(height: 8),
        ],
      ),
    );
  }

  Widget _kv(String k, String v) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 44,
            child: Text('$k:', style: const TextStyle(color: Colors.grey)),
          ),
          Expanded(
            child: Text(v, maxLines: 2, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }
}