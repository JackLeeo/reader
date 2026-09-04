import 'package:flutter/material.dart';

import '../../book_source/services/font_service.dart';
import '../../core/reading_pref.dart';

/// 阅读字体管理。对应官方「字体」：添加字体地址 → 下载 → 注册 → 应用到阅读器。
class FontManagePage extends StatefulWidget {
  const FontManagePage({super.key});

  @override
  State<FontManagePage> createState() => _FontManagePageState();
}

class _FontManagePageState extends State<FontManagePage> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    ReadingPref.instance.load();
  }

  Future<void> _add() async {
    final nameCtrl = TextEditingController();
    final urlCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('添加字体'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(labelText: '字体名称（显示用）'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: urlCtrl,
              decoration: const InputDecoration(
                labelText: '字体文件地址',
                hintText: 'https://.../font.ttf 或 .otf',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              if (nameCtrl.text.trim().isEmpty || urlCtrl.text.trim().isEmpty) {
                return;
              }
              Navigator.pop(ctx, true);
            },
            child: const Text('下载'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    final path = await FontService.instance
        .download(nameCtrl.text.trim(), urlCtrl.text.trim());
    setState(() => _busy = false);
    if (!mounted) return;
    _toast(path == null ? '下载失败' : '已下载，可点击条目注册并应用');
    setState(() {});
  }

  Future<void> _use(FontEntry font) async {
    setState(() => _busy = true);
    await FontService.instance.register(font.name);
    setState(() => _busy = false);
    if (!mounted) return;
    await ReadingPref.instance.setFontFamily(font.name);
    _toast('已应用到阅读（可通过阅读设置或关闭切换）');
    setState(() {});
  }

  void _resetFont() async {
    await ReadingPref.instance.setFontFamily('');
    _toast('已恢复系统默认字体');
    setState(() {});
  }

  void _toast(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(m), duration: const Duration(milliseconds: 1200)));
  }

  @override
  Widget build(BuildContext context) {
    final fonts = FontService.instance.fonts;
    final current = ReadingPref.instance.fontFamily;
    return Scaffold(
      appBar: AppBar(title: const Text('阅读字体')),
      floatingActionButton: _busy
          ? null
          : FloatingActionButton.extended(
              onPressed: _add,
              icon: const Icon(Icons.add),
              label: const Text('添加字体'),
            ),
      body: fonts.isEmpty
          ? const Center(child: Text('暂无字体，点击右下角下载'))
          : ListView(
              children: [
                if (current.isNotEmpty)
                  ListTile(
                    leading: const Icon(Icons.check_circle, color: Colors.green),
                    title: const Text('当前：'),
                    subtitle: Text(current),
                    trailing: TextButton(
                        onPressed: _resetFont, child: const Text('恢复默认')),
                  ),
                for (final f in fonts)
                  ListTile(
                    leading: const Icon(Icons.font_download_outlined),
                    title: Text(f.name,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                      f.filePath.isNotEmpty
                          ? (f.enabled ? '已注册并可用' : '已下载，需注册')
                          : '未下载',
                    ),
                    trailing: f.filePath.isEmpty
                        ? null
                        : TextButton(
                            onPressed: f.enabled ? null : () => _use(f),
                            child: Text(f.enabled ? '使用中' : '应用'),
                          ),
                  ),
              ],
            ),
    );
  }
}