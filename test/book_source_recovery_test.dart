// 测试 BookSourceService 自我修复机制
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/services/book_source_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('自我修复: 所有内置书源被禁用时, init() 自动恢复', () async {
    // 模拟老用户场景: 之前 _invalidAutoDisable=true 自动禁用了所有内置源
    // 持久化里存了所有 source id
    final svc = BookSourceService();
    // 预禁用: 模拟 _loadFromPrefs 读 prefs 之前先打个底
    // 但 _loadFromPrefs 会自动从 prefs 读 disabled_sources
    // 没法直接 mock, 改用 prefs.setStringList 后再 init
    final prefs = await SharedPreferences.getInstance();
    // 1. 先初始化一次拿到所有内置源
    await svc.init();
    final allIds = svc.sources.map((s) => s.id).toList();
    expect(allIds.length, greaterThan(50),
        reason: '内置源数应 > 50, 实际 ${allIds.length}');
    // 2. 全部禁用
    await prefs.setStringList('disabled_sources', allIds);
    // 3. 重新 init 触发自我修复
    final svc2 = BookSourceService();
    await svc2.init();
    // 4. 验证全部启用
    final enabledCount = svc2.sources.where((s) => s.isEnabled).length;
    print('自我修复后启用数: $enabledCount / ${svc2.sources.length}');
    expect(enabledCount, svc2.sources.length,
        reason: '自我修复后所有内置源应被启用');
    // 5. 验证 disabled_sources 已被清空
    final disabledAfter = prefs.getStringList('disabled_sources') ?? [];
    expect(disabledAfter, isEmpty,
        reason: '修复后 disabled_sources 应被清空');
  });

  test('自我修复: 用户主动只禁用少数书源时不触发', () async {
    final svc = BookSourceService();
    await svc.init();
    final allIds = svc.sources.map((s) => s.id).toList();
    // 模拟用户只手动禁了 3 个
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('disabled_sources',
        allIds.take(3).toList());
    final svc2 = BookSourceService();
    await svc2.init();
    // 验证只有 3 个被禁用, 其余启用
    final disabledCount =
        svc2.sources.where((s) => !s.isEnabled).length;
    print('禁用数: $disabledCount (不应被自我修复改)');
    expect(disabledCount, 3,
        reason: '只禁用 3 个不应触发自我修复');
    final enabledCount =
        svc2.sources.where((s) => s.isEnabled).length;
    expect(enabledCount, svc2.sources.length - 3);
  });

  test('正常场景: 所有书源默认启用, 不触发修复', () async {
    final svc = BookSourceService();
    await svc.init();
    final enabledCount = svc.sources.where((s) => s.isEnabled).length;
    print('正常初始化启用数: $enabledCount / ${svc.sources.length}');
    expect(enabledCount, svc.sources.length);
  });
}
