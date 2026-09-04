import 'package:flutter/material.dart';

import '../../../book_source/models/book_source.dart';
import '../../../book_source/services/book_source_service.dart';

/// 书源编辑页（对应官方 `ui/book/source/edit`）。
///
/// 编辑单本书源的各个字段，保存后更新内存列表。
class BookSourceEditPage extends StatefulWidget {
  const BookSourceEditPage({super.key, this.existing});

  final BookSource? existing;

  @override
  State<BookSourceEditPage> createState() => _BookSourceEditPageState();
}

class _BookSourceEditPageState extends State<BookSourceEditPage> {
  late final TextEditingController _name = TextEditingController();
  late final TextEditingController _url = TextEditingController();
  late final TextEditingController _group = TextEditingController();
  late int _type = 0;
  late bool _enabled = true;
  late bool _enabledExplore = true;
  late final TextEditingController _loginUrl = TextEditingController();
  late final TextEditingController _searchUrl = TextEditingController();
  late final TextEditingController _exploreUrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e != null) {
      _name.text = e.bookSourceName;
      _url.text = e.bookSourceUrl;
      _group.text = e.bookSourceGroup ?? '';
      _type = e.bookSourceType;
      _enabled = e.enabled;
      _enabledExplore = e.enabledExplore;
      _loginUrl.text = e.loginUrl ?? '';
      _searchUrl.text = e.searchUrl ?? '';
      _exploreUrl.text = e.exploreUrl ?? '';
    }
  }

  void _save() {
    final base = widget.existing?.toJson() ?? <String, dynamic>{};
    base['bookSourceName'] = _name.text.trim();
    base['bookSourceUrl'] = _url.text.trim();
    base['bookSourceType'] = _type;
    base['enabled'] = _enabled;
    base['enabledExplore'] = _enabledExplore;
    _setOrDelete(base, 'bookSourceGroup', _group.text.trim());
    _setOrDelete(base, 'loginUrl', _loginUrl.text.trim());
    _setOrDelete(base, 'searchUrl', _searchUrl.text.trim());
    _setOrDelete(base, 'exploreUrl', _exploreUrl.text.trim());

    final src = BookSource.fromJson(base);
    BookSourceService.instance.putSource(src);
    BookSourceService.instance.save();
    Navigator.pop(context, true);
  }

  void _setOrDelete(Map<String, dynamic> m, String k, String v) {
    final t = v.trim();
    if (t.isEmpty) {
      m.remove(k);
    } else {
      m[k] = t;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.existing == null ? '添加书源' : '编辑书源'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _name,
            decoration: const InputDecoration(
              labelText: '书源名称',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _url,
            decoration: const InputDecoration(
              labelText: '书源 URL',
              border: OutlineInputBorder(),
              hintText: 'https://...',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _group,
            decoration: const InputDecoration(
              labelText: '分组名称（逗号分隔多个分组）',
              border: OutlineInputBorder(),
              hintText: '玄幻,都市',
            ),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<int>(
            initialValue: _type,
            decoration: const InputDecoration(
              labelText: '书源类型',
              border: OutlineInputBorder(),
            ),
            items: const [
              DropdownMenuItem(value: 0, child: Text('文本')),
              DropdownMenuItem(value: 1, child: Text('音频/听书')),
              DropdownMenuItem(value: 2, child: Text('图片/漫画')),
              DropdownMenuItem(value: 4, child: Text('视频')),
              DropdownMenuItem(value: 3, child: Text('文件')),
            ],
            onChanged: (v) => setState(() => _type = v ?? _type),
          ),
          const SizedBox(height: 12),
          SwitchListTile(
            title: const Text('启用'),
            value: _enabled,
            onChanged: (v) => setState(() => _enabled = v),
          ),
          const SizedBox(height: 4),
          SwitchListTile(
            title: const Text('启用发现'),
            value: _enabledExplore,
            onChanged: (v) => setState(() => _enabledExplore = v),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _loginUrl,
            decoration: const InputDecoration(
              labelText: '登录 URL',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _searchUrl,
            decoration: const InputDecoration(
              labelText: '搜索 URL',
              border: OutlineInputBorder(),
              hintText: 'https://...search?key={key}',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _exploreUrl,
            decoration: const InputDecoration(
              labelText: '发现 URL',
              border: OutlineInputBorder(),
              hintText: '每行一个分组',
            ),
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _save,
              child: Text(widget.existing == null ? '添加' : '保存'),
            ),
          ),
        ],
      ),
    );
  }
}