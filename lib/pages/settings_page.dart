// 设置页
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/chapter_cache_service.dart';
import '../../services/settings_service.dart';
import '../../utils/log.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  int _cacheSize = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refreshCache();
  }

  Future<void> _refreshCache() async {
    final cache = context.read<ChapterCacheService>();
    final s = await cache.totalSize();
    if (!mounted) return;
    setState(() {
      _cacheSize = s;
      _loading = false;
    });
  }

  String _fmtBytes(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    return '${(b / 1024 / 1024).toStringAsFixed(2)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<SettingsService>();
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        children: [
          const _Section(title: '主题'),
          ListTile(
            title: const Text('深色模式'),
            trailing: Switch(
              value: s.themeMode == ThemeMode.dark,
              onChanged: (v) {
                s.setThemeMode(v ? ThemeMode.dark : ThemeMode.light);
              },
            ),
          ),
          ListTile(
            title: const Text('跟随系统'),
            trailing: Switch(
              value: s.themeMode == ThemeMode.system,
              onChanged: (v) {
                s.setThemeMode(v ? ThemeMode.system : ThemeMode.light);
              },
            ),
          ),
          const _Section(title: '阅读'),
          ListTile(
            title: const Text('字号'),
            subtitle: Slider(
              min: 12,
              max: 32,
              divisions: 20,
              value: s.fontSize,
              label: s.fontSize.toStringAsFixed(0),
              onChanged: (v) {
                s.setFontSize(v);
              },
            ),
          ),
          ListTile(
            title: const Text('行距'),
            subtitle: Slider(
              min: 1.2,
              max: 2.4,
              divisions: 12,
              value: s.lineHeight,
              label: s.lineHeight.toStringAsFixed(1),
              onChanged: (v) {
                s.setLineHeight(v);
              },
            ),
          ),
          ListTile(
            title: const Text('翻页模式'),
            subtitle: Text(_pageTurnName(s.pageTurn)),
            trailing: DropdownButton<String>(
              value: s.pageTurn,
              items: const [
                DropdownMenuItem(value: 'none', child: Text('无动画')),
                DropdownMenuItem(value: 'slide', child: Text('上下滑动')),
                DropdownMenuItem(value: 'curl', child: Text('仿真翻页')),
              ],
              onChanged: (v) {
                if (v != null) s.setPageTurn(v);
              },
            ),
          ),
          ListTile(
            title: const Text('保持屏幕常亮'),
            trailing: Switch(
              value: s.keepScreenOn,
              onChanged: s.setKeepScreenOn,
            ),
          ),
          const _Section(title: '主题色'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                _colorChip('#FFF8E1', '羊皮纸'),
                _colorChip('#FFFFFF', '白色'),
                _colorChip('#F5E6D3', '米色'),
                _colorChip('#D4C5A9', '牛皮'),
                _colorChip('#1E1E1E', '夜间'),
                _colorChip('#0F1A2B', '深蓝'),
              ],
            ),
          ),
          const _Section(title: '缓存'),
          ListTile(
            title: const Text('章节缓存'),
            subtitle: Text(_loading ? '...' : _fmtBytes(_cacheSize)),
            trailing: TextButton(
              onPressed: () async {
                final cache = context.read<ChapterCacheService>();
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('清空章节缓存'),
                    content: const Text('清空后需重新联网下载章节内容'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('取消'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('清空'),
                      ),
                    ],
                  ),
                );
                if (ok == true) {
                  final n = await cache.clearAll();
                  if (!mounted) return;
                  Log.i('已清空 $n 个章节缓存');
                  await _refreshCache();
                }
              },
              child: const Text('清空'),
            ),
          ),
          const _Section(title: '书源'),
          ListTile(
            title: const Text('启动时检测书源'),
            subtitle: const Text('默认关闭. 开启后后台探测每个书源是否可达, 距上次 6+ 小时才重测. 首次运行不会自动跑, 需先在「书源」页手动点过「重新检测」'),
            trailing: Switch(
              value: s.sourceCheckOnStartup,
              onChanged: s.setSourceCheckOnStartup,
            ),
          ),
          ListTile(
            title: const Text('无效线路自动关闭'),
            subtitle: const Text('默认关闭. 检测失败的书源自动禁用. 建议保持关闭, 误判会导致书源全部消失'),
            trailing: Switch(
              value: s.invalidAutoDisable,
              onChanged: s.setInvalidAutoDisable,
            ),
          ),
          if (s.invalidAutoDisable)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.orange.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.orange.shade200),
                ),
                child: Row(
                  children: [
                    Icon(Icons.warning_amber, color: Colors.orange.shade700, size: 20),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        '已开启. 若书源全被误判禁用, 可到「书源」页点顶部「恢复所有书源」',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 32),
          const _Section(title: '关于'),
          const ListTile(
            title: Text('换源阅读'),
            subtitle: Text('v1.0.0 - 兼容Legado书源'),
          ),
          const ListTile(
            title: Text('构建信息'),
            subtitle: Text('Flutter · Dart 3.4+ · iOS 13+'),
          ),
        ],
      ),
    );
  }

  String _pageTurnName(String k) {
    switch (k) {
      case 'none':
        return '无动画';
      case 'slide':
        return '上下滑动';
      case 'curl':
        return '仿真翻页';
      default:
        return k;
    }
  }

  Widget _colorChip(String hex, String name) {
    final color = Color(int.parse(hex.replaceFirst('#', 'FF'), radix: 16));
    return InkWell(
      onTap: () {
        context.read<SettingsService>().setBgColor(hex);
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: color,
              border: Border.all(color: Colors.grey.shade400),
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          const SizedBox(height: 4),
          Text(name, style: const TextStyle(fontSize: 11)),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  const _Section({required this.title});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: Colors.grey.shade600,
        ),
      ),
    );
  }
}
