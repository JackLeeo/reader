import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:gbk_codec/gbk_codec.dart';

import '../../utils/fast_gbk_decoder.dart';
import '../protocol/book_source_protocol.dart';
import '../services/book_source_network_policy.dart';
import 'legado_cookie_jar.dart';

enum LegadoRequestMethod { get, post }

class LegadoRequestTemplate {
  const LegadoRequestTemplate({
    required this.url,
    required this.method,
    required this.headers,
    required this.charset,
    this.body,
    this.referer,
  });

  final Uri url;
  final LegadoRequestMethod method;
  final Map<String, String> headers;
  final String charset;
  final String? body;

  /// 页面链路的来源页地址（目录页 Referer=详情页、正文页
  /// Referer=目录页）。防盗链站点校验 Referer，缺失直接 403。
  /// 仅当书源 headers 未显式声明 Referer 时在发送层补上。
  final String? referer;

  static LegadoRequestTemplate parse(
    String template, {
    required Uri baseUri,
    Map<String, String> variables = const {},
    Map<String, String> sourceHeaders = const {},
    String? referer,
  }) {
    final expanded = _expandVariables(template.trim(), variables);
    if (_unresolvedVariables.hasMatch(expanded)) {
      throw const BookSourceProtocolException(
        'Legado request contains an unsupported template expression.',
      );
    }
    if (_unresolvedGetSyntax.hasMatch(expanded)) {
      throw const BookSourceProtocolException(
        'Legado request references an unknown source variable '
        '(@get:{...}); run a search first to populate it.',
      );
    }
    if (_unsupportedRequestSyntax.hasMatch(expanded)) {
      throw const BookSourceProtocolException(
        'Legado request uses scripting, which is not supported.',
      );
    }
    if (expanded.isEmpty) {
      throw const BookSourceProtocolException('Legado request URL is empty.');
    }

    var urlText = expanded;
    var options = const <String, dynamic>{};
    final optionsStart = expanded.lastIndexOf(',{');
    if (optionsStart >= 0) {
      final candidate = expanded.substring(optionsStart + 1).trim();
      try {
        final decoded = _decodeOptions(candidate);
        if (decoded is! Map) throw const FormatException();
        options = decoded.map((key, value) => MapEntry('$key', value));
        urlText = expanded.substring(0, optionsStart).trim();
      } on FormatException {
        throw const BookSourceProtocolException(
          'Legado request options must be a JSON object.',
        );
      }
    }

    final uri = baseUri.resolve(urlText);
    if (!uri.hasAuthority || (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw const BookSourceProtocolException(
        'Legado request targets must use HTTP or HTTPS.',
      );
    }

    final methodText = '${options['method'] ?? 'GET'}'.trim().toUpperCase();
    final method = switch (methodText) {
      'GET' => LegadoRequestMethod.get,
      'POST' => LegadoRequestMethod.post,
      _ => throw BookSourceProtocolException(
        'Unsupported Legado request method: $methodText.',
      ),
    };
    final body = options['body'];
    if (body != null && body is! String) {
      throw const BookSourceProtocolException(
        'Legado request body must be text.',
      );
    }
    if (method == LegadoRequestMethod.get &&
        body is String &&
        body.isNotEmpty) {
      throw const BookSourceProtocolException(
        'GET Legado requests cannot contain a body.',
      );
    }

    final headers = <String, String>{};
    for (final entry in sourceHeaders.entries) {
      final name = entry.key.trim();
      if (name.isEmpty || _forbiddenHeaders.contains(name.toLowerCase())) {
        throw BookSourceProtocolException(
          'Legado request header is not allowed: $name.',
        );
      }
      headers[name] = entry.value;
    }
    final optionHeaders = options['headers'];
    if (optionHeaders != null) {
      Object? normalizedHeaders = optionHeaders;
      if (normalizedHeaders is String) {
        try {
          normalizedHeaders = _decodeOptions(normalizedHeaders);
        } on FormatException {
          throw const BookSourceProtocolException(
            'Legado request headers must be valid JSON.',
          );
        }
      }
      if (normalizedHeaders is! Map) {
        throw const BookSourceProtocolException(
          'Legado request headers must be an object.',
        );
      }
      for (final entry in normalizedHeaders.entries) {
        final name = '${entry.key}'.trim();
        final value = entry.value;
        if (name.isEmpty || value is! String) {
          throw const BookSourceProtocolException(
            'Legado request headers must contain text values.',
          );
        }
        if (_forbiddenHeaders.contains(name.toLowerCase())) {
          throw BookSourceProtocolException(
            'Legado request header is not allowed: $name.',
          );
        }
        headers[name] = value;
      }
    }
    // 部分书源显式写 "charset": ""，空值与未声明一样回退 utf-8；
    // "escape" 是 Legado 的 URL 参数编码方式而非字符集，按 utf-8 处理。
    final charset = '${options['charset'] ?? ''}'.trim().toLowerCase();
    final effectiveCharset = charset.isEmpty || charset == 'escape'
        ? 'utf-8'
        : charset;
    if (!_supportedCharsets.contains(effectiveCharset)) {
      throw BookSourceProtocolException(
        'Unsupported Legado request charset: $effectiveCharset.',
      );
    }
    if (method == LegadoRequestMethod.post &&
        !headers.keys.any((name) => name.toLowerCase() == 'content-type')) {
      headers['Content-Type'] =
          'application/x-www-form-urlencoded; charset=$effectiveCharset';
    }
    return LegadoRequestTemplate(
      url: uri,
      method: method,
      headers: Map.unmodifiable(headers),
      charset: effectiveCharset,
      body: body as String?,
      referer: referer,
    );
  }
}

Object? _decodeOptions(String input) {
  try {
    return jsonDecode(input);
  } on FormatException {
    // Historical source files often use JavaScript-style single-quoted object
    // literals. Normalize only quoted strings and object keys; expressions,
    // functions, comments and other executable syntax remain invalid.
    if (input.contains('`') ||
        input.contains(RegExp(r'\b(function|return|new)\b')) ||
        input.contains('//') ||
        input.contains('/*')) {
      rethrow;
    }
    final buffer = StringBuffer();
    var inSingle = false;
    var inDouble = false;
    var escaped = false;
    for (var index = 0; index < input.length; index++) {
      final char = input[index];
      if (escaped) {
        buffer.write(char == '"' && inSingle ? r'\"' : char);
        escaped = false;
        continue;
      }
      if (char == r'\') {
        buffer.write(char);
        escaped = true;
        continue;
      }
      if (char == '"' && !inSingle) {
        inDouble = !inDouble;
        buffer.write(char);
        continue;
      }
      if (char == "'" && !inDouble) {
        inSingle = !inSingle;
        buffer.write('"');
        continue;
      }
      if (inSingle && char == '"') {
        buffer.write(r'\"');
      } else {
        buffer.write(char);
      }
    }
    if (inSingle) throw const FormatException('Unterminated quoted string.');
    return jsonDecode(buffer.toString());
  }
}

class LegadoResponse {
  const LegadoResponse({required this.body, required this.finalUri});

  final String body;
  final Uri finalUri;
}

abstract interface class LegadoTransport {
  Future<LegadoResponse> send(LegadoRequestTemplate request);
}

class LegadoHttpTransport implements LegadoTransport {
  LegadoHttpTransport({
    Dio? dio,
    BookSourceNetworkPolicy networkPolicy = const BookSourceNetworkPolicy(
      allowSyntheticDns: true,
    ),
    this.maxResponseBytes = 8 * 1024 * 1024,
    this.requestTimeout = const Duration(seconds: 12),
  }) : _networkPolicy = networkPolicy,
       _dio = dio ?? _createDio(networkPolicy, requestTimeout);

  final Dio _dio;
  final BookSourceNetworkPolicy _networkPolicy;
  final int maxResponseBytes;
  final Duration requestTimeout;

  static Dio _createDio(
    BookSourceNetworkPolicy policy,
    Duration requestTimeout,
  ) {
    final dio = Dio(
      BaseOptions(
        connectTimeout: requestTimeout,
        receiveTimeout: requestTimeout,
        sendTimeout: requestTimeout,
      ),
    );
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: policy.createPinnedHttpClient,
    );
    return dio;
  }

  void close({bool force = true}) => _dio.close(force: force);

  @override
  Future<LegadoResponse> send(LegadoRequestTemplate request) async {
    var current = request.url;
    // HTTP 语义 + yuedu_hd 行为：POST 遇 301/302/303 重定向改 GET 重发
    // （表单提交后跳转型站点的搜索依赖此行为）。
    var method = request.method;
    String? body = request.body;
    for (var redirects = 0; redirects <= 5; redirects++) {
      await _networkPolicy.validate(current);
      // CookieJar：书源自带 Cookie 与存储的 Cookie 合并回传，并保存 Set-Cookie。
      final jar = LegadoCookieJar.instance;
      final manualCookie = request.headers.entries
          .where((entry) => entry.key.toLowerCase() == 'cookie')
          .map((entry) => entry.value)
          .join('; ');
      final mergedHeaders = Map<String, String>.of(request.headers)
        ..removeWhere((name, _) => name.toLowerCase() == 'cookie');
      // 默认浏览器头栈：大量站点对"裸请求"（缺 Accept/UA/AL）直接 403
      // 或返回反爬验证页。逐个判断，源没声明才补默认值。
      if (!mergedHeaders.keys.any(
        (name) => name.toLowerCase() == 'user-agent',
      )) {
        mergedHeaders['User-Agent'] = defaultLegadoUserAgent;
      }
      if (!mergedHeaders.keys.any(
        (name) => name.toLowerCase() == 'accept',
      )) {
        mergedHeaders['Accept'] =
            'text/html,application/xhtml+xml,application/xml;q=0.9,'
            'image/avif,image/webp,*/*;q=0.8';
      }
      if (!mergedHeaders.keys.any(
        (name) => name.toLowerCase() == 'accept-language',
      )) {
        mergedHeaders['Accept-Language'] = 'zh-CN,zh;q=0.9,en;q=0.7';
      }
      // 防盗链 Referer：目录/正文页常校验来源页，缺失直接 403。
      // 书源 headers 显式声明的 Referer 优先，不被覆盖。
      if (request.referer != null &&
          request.referer!.isNotEmpty &&
          !mergedHeaders.keys.any((name) => name.toLowerCase() == 'referer')) {
        mergedHeaders['Referer'] = request.referer!;
      }
      final cookieHeader = jar.headerFor(current, manualCookie: manualCookie);
      if (cookieHeader.isNotEmpty) mergedHeaders['Cookie'] = cookieHeader;
      Response<List<int>>? response;
      try {
        response = await _attempt(
          current,
          request,
          method,
          body,
          mergedHeaders,
        );
      } on DioException catch (error) {
        // 连接类失败重试一次：聚合并发下的偶发连接被拒/超时。
        if (!_isRetryableConnectionError(error)) {
          _rethrowRequestException(error, current);
        }
        await Future<void>.delayed(const Duration(milliseconds: 300));
        try {
          response = await _attempt(
            current,
            request,
            method,
            body,
            mergedHeaders,
          );
        } on DioException catch (error) {
          _rethrowRequestException(error, current);
        }
      }
      jar.storeFromResponse(
        current,
        response.headers.map['set-cookie'] ?? const [],
      );
      final status = response.statusCode ?? 0;
      if (status < 300) {
        final bytes = response.data ?? const <int>[];
        if (bytes.length > maxResponseBytes) {
          throw BookSourceProtocolException(
            'Legado response exceeds $maxResponseBytes bytes.',
          );
        }
        return LegadoResponse(
          body: _decode(bytes, request.charset, response.headers),
          finalUri: current,
        );
      }
      // 4xx/5xx 不再静默吞响应体：把 body（最多 200 字符，去掉空白）拼入
      // 错误消息，让用户能一眼判断是 Cloudflare 挑战页、站点关站还是
      // 登录态失效，而不是一个干巴巴的 "HTTP 404"。
      if (status >= 400) {
        final bytes = response.data ?? const <int>[];
        final bodySnippet = _errorBodySnippet(bytes, response.headers);
        throw BookSourceProtocolException(
          bodySnippet.isEmpty
              ? 'Legado source returned HTTP $status for ${current.toString()}.'
              : 'Legado source returned HTTP $status for ${current.toString()}.\nResponse: $bodySnippet',
        );
      }
      if (redirects == 5) {
        throw const BookSourceProtocolException(
          'Legado source redirected too many times.',
        );
      }
      if (method == LegadoRequestMethod.post &&
          (status == 301 || status == 302 || status == 303)) {
        method = LegadoRequestMethod.get;
        body = null;
      }
      current = BookSourceNetworkPolicy.redirectTarget(
        current,
        response.headers.value(HttpHeaders.locationHeader),
      );
    }
    throw const BookSourceProtocolException('Legado source request failed.');
  }

  Future<Response<List<int>>> _attempt(
    Uri target,
    LegadoRequestTemplate request,
    LegadoRequestMethod method,
    String? body,
    Map<String, String> mergedHeaders,
  ) {
    final cancelToken = CancelToken();
    return _dio.requestUri<List<int>>(
      target,
      data: method == LegadoRequestMethod.post
          ? Uint8List.fromList(_encode(body ?? '', request.charset))
          : null,
      options: Options(
        method: method == LegadoRequestMethod.post ? 'POST' : 'GET',
        headers: mergedHeaders,
        responseType: ResponseType.bytes,
        followRedirects: false,
        // validateStatus 允许 4xx/5xx 通过：send() 会手动把响应体
        // 裁剪后拼入错误消息，避免 DioException 把 body 丢掉。
        validateStatus: (status) => status != null && status >= 200 && status < 600,
      ),
      cancelToken: cancelToken,
      onReceiveProgress: (received, total) {
        if (received > maxResponseBytes || total > maxResponseBytes) {
          cancelToken.cancel('Response exceeds $maxResponseBytes bytes.');
        }
      },
    );
  }

  static bool _isRetryableConnectionError(DioException error) {
    if (CancelToken.isCancel(error)) return false;
    return error.response == null;
  }

  Never _rethrowRequestException(DioException error, Uri target) {
    if (CancelToken.isCancel(error)) {
      throw BookSourceProtocolException(
        error.message ?? 'Legado request was cancelled.',
      );
    }
    final status = error.response?.statusCode;
    // 错误消息必须包含目标 URL：不然 10 个源并发报错时，
    // 用户根本分不清是哪个站点挂了。
    throw BookSourceProtocolException(
      status == null
          ? 'Could not connect to ${target.toString()} (${error.type.name}).'
          : 'Legado source returned HTTP $status for ${target.toString()}.',
    );
  }

  /// 把 4xx/5xx 响应体裁剪成最多 200 字符的单行摘要：
  /// HTML/XML 去标签，JSON 去空白，Unicode 控制字符去掉。
  static String _errorBodySnippet(List<int> bytes, Headers headers) {
    try {
      var text = _decode(bytes, 'utf-8', headers);
      // 去 <script>/<style> 整段和所有 HTML 标签。
      text = text.replaceAll(
        RegExp(r'<script[\s\S]*?</script>', caseSensitive: false),
        ' ',
      );
      text = text.replaceAll(
        RegExp(r'<style[\s\S]*?</style>', caseSensitive: false),
        ' ',
      );
      text = text.replaceAll(RegExp(r'<[^>]*>'), ' ');
      // 折叠空白和控制字符。
      text = text.replaceAll(RegExp(r'[\x00-\x1F\x7F]+'), ' ');
      text = text.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (text.length <= 200) return text;
      return '${text.substring(0, 200)}…';
    } catch (_) {
      return '';
    }
  }
}

/// Legado 请求的默认 User-Agent。书源未显式声明 UA 时使用；
/// 无 UA 请求常被目标站点 403 或返回防爬页面。
const defaultLegadoUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

const _supportedCharsets = {'utf-8', 'utf8', 'gbk', 'gb2312', 'gb18030'};
final _unresolvedVariables = RegExp(r'\{\{[^{}]+\}\}');
final _unresolvedGetSyntax = RegExp(r'@get:\{[^{}]*\}');
// `@put:` 不在此列：URL 模板里的 @put:{name:value} 由 runtime 的
// _expandTemplate 先行展开/剥离（原版 Legado 语义），不应按脚本拦截。
final _unsupportedRequestSyntax = RegExp(r'@js:|<js>', caseSensitive: false);
const _forbiddenHeaders = {'host', 'content-length', 'transfer-encoding'};

String _expandVariables(String input, Map<String, String> variables) {
  return input.replaceAllMapped(RegExp(r'\{\{\s*([^{}]+?)\s*\}\}'), (match) {
    final key = match.group(1)!;
    final value = variables[key];
    if (value == null) return match.group(0)!;
    return Uri.encodeQueryComponent(value);
  });
}

List<int> _encode(String value, String charset) {
  if (charset == 'gbk' || charset == 'gb2312') {
    return gbk_bytes.encode(value);
  }
  return utf8.encode(value);
}

String _decode(List<int> bytes, String configured, Headers headers) {
  final contentType = headers
      .value(HttpHeaders.contentTypeHeader)
      ?.toLowerCase();
  final headerCharset = contentType == null
      ? null
      : RegExp(
          r'''charset\s*=\s*["']?([^;"'\s]+)''',
        ).firstMatch(contentType)?.group(1);
  final normalizedHeader = headerCharset?.toLowerCase();
  final charset =
      normalizedHeader != null &&
          (_supportedCharsets.contains(normalizedHeader) ||
              normalizedHeader == 'gb18030')
      ? normalizedHeader
      : configured;
  if (charset == 'gbk' || charset == 'gb2312' || charset == 'gb18030') {
    final encoded = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    return decodeGbkFast(
      encoded,
      lenient: !isLikelyValidGbkByteStream(encoded),
    );
  }
  // yuedu_hd 行为：声明 utf8 但解码出大量替换符（U+FFFD）时，
  // 实际多半是 GBK 字节流，回退按 GBK 解码一次。
  final decoded = utf8.decode(bytes, allowMalformed: true);
  final replacementCount = '\uFFFD'.allMatches(decoded).length;
  if (replacementCount > 0 && bytes.length > 16) {
    final encoded = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    if (isLikelyValidGbkByteStream(encoded)) {
      final gbkText = decodeGbkFast(encoded, lenient: false);
      if ('\uFFFD'.allMatches(gbkText).length < replacementCount) {
        return gbkText;
      }
    }
  }
  return decoded;
}
