import 'package:flutter_test/flutter_test.dart';
import 'package:legado_flutter/book_source/services/webdav_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
  });

  group('WebDavService 配置持久化', () {
    test('默认未配置 / 保存后可读回', () async {
      final s = WebDavService.instance;
      await s.init();
      expect(s.isConfigured, false);

      await s.saveConfig(WebDavConfig(
        server: 'https://dav.example.com/',
        username: 'u',
        password: 'p',
        webdavDir: '/Legado/',
      ));
      expect(s.isConfigured, true);
      expect(s.config.server, 'https://dav.example.com/');
      expect(s.config.webdavDir, '/Legado/');
    });

    test('isConfigured 要求合法 URL', () {
      expect(WebDavConfig(server: '').isConfigured, false);
      expect(WebDavConfig(server: 'dav.example.com').isConfigured, false);
      expect(
          WebDavConfig(server: 'https://dav.example.com/').isConfigured, true);
    });
  });

  group('WebDavClient PROPFIND 解析', () {
    test('解析标准 207 XML（含命名空间前缀）', () {
      const xml = '''<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/Legado/</d:href>
    <d:propstat>
      <d:prop>
        <d:displayname>Legado</d:displayname>
        <d:getcontentlength>0</d:getcontentlength>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
  <d:response>
    <d:href>/Legado/legado_backup_1700000000000.json</d:href>
    <d:propstat>
      <d:prop>
        <d:displayname>legado_backup_1700000000000.json</d:displayname>
        <d:getcontentlength>12345</d:getcontentlength>
        <d:getlastmodified>2023-11-14T12:00:00Z</d:getlastmodified>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>''';
      final items = WebDavClient.parseMultistatus(
          xml, Uri.parse('https://dav.example.com/Legado/'));
      expect(items.length, 1);
      expect(items.single.name, 'legado_backup_1700000000000.json');
      expect(items.single.size, 12345);
      expect(items.single.modified, DateTime.utc(2023, 11, 14, 12));
    });

    test('无命名空间前缀也能解析', () {
      const xml = '''<multistatus xmlns="DAV:">
<response><href>/dir/a.json</href>
<propstat><prop><displayname>a.json</displayname>
<getcontentlength>10</getcontentlength></prop>
<status>HTTP/1.1 200 OK</status></propstat></response>
</multistatus>''';
      final items = WebDavClient.parseMultistatus(
          xml, Uri.parse('https://x.example/dir/'));
      expect(items.single.name, 'a.json');
      expect(items.single.size, 10);
    });
  });
}
