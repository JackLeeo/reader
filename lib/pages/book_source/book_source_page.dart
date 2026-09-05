import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../book_source/models/book_source.dart';
import '../../book_source/services/book_source_service.dart';
import '../../book_source/services/http_service.dart';
import '../../book_source/utils/source_import_parser.dart';
import '../../book_source/utils/source_sharer.dart';
import '../tools/rule_debugger_page.dart';
import '../tools/source_import_preview.dart';
import 'book_source_edit_page.dart';
import 'source_qr_page.dart';
import 'source_validator_page.dart';

/// 书源管理页（对应官方 source_list 页面）。
///
/// 顶部按分组 Tab 展示书源，支持启用/禁用、导入、导出、全选操作。
class BookSourcePage extends StatefulWidget {
  const BookSourcePage({super.key});

  @override
  State<BookSourcePage> createState() => _BookSourcePageState();
}

class _BookSourcePageState extends State<BookSourcePage> {
  String _group = '';
  final TextEditingController _importController = TextEditingController();

  void _openQrPage() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const SourceQrPage()),
    );
  }

  void _editSource(BookSource s) async {
    final edited = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => BookSourceEditPage(existing: s)),
    );
    if (edited == true && mounted) _reload();
  }

  void _addSource() async {
    final added = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const BookSourceEditPage()),
    );
    if (added == true && mounted) _reload();
  }

  @override
  void initState() {
    super.initState();
    final groups = BookSourceService.instance.groups;
    _group = groups.isNotEmpty ? groups.first : '未分组';
  }

  @override
  void dispose() {
    _importController.dispose();
    super.dispose();
  }

  void _reload() => setState(() {});

  Future<void> _showImportDialog() async {
    var text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导入书源'),
        content: TextField(
          controller: _importController,
          maxLines: 10,
          decoration: const InputDecoration(
            hintText: '粘贴书源 JSON / 分享文本，支持单个、数组或 text: 包裹',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, _importController.text),
            child: const Text('解析并导入'),
          ),
        ],
      ),
    );
    if (text == null || text.trim().isEmpty) return;

    // 口令书源：弹出口令框解密后再导入。
    if (SourceSharer.isEncrypted(text)) {
      final dec = await _promptDecryptPassword(text);
      if (dec == null || !mounted) return;
      text = dec;
    }

    final parsed = SourceImportParser.parse(text);
    if (parsed.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('未能解析到书源')));
      return;
    }
    await _runCompareImport(parsed);
  }

  /// 口令书源：弹出口令输入，成功返回解密文本，取消/错误返回 null。
  Future<String?> _promptDecryptPassword(String payload) async {
    final controller = TextEditingController();
    final password = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('口令书源'),
        content: TextField(
          controller: controller,
          obscureText: true,
          autofocus: true,
          decoration: const InputDecoration(hintText: '请输入分享口令'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (password == null || password.isEmpty) return null;
    final dec = SourceSharer.decrypt(payload, password);
    if (dec == null && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('口令错误，无法解密')));
    }
    return dec;
  }

  /// 展示差异预览（新增/更新/一致），用户勾选后批量应用。
  Future<void> _runCompareImport(List<BookSource> incoming) async {
    final n = await SourceImportPreview.show(context, incoming);
    if (n == null) return;
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('已导入/更新 $n 个书源')));
    _reload();
  }

  Future<void> _exportAll() async {
    final json = BookSourceService.instance.exportAll();
    await _safeClipboard(json);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已复制（${BookSourceService.instance.sources.length} 个书源）'),
      ),
    );
  }

  /// 从订阅 URL 拉取书源 JSON 并导入。
  Future<void> _importFromUrl() async {
    final controller = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('从链接导入书源'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: 'https://.../bookSource.json',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    if (url == null || url.trim().isEmpty || !mounted) return;
    controller.dispose();

    setState(() {});
    try {
      final resp = await HttpService.instance.get(url.trim());
      if (!mounted) return;
      if (!resp.ok) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('请求失败：HTTP ${resp.statusCode}')));
        return;
      }
      final parsed = SourceImportParser.parse(resp.body);
      if (parsed.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('目标内容未解析到书源')));
        return;
      }
      await _runCompareImport(parsed);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导入失败：$e')));
    }
  }

  void _openDebugger() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const RuleDebuggerPage()),
    );
  }

  Future<void> _safeClipboard(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
  }

  /// 从本地书源文件(.json / .txt)读取并导入。
  Future<void> _importFromFile() async {
    const typeGroup = XTypeGroup(
      label: 'bookSource',
      extensions: ['json', 'txt'],
      uniformTypeIdentifiers: ['public.json', 'public.plain-text'],
    );
    final file = await openFile(acceptedTypeGroups: const [typeGroup]);
    if (file == null) return;
    final String content;
    try {
      content = await file.readAsString();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('读取文件失败：$e')));
      return;
    }
    final text = content.trim();
    if (text.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('文件内容为空')));
      return;
    }
    // 口令书源：解密后再导入。
    String usable = text;
    if (SourceSharer.isEncrypted(text)) {
      final dec = await _promptDecryptPassword(text);
      if (dec == null || !mounted) return;
      usable = dec;
    }
    final parsed = SourceImportParser.parse(usable);
    if (parsed.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('文件内容未解析到书源')));
      return;
    }
    await _runCompareImport(parsed);
  }

  @override
  Widget build(BuildContext context) {
    final svc = BookSourceService.instance;
    final groups = svc.groups;
    final sources = _group == '未分组'
        ? svc.sources.where((s) => s.groups.isEmpty).toList()
        : svc.sourcesInGroup(_group);
    final hasTabs = groups.length > 1;

    return DefaultTabController(
      length: groups.isNotEmpty ? groups.length : 1,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('书源管理'),
          bottom: hasTabs
              ? TabBar(
                  isScrollable: true,
                  tabs: [for (final g in groups) Tab(text: g)],
                )
              : null,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.maybePop(context),
          ),
          actions: [
            PopupMenuButton<String>(
              onSelected: (v) {
                switch (v) {
                  case 'import_file':
                    _importFromFile();
                  case 'import_url':
                    _importFromUrl();
                  case 'add':
                    _addSource();
                  case 'debug':
                    _openDebugger();
                  case 'export':
                    _exportAll();
                  case 'qr':
                    _openQrPage();
                  case 'validate':
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const SourceValidatorPage()),
                    );
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'add', child: Text('新增书源')),
                PopupMenuItem(value: 'import_file', child: Text('从本地文件导入书源')),
                PopupMenuItem(value: 'import_url', child: Text('从链接导入书源')),
                PopupMenuItem(value: 'qr', child: Text('书源二维码')),
                PopupMenuItem(value: 'debug', child: Text('规则调试器')),
                PopupMenuItem(value: 'validate', child: Text('校验书源')),
                PopupMenuItem(value: 'export', child: Text('导出全部书源')),
              ],
            ),
          ],
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: _showImportDialog,
          icon: const Icon(Icons.file_download_outlined),
          label: const Text('导入书源'),
        ),
        body: sources.isEmpty
            ? _buildEmpty()
            : ListView.separated(
                itemCount: sources.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final s = sources[i];
                  return _SourceTile(
                    source: s,
                    onToggle: (enabled) {
                      svc.setEnabled(s.bookSourceUrl, enabled);
                      svc.save();
                      _reload();
                    },
                    onEdit: () => _editSource(s),
                  );
                },
              ),
      ),
    );
  }

  Widget _buildEmpty() => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.collections_bookmark_outlined, size: 64),
            const SizedBox(height: 12),
            const Text('暂无书源\n点击右下角“导入书源”添加'),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _showImportDialog,
              icon: const Icon(Icons.file_download_outlined),
              label: const Text('导入书源'),
            ),
          ],
        ),
      );
}

class _SourceTile extends StatelessWidget {
  const _SourceTile({
    required this.source,
    required this.onToggle,
    this.onEdit,
  });

  final BookSource source;
  final ValueChanged<bool> onToggle;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onEdit,
      leading: Icon(
        switch (source.bookSourceType) {
          1 => Icons.headphones_outlined,
          2 => Icons.image_outlined,
          4 => Icons.videocam_outlined,
          _ => Icons.menu_book_outlined,
        },
        color: Theme.of(context).primaryColor,
      ),
      title: Text(source.bookSourceName),
      subtitle: Text(
        source.bookSourceUrl,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (onEdit != null)
            IconButton(
              icon: const Icon(Icons.edit_outlined, size: 20),
              onPressed: onEdit,
            ),
          Switch(value: source.enabled, onChanged: onToggle),
        ],
      ),
    );
  }
}