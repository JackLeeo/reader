import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

/// 更换封面对话框的结果。
class CoverChangeResult {
  const CoverChangeResult({required this.remove, this.uri});
  final bool remove;

  /// remove=false 时的封面 uri（`file://` 或 `http(s)`）。
  final String? uri;
}

/// 打开换封面对话框：选本地图片 / 输入网络地址 / 清除自定义封面。
/// 返回 null 表示取消。
Future<CoverChangeResult?> showChangeCoverDialog(BuildContext context) {
  return showDialog<CoverChangeResult>(
    context: context,
    builder: (_) => const _ChangeCoverDialog(),
  );
}

class _ChangeCoverDialog extends StatelessWidget {
  const _ChangeCoverDialog();

  Future<void> _pickLocal(BuildContext context) async {
    const tg = XTypeGroup(
      label: 'cover',
      extensions: ['png', 'jpg', 'jpeg', 'webp', 'gif'],
      uniformTypeIdentifiers: ['public.image'],
    );
    final XFile? file = await openFile(acceptedTypeGroups: [tg]);
    if (file == null) return;
    if (context.mounted) {
      Navigator.pop(
        context,
        CoverChangeResult(remove: false, uri: 'file://${file.path}'),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final urlCtrl = TextEditingController();
    return AlertDialog(
      title: const Text('更换封面'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('选择本地图片'),
            onTap: () => _pickLocal(context),
          ),
          TextField(
            controller: urlCtrl,
            decoration: const InputDecoration(
              labelText: '网络图片地址',
              hintText: 'https://…/cover.jpg',
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(
            context,
            const CoverChangeResult(remove: true),
          ),
          child: const Text('清除自定义封面'),
        ),
        FilledButton(
          onPressed: () {
            final u = urlCtrl.text.trim();
            if (u.isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('请输入网络图片地址或选择本地图片')),
              );
              return;
            }
            Navigator.pop(
              context,
              CoverChangeResult(remove: false, uri: u),
            );
          },
          child: const Text('使用网络图片'),
        ),
      ],
    );
  }
}