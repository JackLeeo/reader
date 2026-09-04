import 'dart:convert';

import 'package:flutter/material.dart';

import '../../book_source/analyze/analyze_rule.dart';
import '../../book_source/models/book_source.dart';
import '../../book_source/services/http_service.dart';
import '../../widgets/code_editor.dart';
import 'code_editor_page.dart';

/// 规则调试器（对应官方「调试」工具）。
///
/// 输入书源 JSON + 测试 URL + 单条规则，实际发起请求并用 [AnalyzeRule]
/// 逐步求值，展示命中结果，用于验证规则是否正确。
class RuleDebuggerPage extends StatefulWidget {
  const RuleDebuggerPage({super.key});

  @override
  State<RuleDebuggerPage> createState() => _RuleDebuggerPageState();
}

class _RuleDebuggerPageState extends State<RuleDebuggerPage> {
  final TextEditingController _sourceJson = TextEditingController();
  final TextEditingController _testUrl = TextEditingController();
  final TextEditingController _rule = TextEditingController();

  bool _running = false;
  String? _result;
  String? _error;
  bool _asList = false;

  @override
  void dispose() {
    _sourceJson.dispose();
    _testUrl.dispose();
    _rule.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final url = _testUrl.text.trim();
    final rule = _rule.text.trim();
    if (url.isEmpty || rule.isEmpty) {
      setState(() => _error = '请填写测试 URL 与规则');
      return;
    }

    BookSource? source;
    if (_sourceJson.text.trim().isNotEmpty) {
      try {
        source = BookSource.fromJson(
            jsonDecode(_sourceJson.text.trim()) as Map<String, dynamic>);
      } catch (e) {
        setState(() => _error = '书源 JSON 解析失败：$e');
        return;
      }
    }

    setState(() {
      _running = true;
      _error = null;
      _result = null;
    });
    try {
      final resp = await HttpService.instance.get(url, source: source);
      if (!resp.ok) {
        setState(() {
          _running = false;
          _error = 'HTTP ${resp.statusCode}';
        });
        return;
      }

      final analyze = AnalyzeRule(source: source);
      analyze.setBaseUrl(resp.finalUrl?.toString() ?? url);
      analyze.setContent(_smart(resp));

      final isJson = _smart(resp) is Map;
      String output;
      if (_asList) {
        output = (await analyze.getStringListAsync(rule) ?? const []).toString();
      } else if (isJson) {
        output = (await analyze.getElementsAsync(rule)).toString();
      } else {
        output = await analyze.getStringAsync(rule);
      }

      if (!mounted) return;
      setState(() {
        _running = false;
        _result = output.toString();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _running = false;
        _error = '请求/解析出错：$e';
      });
    }
  }

  Object? _smart(Resp resp) {
    final t = resp.body.trim();
    if (t.startsWith('{') || t.startsWith('[')) {
      try {
        return jsonDecode(t);
      } catch (_) {
        return resp.body;
      }
    }
    return resp.body;
  }

  Future<void> _openCodeEditor() async {
    final result = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => CodeEditorPage(
          title: '规则编辑器',
          initialText: _rule.text,
          mode: CodeMode.none,
        ),
      ),
    );
    if (result != null && mounted) {
      _rule.text = result;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('规则调试器'),
        actions: [
          IconButton(
            icon: const Icon(Icons.code),
            tooltip: '代码编辑器',
            onPressed: _openCodeEditor,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _sourceJson,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: '书源 JSON（可选）',
              border: OutlineInputBorder(),
              hintText: '粘贴单个书源 JSON，可为空',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _testUrl,
            decoration: const InputDecoration(
              labelText: '测试 URL',
              border: OutlineInputBorder(),
              hintText: '如 https://example.com/search?key=斗破苍穹',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _rule,
            decoration: const InputDecoration(
              labelText: '规则',
              border: OutlineInputBorder(),
              hintText: r'如 class.book-item@name / $..name / #content 等',
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Checkbox(
                value: _asList,
                onChanged: (v) => setState(() => _asList = v ?? false),
              ),
              const Text('按列表解析（getStringList）'),
              const Spacer(),
              FilledButton.icon(
                onPressed: _running ? null : _run,
                icon: _running
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.play_arrow),
                label: Text(_running ? '运行中…' : '运行'),
              ),
            ],
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
          if (_result != null)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('结果',
                        style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 8),
                    SelectableText(_result!),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}