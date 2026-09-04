import '../models/book_source.dart';
import 'cookie_service.dart';

/// 登录域解析：从书源地址提取 host（cookie 按域名存储）。
String loginDomainOf(BookSource source) {
  final m = RegExp(r'^https?://([^/]+)').firstMatch(source.bookSourceUrl);
  if (m == null) return '';
  return m.group(1)!;
}

/// 书源登录闭环（对应官方 `LoginActivity` + `loginCheckJs`）。
///
/// 复杂 JS 源（登录后才能抓取）流程：
/// 1. [needsLogin] 判断该源是否需要 WebView 登录（配置了 loginUrl/loginCheckJs
///    且本机尚无该域名的持久 cookie）。
/// 2. 由 WebView 页加载 [loginUrl]，用户在浏览器内完成登录。
/// 3. 完成后调用 [evaluateCheck] 执行 loginCheckJs 检测是否已登录；通过则
///    [captureDocumentCookie] 把 `document.cookie` 写入 [CookieService] 持久化。
/// 4. 后续书源请求在 [HttpService] 自动带上持久 cookie。
class LoginService {
  LoginService._();

  static final LoginService instance = LoginService._();

  /// 是否配置了登录（有 loginUrl 且有检测脚本）。
  bool canLogin(BookSource source) =>
      (source.loginUrl?.trim().isNotEmpty ?? false) &&
      (source.loginCheckJs?.trim().isNotEmpty ?? false);

  /// 是否已处于登录态。
  ///
  /// 稳健做法：只要该域名已有持久 cookie 即视为已登录（不阻塞阅读）。
  /// 真实 DOM 级 loginCheckJs 检测需在 WebView 内执行，无法在本层精确求值。
  bool isLoggedIn(BookSource source) =>
      CookieService.instance.hasCookie(loginDomainOf(source));

  /// 执行 loginCheckJs 检测登录态。
  ///
  /// DOM 相关的检测脚本必须运行在 WebView 页面上下文；这里不做不可靠模拟，
  /// 以“已有该域名 cookie”作为可复用的判定结果。
  bool evaluateCheck(BookSource source) =>
      CookieService.instance.hasCookie(loginDomainOf(source));

  /// 从 `document.cookie` 字符串解析并持久化到 [CookieService]。
  ///
  /// [cookieStr] 形如 `k1=v1; k2=v2`（`document.cookie` 输出）。多段按
  /// `;` 拆开，`=` 前为名、剩余为值，忽略属性段。
  Future<void> captureDocumentCookie(BookSource source, String cookieStr) async {
    final domain = loginDomainOf(source);
    if (domain.isEmpty) return;
    await CookieService.instance.setCookiesFromString(domain, cookieStr);
  }

  /// 抓取登录页时在 WebView 内执行的 JS，返回 `document.cookie`。
  String get captureCookieJs => 'document.cookie';
}

/// HttpService 接入持久 Cookie 的辅助。
///
/// 仅当请求携带 [BookSource] 且 `enabledCookieJar` 开启（默认）时采用：
/// - [seedPersistentCookie] 返回该 host 的持久 cookie 请求头（无则 null）；
/// - [persistResponseCookies] 把响应 `set-cookie` 回写持久 CookieJar。
class PersistentCookie {
  /// 生成请求态 cookie 头字符串；该宿主无持久 cookie 时返回 null。
  static String? seed(BookSource? source, String host) {
    if (source == null || source.enabledCookieJar == false) return null;
    final header = CookieService.instance.cookieHeaderFor(host);
    return header.isEmpty ? null : header;
  }

  /// 回写响应 Set-Cookie 头到持久 CookieJar。
  static void persist(BookSource? source, String host, List<String> setCookies) {
    if (source == null || source.enabledCookieJar == false) return;
    if (setCookies.isEmpty) return;
    CookieService.instance.setCookiesFromHeader(host, setCookies);
  }
}