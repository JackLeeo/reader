import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:legado_flutter/book_source/services/rule_subscription_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    RuleSubscriptionService.instance.reset();
  });

  group('RuleSubscriptionService 订阅管理', () {
    test('增删 + 持久化往返', () async {
      final s = RuleSubscriptionService.instance;
      await s.init();

      s.add(RuleSubscription(url: 'https://a.example/x.json', name: 'A'));
      s.add(RuleSubscription(url: 'https://b.example/y.json', name: 'B'));
      expect(s.items.length, 2);

      s.remove('https://a.example/x.json');
      expect(s.items.length, 1);
      await s.save();

      // 重置后重新 init，从 prefs 恢复。
      s.reset();
      await s.init();
      expect(s.items.single.url, 'https://b.example/y.json');
    });

    test('重复 URL 幂等更新', () async {
      final s = RuleSubscriptionService.instance;
      await s.init();
      s.add(RuleSubscription(url: 'https://a.example/x.json', name: 'A'));
      s.add(RuleSubscription(
          url: 'https://a.example/x.json',
          name: 'A2',
          lastFetchTime: 123));
      expect(s.items.length, 1);
      expect(s.items.single.lastFetchTime, 123);
    });
  });

  group('parseBookSources', () {
    test('纯数组', () {
      final list = RuleSubscriptionService.parseBookSources(jsonDecode('''
[{"bookSourceUrl":"https://a.example/api.json","bookSourceName":"源A","enabled":true}]
'''));
      expect(list.length, 1);
      expect(list.single.bookSourceName, '源A');
    });

    test('带 bookSources 包装', () {
      final list = RuleSubscriptionService.parseBookSources(jsonDecode('''
{"bookSources":[{"bookSourceUrl":"https://b.example/api.json","bookSourceName":"源B"}]}
'''));
      expect(list.single.bookSourceName, '源B');
    });

    test('单对象', () {
      final list = RuleSubscriptionService.parseBookSources(
          jsonDecode('{"bookSourceUrl":"https://c.example/api.json","bookSourceName":"源C"}'));
      expect(list.single.bookSourceName, '源C');
    });

    test('空 / 非法项被忽略', () {
      expect(RuleSubscriptionService.parseBookSources(jsonDecode('[]')), isEmpty);
      expect(RuleSubscriptionService.parseBookSources(jsonDecode('{}')), isEmpty);
    });
  });
}
