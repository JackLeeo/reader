import 'package:flutter/material.dart';

/// 粘贴/输入书源文本后导入。返回解析得到的纯文本（由调用方解析导入）。
class SourceImportPage extends StatefulWidget {
  const SourceImportPage({super.key});

  @override
  State<SourceImportPage> createState() => _SourceImportPageState();
}

class _SourceImportPageState extends State<SourceImportPage> {
  final TextEditingController _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('粘贴导入')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Expanded(
              child: TextField(
                controller: _ctrl,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: '粘贴书源 JSON（数组 / 单对象 / text: 包裹）',
                ),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () {
                  final t = _ctrl.text.trim();
                  if (t.isEmpty) {
                    ScaffoldMessenger.of(this.context).showSnackBar(
                      const SnackBar(content: Text('请输入书源文本')),
                    );
                    return;
                  }
                  Navigator.pop(context, t);
                },
                child: const Text('导入'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}