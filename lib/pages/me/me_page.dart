import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../book_source/services/http_service.dart';
import '../../book_source/services/read_stat_service.dart';
import '../../core/reading_pref.dart';
import '../../core/theme_mode_store.dart';
import '../../core/shelf_badge_store.dart';
import '../book_source/book_source_page.dart';
import '../tools/auto_task_page.dart';
import '../tools/backup_page.dart';
import '../tools/bookmark_manage_page.dart';
import '../tools/cache_manage_page.dart';
import '../tools/download_center_page.dart';
import '../tools/cookie_page.dart';
import '../tools/dict_manage_page.dart';
import '../tools/font_manage_page.dart';
import '../tools/file_manage_page.dart';
import '../tools/highlight_manage_page.dart';
import 'note_manage_page.dart';
import '../tools/local_server_page.dart';
import '../tools/proxy_page.dart';
import '../tools/read_record_page.dart';
import '../tools/replace_rule_page.dart';
import '../tools/rule_subscription_page.dart';
import '../tools/tts_manage_page.dart';
import '../tools/txt_toc_rule_page.dart';
import '../tools/webdav_page.dart';

/// 我的。对应官方 fragment_my_config。
///
/// 阶段3按官方 setting 结构复刻常用设置项：书源/书架、阅读、主题、数据、关于。
class MePage extends StatelessWidget {
  const MePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('我的')),
      body: ListView(
        children: [
          _SectionHeader('书源'),
          ListTile(
            leading: const Icon(Icons.collections_bookmark_outlined),
            title: const Text('书源管理'),
            subtitle: const Text('启用/禁用、导入、导出书源'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const BookSourcePage()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.rss_feed),
            title: const Text('规则订阅'),
            subtitle: const Text('订阅远端书源，一键同步'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const RuleSubscriptionPage()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.cookie_outlined),
            title: const Text('Cookie 管理'),
            subtitle: const Text('查看/管理书源登录 Cookie'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const CookiePage()),
            ),
          ),
          const Divider(height: 1),
          _SectionHeader('阅读'),
          ListTile(
            leading: const Icon(Icons.brightness_6_outlined),
            title: Text('主题模式（${ThemeController.kNames[ThemeController.instance.mode.value]}）'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _pickThemeMode(context),
          ),
          ListTile(
            leading: const Icon(Icons.palette_outlined),
            title: Text('自定义配色（${ThemeController.instance.hasCustomAccent ? '已启用' : '默认'}）'),
            subtitle: const Text('选择主题主色（亮/暗通用）'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _pickAccent(context),
          ),
          ListTile(
            leading: const Icon(Icons.badge_outlined),
            title: Text('书架角标（${ShelfBadgeController.kNames[ShelfBadgeController.instance.mode.value]}）'),
            subtitle: const Text('封面显示阅读进度角标/进度条'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _pickShelfBadge(context),
          ),
          ListTile(
            leading: const Icon(Icons.format_size),
            title: const Text('阅读设置'),
            subtitle: const Text('字号、行距、背景、翻页模式'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _openReadingSettings(context),
          ),
          ListTile(
            leading: const Icon(Icons.record_voice_over_outlined),
            title: const Text('TTS 引擎管理'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const TtsManagePage()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.sticky_note_2_outlined),
            title: const Text('笔记管理'),
            subtitle: const Text('查看/编辑阅读时记录的章节笔记'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const NoteManagePage()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.menu_book_outlined),
            title: const Text('词典'),
            subtitle: const Text('查询词义的词典源管理'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const DictManagePage()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.format_color_fill),
            title: const Text('正文高亮'),
            subtitle: const Text('阅读时按关键词/正则高亮'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const HighlightManagePage()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.font_download_outlined),
            title: const Text('阅读字体'),
            subtitle: const Text('下载自定字体并应用到阅读器'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const FontManagePage()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.cleaning_services_outlined),
            title: const Text('替换规则'),
            subtitle: const Text('正文/标题净化替换规则'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ReplaceRulePage()),
            ),
          ),
          const Divider(height: 1),
          _SectionHeader('数据'),
          ListTile(
            leading: const Icon(Icons.timer_outlined),
            title: const Text('阅读时长'),
            subtitle: Text(_statSummary()),
            onTap: () => _showReadStat(context),
          ),
          ListTile(
            leading: const Icon(Icons.history),
            title: const Text('阅读记录'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ReadRecordPage()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.bookmark_outline),
            title: const Text('书签管理'),
            subtitle: const Text('查看/删除全部书签'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const BookmarkManagePage()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.settings_backup_restore),
            title: const Text('备份与恢复'),
            subtitle: const Text('导出/恢复全部书源与书架'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const BackupPage()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.sd_storage_outlined),
            title: const Text('缓存管理'),
            subtitle: const Text('清理正文缓存与漫画离线章节'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const CacheManagePage()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.downloading),
            title: const Text('下载中心'),
            subtitle: const Text('章节批量下载队列：排队/进度/暂停'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const DownloadCenterPage()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.cloud_sync_outlined),
            title: const Text('WebDAV 同步'),
            subtitle: const Text('备份/恢复书源与书架到云端'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const WebDavPage()),
            ),
          ),
          const Divider(height: 1),
          _SectionHeader('更多'),
          ListTile(
            leading: const Icon(Icons.rule_folder_outlined),
            title: const Text('TXT 目录规则'),
            subtitle: const Text('本地书分章正则'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const TxtTocRulePage()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.language),
            title: const Text('代理设置'),
            subtitle: const Text('全局网络代理'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ProxyPage()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.schedule_outlined),
            title: const Text('自动任务'),
            subtitle: const Text('定时刷新 RSS 等自动动作'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const AutoTaskPage()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.folder_open_outlined),
            title: const Text('文件管理'),
            subtitle: const Text('浏览应用数据/导出文件'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const FileManagePage()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.lan_outlined),
            title: const Text('本地 Web 服务'),
            subtitle: const Text('局域网查询本机书源/目录/正文'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const LocalServerPage()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.home_outlined),
            title: const Text('默认首页'),
            subtitle: const Text('启动时优先显示的底部页签'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _pickDefaultHome(context),
          ),
          ListTile(
            leading: const Icon(Icons.public_outlined),
            title: const Text('自定义 User-Agent'),
            subtitle: const Text('覆盖全局请求 UA（空 = 默认）'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _editUserAgent(context),
          ),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('关于 Legado'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showAbout(context),
          ),
        ],
      ),
    );
  }

  void _openReadingSettings(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => const ReadingSettingsPanel(),
    );
  }

  void _pickShelfBadge(BuildContext context) {
    final cur = ShelfBadgeController.instance.mode.value;
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < ShelfBadgeController.kNames.length; i++)
              ListTile(
                leading: Icon(
                  cur == i ? Icons.radio_button_checked : Icons.radio_button_off,
                  color: Theme.of(ctx).colorScheme.primary,
                ),
                title: Text(ShelfBadgeController.kNames[i]),
                onTap: () {
                  ShelfBadgeController.instance.setMode(i);
                  Navigator.pop(ctx);
                },
              ),
          ],
        ),
      ),
    );
  }

  void _pickThemeMode(BuildContext context) {
    final cur = ThemeController.instance.mode.value;
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < ThemeController.kNames.length; i++)
              ListTile(
                leading: Icon(
                  cur == i ? Icons.radio_button_checked : Icons.radio_button_off,
                  color: Theme.of(ctx).colorScheme.primary,
                ),
                title: Text(ThemeController.kNames[i]),
                onTap: () {
                  ThemeController.instance.setMode(i);
                  Navigator.pop(ctx);
                },
              ),
          ],
        ),
      ),
    );
  }

  /// 自定义配色面板：预设色板 + 自定义色 + 恢复默认。
  void _pickAccent(BuildContext context) {
    const accents = <Color>[
      Color(0xFF2196F3), // 默认蓝
      Color(0xFF4CAF50),
      Color(0xFFF44336),
      Color(0xFFFF9800),
      Color(0xFF9C27B0),
      Color(0xFF00BCD4),
      Color(0xFF795548),
      Color(0xFF3F51B5),
      Color(0xFFE91E63),
      Color(0xFF607D8B),
    ];
    final cur = ThemeController.instance.accent.value;
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('自定义配色',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final c in accents)
                    GestureDetector(
                      onTap: () {
                        ThemeController.instance.setAccent(c);
                        Navigator.pop(ctx);
                      },
                      child: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: c,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: cur == c.toARGB32()
                                ? Theme.of(ctx).colorScheme.primary
                                : Colors.transparent,
                            width: 3,
                          ),
                        ),
                        child: cur == c.toARGB32()
                            ? const Icon(Icons.check, color: Colors.white, size: 20)
                            : null,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  TextButton.icon(
                    onPressed: () async {
                      final picked = await showDialog<Color>(
                        context: context,
                        builder: (_) => _ColorPickerDialog(
                            initial: cur == 0 ? const Color(0xFF2196F3) : Color(cur)),
                      );
                      if (picked != null) {
                        ThemeController.instance.setAccent(picked);
                      }
                      if (ctx.mounted) Navigator.pop(ctx);
                    },
                    icon: const Icon(Icons.colorize),
                    label: const Text('自定义色'),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () {
                      ThemeController.instance.resetAccent();
                      Navigator.pop(ctx);
                    },
                    child: const Text('恢复默认'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pickDefaultHome(BuildContext context) async {
    const names = ['书库', '发现', '我的', 'RSS'];
    final p = await SharedPreferences.getInstance();
    final cur = p.getInt('defaultHome') ?? 0;
    if (!context.mounted) return;
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < names.length; i++)
              ListTile(
                leading: Icon(
                  cur == i ? Icons.radio_button_checked : Icons.radio_button_off,
                  color: Theme.of(ctx).colorScheme.primary,
                ),
                title: Text(names[i]),
                onTap: () {
                  p.setInt('defaultHome', i);
                  Navigator.pop(ctx);
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _editUserAgent(BuildContext context) async {
    final p = await SharedPreferences.getInstance();
    final controller =
        TextEditingController(text: p.getString('customUA') ?? '');
    if (!context.mounted) return;
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('自定义 User-Agent'),
        content: TextField(
          controller: controller,
          maxLines: 3,
          decoration: const InputDecoration(hintText: '留空则使用默认 UA'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (saved == true) {
      final v = controller.text.trim();
      await p.setString('customUA', v);
      HttpService.instance.setUserAgent(v);
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(v.isEmpty ? '已恢复默认 UA' : '已应用自定义 UA')));
      }
    }
    controller.dispose();
  }

  void _showAbout(BuildContext context) {
    showAboutDialog(
      context: context,
      applicationName: 'Legado',
      applicationVersion: '跨平台版 0.1.0',
      children: const [
        Text('基于官方 Legado 规则引擎重写的跨平台版本，覆盖 iOS / Android。'),
      ],
    );
  }

  String _statSummary() {
    final s = ReadStatService.instance;
    return '累计 ${_fmtDuration(s.totalSeconds)} · 今日 ${_fmtDuration(s.todaySeconds)}';
  }

  static String _fmtDuration(int seconds) {
    if (seconds < 60) return '$seconds 秒';
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    if (h > 0) return '$h 小时 $m 分';
    return '$m 分钟';
  }

  void _showReadStat(BuildContext context) {
    final s = ReadStatService.instance;
    final books = s.topBooks;
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('阅读时长', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Text('累计 ${_fmtDuration(s.totalSeconds)} · 今日 ${_fmtDuration(s.todaySeconds)}'),
              const Divider(height: 24),
              if (books.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Text('还没有阅读记录，去读几章吧。'),
                )
              else
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: books.length,
                    itemBuilder: (_, i) {
                      final b = books[i];
                      return ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Text('${i + 1}'),
                        title: Text(b.title.isEmpty ? '(未命名)' : b.title,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        trailing: Text(_fmtDuration(b.seconds)),
                      );
                    },
                  ),
                ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: Theme.of(context).colorScheme.primary,
            ),
      ),
    );
  }
}

/// 复选的阅读设置面板（与阅读器内一致，供“我的-阅读设置”入口复用）。
class ReadingSettingsPanel extends StatefulWidget {
  const ReadingSettingsPanel({super.key});

  @override
  State<ReadingSettingsPanel> createState() => _ReadingSettingsPanelState();
}

class _ReadingSettingsPanelState extends State<ReadingSettingsPanel> {
  late final ReadingPref _pref = ReadingPref.instance;

  @override
  void initState() {
    super.initState();
    _pref.load();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('阅读设置', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Row(
              children: [
                const Text('背景主题'),
                const Spacer(),
                for (var i = 0; i < ReadingPref.kThemes.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: ChoiceChip(
                      label: Text(ReadingPref.kThemes[i].name),
                      selected: _pref.themeIndex == i,
                      onSelected: (_) => setState(() => _pref.setThemeIndex(i)),
                    ),
                  ),
              ],
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('字号'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.text_decrease),
                    onPressed: () => _adjFont(-2),
                  ),
                  Text('${_pref.fontSize}'),
                  IconButton(
                    icon: const Icon(Icons.text_increase),
                    onPressed: () => _adjFont(2),
                  ),
                ],
              ),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('行距'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.remove_circle_outline),
                    onPressed: () =>
                        setState(() => _pref.setLineHeight((_pref.lineHeight - 0.1).clamp(1.2, 2.5))),
                  ),
                  Text(_pref.lineHeight.toStringAsFixed(1)),
                  IconButton(
                    icon: const Icon(Icons.add_circle_outline),
                    onPressed: () =>
                        setState(() => _pref.setLineHeight((_pref.lineHeight + 0.1).clamp(1.2, 2.5))),
                  ),
                ],
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('阅读常亮'),
              subtitle: const Text('阅读时屏幕保持常亮'),
              value: _pref.keepScreenOn,
              onChanged: (v) async {
                setState(() => _pref.setKeepScreenOn(v));
                v ? await WakelockPlus.enable() : await WakelockPlus.disable();
              },
            ),
          ],
        ),
      ),
    );
  }

  void _adjFont(int delta) {
    final idx = ReadingPref.kFontSizes.indexOf(_pref.fontSize);
    final ni =
        (idx + delta).clamp(0, ReadingPref.kFontSizes.length - 1);
    setState(() => _pref.setFontSize(ReadingPref.kFontSizes[ni]));
  }
}

/// 简易颜色选择对话框：预设色 + 滑杆调 RGB。
class _ColorPickerDialog extends StatefulWidget {
  const _ColorPickerDialog({required this.initial});
  final Color initial;

  @override
  State<_ColorPickerDialog> createState() => _ColorPickerDialogState();
}

class _ColorPickerDialogState extends State<_ColorPickerDialog> {
  late Color _color = widget.initial;
  late double _r = widget.initial.r * 255;
  late double _g = widget.initial.g * 255;
  late double _b = widget.initial.b * 255;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('选择主色'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(color: _color, shape: BoxShape.circle),
          ),
          const SizedBox(height: 12),
          _slider('红', _r, (v) => setState(() {
            _r = v;
            _color = Color.fromARGB(255, v.toInt(), _g.toInt(), _b.toInt());
          })),
          _slider('绿', _g, (v) => setState(() {
            _g = v;
            _color = Color.fromARGB(255, _r.toInt(), v.toInt(), _b.toInt());
          })),
          _slider('蓝', _b, (v) => setState(() {
            _b = v;
            _color = Color.fromARGB(255, _r.toInt(), _g.toInt(), v.toInt());
          })),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(
            onPressed: () => Navigator.pop(context, _color),
            child: const Text('确定')),
      ],
    );
  }

  Widget _slider(String label, double value, ValueChanged<double> onChanged) {
    return Row(
      children: [
        SizedBox(width: 24, child: Text(label)),
        Expanded(
          child: Slider(
            value: value.clamp(0.0, 255.0).toDouble(),
            min: 0,
            max: 255,
            onChanged: onChanged,
          ),
        ),
        Text(value.toInt().toString()),
      ],
    );
  }
}