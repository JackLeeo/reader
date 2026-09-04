import 'package:flutter_test/flutter_test.dart';
import 'package:legado_flutter/book_source/services/proxy_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    ProxyService.instance.reset();
  });

  group('ProxyService', () {
    test('默认关闭，directive 为 DIRECT', () async {
      final s = ProxyService.instance;
      await s.init();
      expect(s.enabled, false);
      expect(s.isConfigured, false);
      expect(s.proxyDirective, 'DIRECT');
    });

    test('保存并启用后 directive 正确', () async {
      final s = ProxyService.instance;
      await s.init();
      await s.save(enabled: true, host: '127.0.0.1', port: 7890);
      expect(s.isConfigured, true);
      expect(s.proxyDirective, 'PROXY 127.0.0.1:7890');
    });

    test('非法端口视为未配置', () async {
      final s = ProxyService.instance;
      await s.init();
      await s.save(enabled: true, host: '127.0.0.1', port: 99999);
      expect(s.isConfigured, false);
      expect(s.proxyDirective, 'DIRECT');
    });

    test('持久化往返', () async {
      final s = ProxyService.instance;
      await s.init();
      await s.save(enabled: true, host: 'proxy.example.com', port: 8080);

      s.reset();
      await s.init();
      expect(s.enabled, true);
      expect(s.host, 'proxy.example.com');
      expect(s.port, 8080);
    });
  });
}
