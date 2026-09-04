import 'dart:convert';
import 'dart:io';

import '../models/books.dart';
import 'book_service.dart';
import 'search_service.dart';
import 'shelf_service.dart';

/// 本地 Web 服务（对齐官方 `api/controller` 的常用查询接口）。
///
/// 在设备局域网内开启一个 HTTP 服务，允许同网络其它设备/脚本按 Legado 风格
/// API 查询搜索、书籍详情、目录、正文与书架。用 [start]/[stop] 控制。
///
/// 保留接口（`name` 首字母即路由键）：
/// - `GET /search?key=关键字`          → 聚合搜索结果（书名/作者/封面/简介/origin/type）
/// - `GET /book?bookUrl=&origin=`       → 书籍详情
/// - `GET /toc?bookUrl=&origin=`        → 章节目录
/// - `GET /content?origin=&url=`        → 章节正文（书源规则解析）
/// - `GET /shelf`                       → 书架书列表
/// - `GET /clock`                       → 本机时间（供外部调度参考）
class LocalServerService {
  LocalServerService._();

  static final LocalServerService instance = LocalServerService._();

  static final BookService _bookService = BookService();
  HttpServer? _server;
  int _port = 0;
  String? _host;

  bool get running => _server != null;

  /// 实际绑定的端口（未启动为 0）。
  int get port => _port;
  String? get host => _host;

  /// 启动服务。[port] 为 0 时随机空闲端口。
  Future<int> start({int port = 2323, InternetAddress? address}) async {
    if (_server != null) return _port;
    final addr = address ?? InternetAddress.anyIPv4;
    _server = await HttpServer.bind(addr, port);
    _port = _server!.port;
    _host = await _localAddress();
    // 可能绑定 0 到任意地址；仅上报 IPv4。
    _server!.listen(_dispatch);
    return _port;
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _port = 0;
    _host = null;
  }

  Future<String?> _localAddress() async {
    try {
      final interfaces = await NetworkInterface.list();
      for (final i in interfaces) {
        for (final a in i.addresses) {
          if (a.type == InternetAddressType.IPv4 && !a.isLoopback) {
            return a.address;
          }
        }
      }
    } catch (_) {}
    return null;
  }

  Future<void> _dispatch(HttpRequest req) async {
    final path = req.uri.path;

    // WebSocket 控制通道（浏览器/脚本实时调用）。
    if (path == '/ws' && WebSocketTransformer.isUpgradeRequest(req)) {
      final ws = await WebSocketTransformer.upgrade(req);
      _handleWs(ws);
      return;
    }

    // MCP over HTTP（JSON-RPC）。
    if (path == '/mcp' || path == '/mcp/' || path == '/rpc') {
      await _handleMcp(req);
      return;
    }

    final resp = req.response;
    resp.headers.contentType = ContentType.json;
    Object? result;
    try {
      switch (path) {
        case '/search' || '/search/':
          result = await _searchData(req.uri.queryParameters['key'] ?? '');
        case '/book' || '/book/':
          result = await _bookData(
            req.uri.queryParameters['bookUrl'] ?? '',
            req.uri.queryParameters['origin'] ?? '',
          );
        case '/toc' || '/toc/':
          result = await _tocData(
            bookUrl: req.uri.queryParameters['bookUrl'] ?? '',
            name: req.uri.queryParameters['name'] ?? '',
            origin: req.uri.queryParameters['origin'] ?? '',
            sourceTag: req.uri.queryParameters['sourceTag'] ?? '',
          );
        case '/content' || '/content/':
          final url = req.uri.queryParameters['url'] ?? '';
          result = await _contentData(
            url: url,
            name: req.uri.queryParameters['name'] ?? '',
            bookUrl: req.uri.queryParameters['bookUrl'] ?? url,
            origin: req.uri.queryParameters['origin'] ?? '',
            sourceTag: req.uri.queryParameters['sourceTag'] ?? '',
            title: req.uri.queryParameters['title'] ?? '',
          );
        case '/shelf' || '/shelf/':
          result = _shelfData();
        case '/clock' || '/clock/':
          result = {'clock': DateTime.now().millisecondsSinceEpoch};
        case '/tools' || '/tools/':
          result = _mcpTools();
        case '/health' || '/health/':
          result = {'ok': true};
        default:
          result = {'error': 'not found', 'path': path};
      }
    } catch (e) {
      result = {'error': '$e'};
    }
    resp.write(jsonEncode(result));
    await resp.close();
  }

  // -------------------------------------------------------------------------
  // HTTP 复用层：所有数据方法仅依赖参数，供 REST / MCP / WebSocket 共用
  // -------------------------------------------------------------------------

  Future<List<Map<String, dynamic>>> _searchData(String key) async {
    if (key.trim().isEmpty) return const [];
    final out = <Map<String, dynamic>>[];
    await SearchService.instance.searchAll(key.trim(), onResult: (origin, books, done, total) {
      for (final b in books) {
        out.add(_searchBookToJson(b));
      }
    });
    return out;
  }

  Future<Map<String, dynamic>?> _bookData(String bookUrl, String origin) async {
    if (bookUrl.isEmpty) return {'error': 'bookUrl required'};
    final book = await _bookService.getBook(
      SearchBook(name: '', bookUrl: bookUrl, origin: origin),
    );
    if (book == null) return null;
    return {
      'name': book.name,
      'author': book.author,
      'coverUrl': book.coverUrl,
      'intro': book.intro,
      'tocUrl': book.tocUrl,
      'bookUrl': book.bookUrl,
      'origin': book.origin,
      'type': book.type,
    };
  }

  Future<Map<String, dynamic>?> _tocData({
    required String bookUrl,
    required String name,
    required String origin,
    required String sourceTag,
  }) async {
    if (bookUrl.isEmpty) return {'error': 'bookUrl required'};
    final book = Book(
      name: name,
      bookUrl: bookUrl,
      origin: origin,
      sourceTag: sourceTag,
    );
    final chapters = await _bookService.getToc(book);
    return {
      'bookTitle': book.name,
      'toc': [
        for (final c in chapters)
          {
            'title': c.title,
            'url': c.url,
            'isVolume': c.isVolume,
            'isVip': c.isVip,
            'isPay': c.isPay,
          },
      ],
    };
  }

  Future<Map<String, dynamic>?> _contentData({
    required String url,
    required String name,
    required String bookUrl,
    required String origin,
    required String sourceTag,
    required String title,
  }) async {
    if (url.isEmpty) return {'error': 'url required'};
    final book = Book(
      name: name,
      bookUrl: bookUrl,
      origin: origin,
      sourceTag: sourceTag,
    );
    final content = await _bookService.getContent(
      BookChapter(title: title, url: url),
      book,
    );
    return {
      'title': content.title,
      'content': content.body,
      'succeed': content.succeed,
      'msg': content.msg,
      'nextUrl': content.nextUrl,
    };
  }

  List<Map<String, dynamic>> _shelfData() => [
        for (final b in ShelfService.instance.books)
          {
            'name': b.name,
            'author': b.author,
            'bookUrl': b.bookUrl,
            'origin': b.origin,
            'sourceTag': b.sourceTag,
            'intro': b.intro,
            'progress': b.readingProgress,
            'lastReadChapter': b.lastReadChapter,
          },
      ];

  static Map<String, dynamic> _searchBookToJson(SearchBook b) => {
        'name': b.name,
        'author': b.author,
        'coverUrl': b.coverUrl,
        'intro': b.intro,
        'bookUrl': b.bookUrl,
        'origin': b.origin,
        'type': b.type,
      };

  // -------------------------------------------------------------------------
  // WebSocket：实时 RPC 通道（浏览器/脚本 connect 后按 JSON 调用）
  // -------------------------------------------------------------------------

  Future<void> _handleWs(WebSocket ws) async {
    ws.add(jsonEncode({'server': 'legado', 'version': '1.0'}));
    await for (final msg in ws) {
      if (msg is! String) continue;
      final idObj = jsonDecode(msg);
      if (idObj is! Map) continue;
      final id = idObj['id'];
      final method = (idObj['method'] as String?) ?? '';
      final params = (idObj['params'] is Map)
          ? Map<String, dynamic>.from(idObj['params'] as Map)
          : <String, dynamic>{};
      Object? result;
      Object? error;
      try {
        result = await _runTool(method, params);
      } catch (e) {
        error = '$e';
      }
      ws.add(jsonEncode({
        'id': id,
        if (error != null) 'error': {'message': error} else 'result': result,
      }));
    }
  }

  // -------------------------------------------------------------------------
  // MCP over HTTP（JSON-RPC：initialize / tools/list / tools/call）
  // -------------------------------------------------------------------------

  Future<void> _handleMcp(HttpRequest req) async {
    final resp = req.response;
    resp.headers.contentType = ContentType.json;
    if (req.method != 'POST') {
      resp.write(jsonEncode({'error': 'POST required'}));
      await resp.close();
      return;
    }
    Map<String, dynamic>? inMsg;
    try {
      final body = await utf8.decoder.bind(req).join();
      final dec = jsonDecode(body);
      if (dec is Map) inMsg = Map<String, dynamic>.from(dec);
    } catch (e) {
      resp.write(jsonEncode({'jsonrpc': '2.0', 'error': {'code': -32700, 'message': 'Parse error'}}));
      await resp.close();
      return;
    }
    if (inMsg == null) {
      resp.write(jsonEncode({'jsonrpc': '2.0', 'error': {'code': -32600, 'message': 'Invalid Request'}}));
      await resp.close();
      return;
    }
    final id = inMsg['id'];
    final method = (inMsg['method'] as String?) ?? '';
    final params = (inMsg['params'] is Map)
        ? Map<String, dynamic>.from(inMsg['params'] as Map)
        : <String, dynamic>{};

    Object? result;
    Object? error;
    if (method == 'initialize') {
      result = {
        'protocolVersion': '2024-11-05',
        'capabilities': {'tools': {}},
        'serverInfo': {'name': 'legado-flutter', 'version': '1.0.0'},
      };
    } else if (method == 'notifications/initialized') {
      // 通知，无需回包；置 result 使响应结构统一（规范允许无回包，此处省掉 body）。
      resp.write('{}');
      await resp.close();
      return;
    } else if (method == 'tools/list') {
      result = {'tools': _mcpTools()};
    } else if (method == 'tools/call') {
      final name = (params['name'] as String?) ?? '';
      final args = (params['arguments'] is Map)
          ? Map<String, dynamic>.from(params['arguments'] as Map)
          : <String, dynamic>{};
      try {
        final toolResult = await _runTool(name, args);
        result = {'content': [{'type': 'text', 'text': jsonEncode(toolResult)}]};
      } catch (e) {
        error = {'message': '$e'};
      }
    } else {
      error = {'code': -32601, 'message': 'Method not found: $method'};
    }

    resp.write(jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      if (error != null) 'error': error else 'result': result,
    }));
    await resp.close();
  }

  /// 工具定义列表（MCP tools/list）。
  List<Map<String, dynamic>> _mcpTools() => [
        _tool('search',
            '聚合搜索书籍',
            {'key': {'type': 'string', 'description': '搜索关键字', 'required': true}}),
        _tool('get_book',
            '按 bookUrl + origin 解析书籍详情',
            {
              'bookUrl': {'type': 'string', 'required': true},
              'origin': {'type': 'string'},
            }),
        _tool('get_toc',
            '拉取章节目录',
            {'bookUrl': {'type': 'string', 'required': true}}),
        _tool('get_content',
            '拉取章节正文',
            {
              'url': {'type': 'string', 'required': true},
              'bookUrl': {'type': 'string'},
              'origin': {'type': 'string'},
            }),
        _tool('get_shelf', '返回书架书籍', const {}),
        _tool('clock', '返回服务器时间戳', const {}),
      ];

  static Map<String, dynamic> _tool(String name, String description, Map properties) => {
        'name': name,
        'description': description,
        'inputSchema': {'type': 'object', 'properties': properties},
      };

  /// 执行一个工具调用（忽略首字母 for-search 等，直接用全名）。
  Future<Object?> _runTool(String tool, Map<String, dynamic> p) async {
    switch (tool) {
      case 'search':
        return _searchData((p['key'] ?? '').toString());
      case 'get_book':
        return _bookData((p['bookUrl'] ?? '').toString(), (p['origin'] ?? '').toString());
      case 'get_toc':
        return _tocData(
          bookUrl: (p['bookUrl'] ?? '').toString(),
          name: (p['name'] ?? '').toString(),
          origin: (p['origin'] ?? '').toString(),
          sourceTag: (p['sourceTag'] ?? '').toString(),
        );
      case 'get_content':
        return _contentData(
          url: (p['url'] ?? '').toString(),
          name: (p['name'] ?? '').toString(),
          bookUrl: (p['bookUrl'] ?? (p['url'] ?? '')).toString(),
          origin: (p['origin'] ?? '').toString(),
          sourceTag: (p['sourceTag'] ?? '').toString(),
          title: (p['title'] ?? '').toString(),
        );
      case 'get_shelf':
        return _shelfData();
      case 'clock':
        return {'clock': DateTime.now().millisecondsSinceEpoch};
      default:
        throw ArgumentError('未知工具: $tool');
    }
  }
}