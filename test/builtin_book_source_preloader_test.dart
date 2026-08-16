// 文件说明：内置书源预装服务回归测试，验证随包资产可加载、可解析、
// 可导入注册表，防止资产路径或解析链路被无意破坏。
// 技术要点：flutter_test rootBundle、SharedPreferences mock。

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xxread/book_sources/services/book_source_registry.dart';
import 'package:xxread/book_sources/services/builtin_book_source_preloader.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => SharedPreferences.setMockInitialValues({}));

  test('preloads runnable builtin sources into the registry once', () async {
    SharedPreferences.setMockInitialValues({});
    final registry = BookSourceRegistry();

    await BuiltinBookSourcePreloader.ensurePreloaded(registry: registry);

    final sources = await registry.load();
    expect(sources, isNotEmpty);
    expect(
      sources.every((source) => source.enabled),
      isTrue,
      reason: '内置书源应默认启用且通过可运行性筛选',
    );

    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getBool('builtin_book_sources_preloaded_v1'), isTrue);

    // 第二次调用应直接跳过：清空注册表后重新预装不应再次导入。
    await preferences.setString('open_reading_book_sources_v1', '[]');
    await BuiltinBookSourcePreloader.ensurePreloaded(registry: registry);
    expect(await registry.load(), isEmpty);
  });
}
