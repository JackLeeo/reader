import 'package:flutter_test/flutter_test.dart';
import 'package:legado_flutter/book_source/models/book_source.dart';
import 'package:legado_flutter/book_source/services/cookie_service.dart';
import 'package:legado_flutter/book_source/services/login_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  test('loginDomainOf 从书源 URL 提取 host', () {
    final src = BookSource(
      bookSourceUrl: 'https://example.com/custom/api',
      bookSourceName: '测试',
    );
    expect(loginDomainOf(src), 'example.com');
  });

  test('loginDomainOf 无协议返回空串', () {
    final src = BookSource(bookSourceUrl: 'legado://local', bookSourceName: 'x');
    expect(loginDomainOf(src), '');
  });

  test('canLogin 需同时配置 loginUrl 与 loginCheckJs', () {
    final no = BookSource(
      bookSourceUrl: 'https://a.com',
      bookSourceName: 'a',
      loginUrl: 'https://a.com/login',
    );
    final yes = BookSource(
      bookSourceUrl: 'https://a.com',
      bookSourceName: 'a',
      loginUrl: 'https://a.com/login',
      loginCheckJs: 'document.cookie.length>0',
    );
    expect(LoginService.instance.canLogin(no), false);
    expect(LoginService.instance.canLogin(yes), true);
  });

  test('captureDocumentCookie 解析 document.cookie 并持久化', () async {
    CookieService.instance.reset();
    await CookieService.instance.init();
    final src = BookSource(
      bookSourceUrl: 'https://m.some.site/book',
      bookSourceName: 's',
    );
    await LoginService.instance.captureDocumentCookie(
      src,
      'token=abcd1234; Path=/; userId=88',
    );
    expect(LoginService.instance.isLoggedIn(src), isTrue);
    final h = CookieService.instance.cookieHeaderFor('m.some.site');
    expect(h, contains('token=abcd1234'));
    expect(h, contains('userId=88'));
  });

  test('setCookiesFromString 忽略属性段', () async {
    CookieService.instance.reset();
    await CookieService.instance.init();
    await CookieService.instance.setCookiesFromString(
      'h.com',
      'sid=x; Domain=h.com; Path=/; Expires=Wed, 21 Oct; Max-Age=3600; HttpOnly; Secure; SameSite=Lax',
    );
    final m = CookieService.instance.cookiesFor('h.com');
    expect(m.containsKey('sid'), isTrue);
    expect(m.containsKey('Domain'), isFalse);
    expect(m.containsKey('Path'), isFalse);
    expect(m.containsKey('HttpOnly'), isFalse);
    CookieService.instance.reset();
  });
}