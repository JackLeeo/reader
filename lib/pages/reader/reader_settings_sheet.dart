// 阅读器设置面板（字号、行距、主题）
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/settings_service.dart';
import '../../utils/extensions.dart';

void showReaderSettings(BuildContext context) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (_) => const _ReaderSettingsSheet(),
  );
}

class _ReaderSettingsSheet extends StatelessWidget {
  const _ReaderSettingsSheet();

  static const _themes = [
    ('#FFF8E1', '#3E2723', '羊皮纸'),
    ('#FFFFFF', '#212121', '白底黑字'),
    ('#E8F5E9', '#1B5E20', '护眼绿'),
    ('#FCE4EC', '#880E4F', '樱花粉'),
    ('#263238', '#ECEFF1', '暗夜'),
    ('#000000', '#B0BEC5', '纯黑'),
  ];

  @override
  Widget build(BuildContext context) {
    return Consumer<SettingsService>(
      builder: (context, settings, _) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text('阅读设置', style: context.textStyles.titleMedium),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text('字号: ${settings.fontSize.toStringAsFixed(0)}',
                    style: context.textStyles.bodySmall),
                Slider(
                  value: settings.fontSize,
                  min: 12,
                  max: 32,
                  divisions: 20,
                  onChanged: settings.setFontSize,
                ),
                const SizedBox(height: 8),
                Text('行距: ${settings.lineHeight.toStringAsFixed(1)}',
                    style: context.textStyles.bodySmall),
                Slider(
                  value: settings.lineHeight,
                  min: 1.2,
                  max: 2.4,
                  divisions: 12,
                  onChanged: settings.setLineHeight,
                ),
                const SizedBox(height: 12),
                Text('主题', style: context.textStyles.bodySmall),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    for (final (bg, fg, name) in _themes)
                      _ThemeChip(
                        bg: _parseHex(bg),
                        fg: _parseHex(fg),
                        name: name,
                        selected: settings.bgColor == bg,
                        onTap: () {
                          settings.setBgColor(bg);
                          settings.setTextColor(fg);
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        );
      },
    );
  }

  Color _parseHex(String hex) {
    var h = hex.replaceFirst('#', '');
    if (h.length == 6) h = 'FF$h';
    return Color(int.parse(h, radix: 16));
  }
}

class _ThemeChip extends StatelessWidget {
  final Color bg;
  final Color fg;
  final String name;
  final bool selected;
  final VoidCallback onTap;

  const _ThemeChip({
    required this.bg,
    required this.fg,
    required this.name,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 64,
        height: 64,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? context.colors.primary : Colors.transparent,
            width: 2,
          ),
        ),
        child: Center(
          child: Text(
            '字',
            style: TextStyle(color: fg, fontSize: 22, fontWeight: FontWeight.w600),
          ),
        ),
      ),
    );
  }
}
