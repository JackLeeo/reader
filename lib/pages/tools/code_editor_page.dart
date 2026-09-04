import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../widgets/code_editor.dart';

/// 独立代码编辑器页（对齐官方 CodeEditActivity）。
///
/// 支持 JS / JSON / XML(RSS) 三种语法高亮的编辑，返回编辑后的文本。
class CodeEditorPage extends StatefulWidget {
  const CodeEditorPage({
    super.key,
    this.title = '代码编辑器',
    this.initialText = '',
    this.mode = CodeMode.js,
  });

  final String title;
  final String initialText;
  final CodeMode mode;

  @override
  State<CodeEditorPage> createState() => _CodeEditorPageState();
}

class _CodeEditorPageState extends State<CodeEditorPage> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialText);
  late CodeMode _mode = widget.mode;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _controller.text));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('已复制')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy_all),
            tooltip: '复制全部',
            onPressed: _copy,
          ),
          PopupMenuButton<CodeMode>(
            initialValue: _mode,
            onSelected: (m) => setState(() => _mode = m),
            itemBuilder: (_) => [
              for (final m in CodeMode.values)
                PopupMenuItem(
                  value: m,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(m == _mode ? Icons.check : Icons.code),
                      const SizedBox(width: 8),
                      Text(m.label),
                    ],
                  ),
                ),
            ],
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, _controller.text),
            child: const Text('完成'),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
              children: [
                Text(_mode.label,
                    style: Theme.of(context).textTheme.labelLarge),
                const Spacer(),
                Text(
                  '${_controller.text.length} 字符',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: SizedBox(
                width: double.infinity,
                child: CodeEditor(
                  controller: _controller,
                  mode: _mode,
                  minLines: 3,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}