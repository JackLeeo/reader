import 'dart:convert';

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
/// 顶部按分组 Tab 展示书源，支持：启用/禁用、发现开关、编辑、
/// 长按拖动排序、置顶/置底、单源导出/加密分享、删除，以及
/// 多选批量操作（删除/启用/禁用/导出）。
class BookSourcePage extends StatefulWidget {
  const BookSourcePage({super.key});

  @override
  State<BookSourcePage> createState() => _BookSourcePageState();
}

class _BookSourcePageState extends State<BookSourcePage> {
  String _group = '';
  final TextEditingController _importController = TextEditingController();

  /// 多选模式标记与选中集合。
  bool _selecting = false;
  final Set<String> _selected = {};

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

  void _exitSelecting() {
    _selecting = false;
    _selected.clear();
    _reload();
  }

  void _toggleSelect(String url) {
    setState(() {
      if (!_selected.remove(url)) _selected.add(url);
    });
  }

  List<BookSource> get _selectedSources =>
      BookSourceService.instance.sources
          .where((s) => _selected.contains(s.bookSourceUrl))
          .toList();

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
    // 导入成功：切到新书源所在分组，保证“所见即所得”（无分组回“未分组”）。
    var target = '未分组';
    for (final s in incoming) {
      if (s.groups.isNotEmpty) {
        target = s.groups.first;
        break;
      }
    }
    if (!mounted) return;
    setState(() => _group = target);
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('已导入/更新 $n 个书源')));
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

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      duration: const Duration(milliseconds: 900),
    ));
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
      _toast('读取文件失败：$e');
      return;
    }
    final text = content.trim();
    if (text.isEmpty) {
      _toast('文件内容为空');
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
      _toast('文件内容未解析到书源');
      return;
    }
    await _runCompareImport(parsed);
  }

  // ---- 排序 / 置顶置底 ----
  void _reorderUrls(List<String> ordered) {
    final svc = BookSourceService.instance;
    svc.reorder(ordered);
    svc.save();
    _reload();
  }

  void _onReorder(int oldIndex, int newIndex) {
    final sources = _visibleSources();
    if (oldIndex < 0 || oldIndex >= sources.length) return;
    final list = List<BookSource>.of(sources);
    final item = list.removeAt(oldIndex);
    list.insert(newIndex.clamp(0, list.length), item);
    _reorderUrls([for (final s in list) s.bookSourceUrl]);
  }

  void _pinTop(BookSource s) {
    final list = _visibleSources()
      ..removeWhere((e) => e.bookSourceUrl == s.bookSourceUrl);
    list.insert(0, s);
    _reorderUrls([for (final e in list) e.bookSourceUrl]);
  }

  void _pinBottom(BookSource s) {
    final list = _visibleSources()
      ..removeWhere((e) => e.bookSourceUrl == s.bookSourceUrl);
    list.add(s);
    _reorderUrls([for (final e in list) e.bookSourceUrl]);
  }

  /// 复制单个书源 JSON 到剪贴板。
  Future<void> _exportOne(BookSource s) async {
    final json =
        const JsonEncoder.withIndent('  ').convert([s.toJson()]);
    await _safeClipboard(json);
    _toast('已复制书源 ${s.bookSourceName}');
  }

  /// 加密分享单个书源：输入口令后加密并复制。
  Future<void> _shareOneEncrypted(BookSource s) async {
    final controller = TextEditingController();
    final pwd = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('加密分享书源'),
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
    final p = pwd?.trim();
    if (p == null || p.isEmpty) return;
    final enc = SourceSharer.encrypt(jsonEncode([s.toJson()]), p);
    await _safeClipboard(enc);
    _toast('已生成口令书源并复制');
  }

  // ---- 多选批量操作 ----
  void _batchDelete() {
    final svc = BookSourceService.instance;
    final n = _selected.length;
    if (n == 0) return;
    showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('批量删除'),
        content: Text('确定删除选中的 $n 个书源吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    ).then((ok) {
      if (ok != true || !mounted) return;
      for (final url in _selected.toList()) {
        svc.removeSource(url);
      }
      svc.save();
      _exitSelecting();
      _toast('已删除 $n 个书源');
    });
  }

  void _batchSetEnabled(bool enabled) {
    final svc = BookSourceService.instance;
    final n = _selected.length;
    for (final url in _selected.toList()) {
      svc.setEnabled(url, enabled);
    }
    svc.save();
    _exitSelecting();
    _toast('已${enabled ? '启用' : '禁用'} $n 个书源');
  }

  void _batchExport() {
    final list = _selectedSources;
    if (list.isEmpty) return;
    final json = const JsonEncoder.withIndent('  ').convert([
      for (final s in list) s.toJson(),
    ]);
    _safeClipboard(json);
    _toast('已复制 ${list.length} 个书源');
  }

  List<BookSource> _visibleSources() {
    final svc = BookSourceService.instance;
    if (_group == '未分组') {
      return svc.sources.where((s) => s.groups.isEmpty).toList();
    }
    return svc.sourcesInGroup(_group);
  }

  @override
  Widget build(BuildContext context) {
    final svc = BookSourceService.instance;
    final groups = svc.groups;
    final sources = _visibleSources();
    final hasTabs = groups.length > 1;

    return DefaultTabController(
      length: groups.isNotEmpty ? groups.length : 1,
      child: Scaffold(
        appBar: _buildAppBar(hasTabs, groups, sources),
        floatingActionButton: _selecting ? null : _buildFabs(),
        bottomNavigationBar: _selecting ? _buildBatchBar() : null,
        body: sources.isEmpty
            ? _buildEmpty()
            : ReorderableListView.builder(
                padding: const EdgeInsets.only(bottom: 16),
                buildDefaultDragHandles: false,
                itemCount: sources.length,
                onReorderItem: _onReorder,
                proxyDecorator: (child, _, _) => Material(
                  elevation: 4,
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(8),
                  child: child,
                ),
                itemBuilder: (_, i) {
                  final s = sources[i];
                  final sel = _selected.contains(s.bookSourceUrl);
                  return ReorderableDragStartListener(
                    key: ValueKey('src_${s.bookSourceUrl}'),
                    index: i,
                    child: _SourceTile(
                      source: s,
                      selected: _selecting && sel,
                      selectMode: _selecting,
                      onTap: () => _selecting
                          ? _toggleSelect(s.bookSourceUrl)
                          : _editSource(s),
                      onToggle: (enabled) {
                        svc.setEnabled(s.bookSourceUrl, enabled);
                        svc.save();
                        _reload();
                      },
                      onToggleExplore: (v) {
                        svc.setExploreEnabled(s.bookSourceUrl, v);
                        svc.save();
                        _reload();
                      },
                      onMenu: (v) => _onSourceMenu(s, v),
                    ),
                  );
                },
              ),
      ),
    );
  }

  PreferredSizeWidget? _buildAppBar(
      bool hasTabs, List<String> groups, List<BookSource> sources) {
    return AppBar(
      title: Text(_selecting ? '已选 ${_selected.length}' : '书源管理'),
      bottom: hasTabs && !_selecting
          ? TabBar(
              isScrollable: true,
              onTap: (i) => setState(
                  () => _group = i >= 0 && i < groups.length ? groups[i] : '未分组'),
              tabs: [for (final g in groups) Tab(text: g)],
            )
          : null,
      leading: IconButton(
        icon: const Icon(Icons.arrow_back),
        onPressed: () => _selecting ? _exitSelecting() : Navigator.maybePop(context),
      ),
      actions: _selecting
          ? [
              IconButton(
                icon: const Icon(Icons.select_all),
                tooltip: '全选',
                onPressed: () => setState(() {
                  _selected.clear();
                  for (final s in sources) {
                    _selected.add(s.bookSourceUrl);
                  }
                }),
              ),
              IconButton(
                icon: const Icon(Icons.close),
                tooltip: '取消选择',
                onPressed: _exitSelecting,
              ),
            ]
          : [
              PopupMenuButton<String>(
                onSelected: (v) {
                  switch (v) {
                    case 'multi':
                      setState(() => _selecting = true);
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
                  PopupMenuItem(value: 'multi', child: Text('多选')),
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
    );
  }

  Widget _buildFabs() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        FloatingActionButton.small(
          heroTag: 'fab_add',
          tooltip: '新增书源',
          onPressed: _addSource,
          child: const Icon(Icons.add),
        ),
        const SizedBox(height: 12),
        FloatingActionButton.extended(
          heroTag: 'fab_import',
          onPressed: _showImportDialog,
          icon: const Icon(Icons.file_download_outlined),
          label: const Text('导入书源'),
        ),
      ],
    );
  }

  Widget _buildBatchBar() {
    return BottomAppBar(
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: '删除选中',
            onPressed: _batchDelete,
          ),
          IconButton(
            icon: const Icon(Icons.check_circle_outline),
            tooltip: '启用选中',
            onPressed: () => _batchSetEnabled(true),
          ),
          IconButton(
            icon: const Icon(Icons.remove_circle_outline),
            tooltip: '禁用选中',
            onPressed: () => _batchSetEnabled(false),
          ),
          IconButton(
            icon: const Icon(Icons.ios_share),
            tooltip: '导出选中',
            onPressed: _batchExport,
          ),
          const Spacer(),
          Text('已选 ${_selected.length}'),
        ],
      ),
    );
  }

  void _onSourceMenu(BookSource s, String v) {
    switch (v) {
      case 'edit':
        _editSource(s);
        break;
      case 'top':
        _pinTop(s);
        break;
      case 'bottom':
        _pinBottom(s);
        break;
      case 'export':
        _exportOne(s);
        break;
      case 'share':
        _shareOneEncrypted(s);
        break;
      case 'delete':
        showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('删除书源'),
            content: Text('确定删除「${s.bookSourceName}」吗？'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('删除'),
              ),
            ],
          ),
        ).then((ok) {
          if (ok != true || !mounted) return;
          BookSourceService.instance.removeSource(s.bookSourceUrl);
          BookSourceService.instance.save();
          _reload();
          _toast('已删除书源');
        });
        break;
    }
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
    required this.onTap,
    required this.onToggle,
    required this.onToggleExplore,
    required this.onMenu,
    this.selected = false,
    this.selectMode = false,
  });

  final BookSource source;
  final VoidCallback onTap;
  final ValueChanged<bool> onToggle;
  final ValueChanged<bool> onToggleExplore;
  final ValueChanged<String> onMenu;
  final bool selected;
  final bool selectMode;

  @override
  Widget build(BuildContext context) {
    final icon = switch (source.bookSourceType) {
      1 => Icons.headphones_outlined,
      2 => Icons.image_outlined,
      4 => Icons.videocam_outlined,
      _ => Icons.menu_book_outlined,
    };
    return ListTile(
      onTap: onTap,
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!selectMode) const Icon(Icons.drag_handle, size: 18),
          const SizedBox(width: 4),
          Icon(icon, color: Theme.of(context).primaryColor),
        ],
      ),
      title: Text(source.bookSourceName),
      subtitle: Text(
        source.bookSourceUrl,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      selected: selected,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!selectMode)
            IconButton(
              icon: Icon(
                source.enabledExplore
                    ? Icons.travel_explore
                    : Icons.travel_explore_outlined,
                size: 20,
                color: source.enabledExplore
                    ? Theme.of(context).primaryColor
                    : null,
              ),
              tooltip: source.enabledExplore ? '发现已启用' : '启用发现',
              onPressed: () => onToggleExplore(!source.enabledExplore),
            ),
          if (!selectMode)
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert, size: 20),
              tooltip: '更多',
              onSelected: onMenu,
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'edit', child: Text('编辑')),
                PopupMenuItem(value: 'top', child: Text('置顶')),
                PopupMenuItem(value: 'bottom', child: Text('置底')),
                PopupMenuItem(value: 'export', child: Text('导出单个(复制 JSON)')),
                PopupMenuItem(value: 'share', child: Text('加密分享')),
                PopupMenuItem(value: 'delete', child: Text('删除')),
              ],
            ),
          Switch(value: source.enabled, onChanged: onToggle),
        ],
      ),
    );
  }
}