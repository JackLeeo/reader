import 'package:flutter_test/flutter_test.dart';
import 'package:legado_flutter/book_source/help/audio_engine.dart';
import 'package:legado_flutter/book_source/models/book_source.dart';
import 'package:legado_flutter/book_source/services/cookie_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    CookieService.instance.reset();
  });

  group('CookieService', () {
    test('设置/读取/Cookie 请求头', () async {
      final s = CookieService.instance;
      await s.init();
      await s.setCookie('a.example.com', 'sid', 'abc');
      await s.setCookie('a.example.com', 'uid', '1');

      expect(s.hasCookie('a.example.com'), true);
      expect(s.cookieHeaderFor('a.example.com'), 'sid=abc; uid=1');
      expect(s.domains, ['a.example.com']);
    });

    test('从 Set-Cookie 响应头解析保存', () async {
      final s = CookieService.instance;
      await s.init();
      await s.setCookiesFromHeader('b.example.com', [
        'token=xyz; Path=/; HttpOnly',
        'lang=zh; Path=/',
      ]);
      expect(s.cookieHeaderFor('b.example.com'), 'token=xyz; lang=zh');
    });

    test('删除与清空', () async {
      final s = CookieService.instance;
      await s.init();
      await s.setCookie('a.com', 'x', '1');
      await s.setCookie('a.com', 'y', '2');
      await s.deleteCookie('a.com', 'x');
      expect(s.cookieHeaderFor('a.com'), 'y=2');

      await s.clearAll();
      expect(s.domains, isEmpty);
    });

    test('持久化往返', () async {
      final s = CookieService.instance;
      await s.init();
      await s.setCookie('c.com', 'k', 'v');

      s.reset();
      await s.init();
      expect(s.cookieHeaderFor('c.com'), 'k=v');
    });
  });

  group('AudioEngine', () {
    test('无附加内容原样返回', () {
      expect(AudioEngine.buildPlayableUrl('https://x.example/a.mp3'), 'https://x.example/a.mp3');
    });

    test('注入 referer / userAgent / cookie', () {
      final out = AudioEngine.buildPlayableUrl(
        'https://x.example/a.mp3',
        referer: 'https://book.example/',
        userAgent: 'UA/1.0',
        cookie: 'sid=1',
      );
      expect(out, contains('referer=https%3A%2F%2Fbook.example%2F'));
      expect(out, contains('userAgent=UA%2F1.0'));
      expect(out, contains('cookie=sid%3D1'));
    });

    test('已有参数不覆盖', () {
      final out = AudioEngine.buildPlayableUrl(
        'https://x.example/a.mp3?cookie=keep',
        cookie: 'new=1',
      );
      expect(out, contains('cookie=keep'));
      expect(out, isNot(contains('new=1')));
    });

    test('buildSourcePlayableUrl 合并书源头 + 持久化 Cookie', () async {
      final s = CookieService.instance;
      await s.init();
      await s.setCookie('cdn.example.com', 'token', 'T1');

      final source = BookSource(
        bookSourceUrl: 'https://book.example/api.json',
        bookSourceName: '源',
        bookSourceType: 1,
        header: 'Referer: https://book.example/\nUser-Agent: UA-X',
        enabledCookieJar: true,
      );
      final out = AudioEngine.buildSourcePlayableUrl(
          'https://cdn.example.com/audio.mp3', source);
      expect(out, contains('referer=https%3A%2F%2Fbook.example%2F'));
      expect(out, contains('userAgent=UA-X'));
      expect(out, contains('cookie=token%3DT1'));
    });

    test('enabledCookieJar=false 不带 Cookie', () async {
      final source = BookSource(
        bookSourceUrl: 'https://b.example/api.json',
        bookSourceName: '源',
        bookSourceType: 1,
        enabledCookieJar: false,
      );
      final out = AudioEngine.buildSourcePlayableUrl(
          'https://cdn.example.com/audio.mp3', source);
      expect(out, isNot(contains('cookie=')));
    });

    test('base64 音频解码', () {
      // "hello" 的 base64。
      expect(AudioEngine.isBase64Audio('aGVsbG8='), true);
      expect(AudioEngine.decodeIfBase64('aGVsbG8='), 'hello');
      expect(AudioEngine.decodeIfBase64('https://x.example/a.mp3'),
          'https://x.example/a.mp3');
    });
  });
}
