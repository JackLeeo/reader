import 'package:flutter/material.dart';

import '../../book_source/models/book_source.dart';
import '../../book_source/services/book_source_service.dart';

/// 书源「对比导入」共享交互。
///
/// 展示每条导入源在库内的差异（新增 / 更新 / 与库内一致），用户勾选后
/// 批量应用并落盘。返回实际导入/更新的条数；取消或全被勾选为“一致”时返回 null。
class SourceImportPreview {
  /// 弹窗让用户选择要导入的书源，选中后应用并保存。
  /// 返回 null 表示用户取消 / 无可导入项；否则返回实际写入数。
  static Future<int?> show(
      BuildContext context, List<BookSource> incoming) async {
    final svc = BookSourceService.instance;
    final diffs = svc.diffImport(incoming);
    // 默认全部勾选；已在库且完全一致的不主动勾选。
    final checked = <SourceImportDiff>{
      for (final d in diffs) if (!d.identical) d,
    };

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => AlertDialog(
          title: Text('对比导入（${diffs.length} 个）'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final d in diffs)
                  CheckboxListTile(
                    dense: true,
                    value: checked.contains(d),
                    controlAffinity: ListTileControlAffinity.leading,
                    title: Text(d.incoming.bookSourceName,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                      d.isNew
                          ? '新增'
                          : d.identical
                              ? '与库内一致'
                              : '更新「${d.existing!.bookSourceName}」',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    secondary: Icon(
                      d.identical
                          ? Icons.check_circle_outline
                          : d.isNew
                              ? Icons.add_circle_outline
                              : Icons.update,
                      color: d.identical ? Colors.grey : null,
                    ),
                    onChanged: (v) {
                      setSheet(() {
                        if (v == true) {
                          checked.add(d);
                        } else {
                          checked.remove(d);
                        }
                      });
                    },
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => setSheet(() => checked.addAll(diffs)),
              child: const Text('全选'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(ctx, checked.any((d) => !d.identical)),
              child: Text('导入 ${checked.length} 个'),
            ),
          ],
        ),
      ),
    );
    if (confirmed == null || !confirmed) return null;

    final toApply = checked.where((d) => !d.identical).toList();
    if (toApply.isEmpty) return null;
    final n = svc.applyImportDiffs(toApply);
    await svc.save();
    return n;
  }
}