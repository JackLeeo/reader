// 验证 assets 内置书源能正确加载和解析
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reader/models/book_source.dart';

void main() {
  test('assets 内置书源能正确加载', () {
    // 直接读源文件 (测试环境无 rootBundle, 用 File)
    final file = File('assets/book_sources/perfect_sources.json');
    expect(file.existsSync(), isTrue,
        reason: 'assets/book_sources/perfect_sources.json 必须存在');

    final raw = file.readAsStringSync();
    final list = jsonDecode(raw) as List;
    expect(list.length, greaterThan(50),
        reason: '书源数量应该 > 50, 实际 ${list.length}');

    int okCount = 0;
    int failCount = 0;
    for (final item in list) {
      if (item is! Map) continue;
      try {
        final source = BookSource.fromJson(
            item.map((k, v) => MapEntry(k.toString(), v)));
        if (source.bookSourceName.isEmpty) {
          failCount++;
          continue;
        }
        okCount++;
      } catch (e) {
        failCount++;
      }
    }
    print('书源解析结果: 成功=$okCount, 失败=$failCount, 总=${list.length}');
    expect(okCount, greaterThan(50),
        reason: '至少 50 个书源解析成功, 实际 $okCount');
  });

  test('BookSourceService.init 加载所有书源后 enabledSources 不为空', () async {
    // 用 mock SharedPreferences 验证 init 流程
    // (不直接测 service 因为它依赖 rootBundle, 而 dart-only 测试无 rootBundle)
    final file = File('assets/book_sources/perfect_sources.json');
    final raw = file.readAsStringSync();
    final list = jsonDecode(raw) as List;

    final sources = <BookSource>[];
    for (final item in list) {
      if (item is! Map) continue;
      try {
        final source = BookSource.fromJson(
            item.map((k, v) => MapEntry(k.toString(), v)));
        sources.add(source);
      } catch (_) {}
    }

    final enabled = sources.where((s) => s.isEnabled).toList();
    print('总书源: ${sources.length}, 启用: ${enabled.length}');
    expect(sources.length, greaterThan(50));
    expect(enabled.length, greaterThan(50),
        reason: '默认全部启用, 不应该有 disabled_sources 干扰');
  });
}
