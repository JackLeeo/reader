import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// WebDAV 连接配置（对齐官方「WebDAV 设置」）。
class WebDavConfig {
  WebDavConfig({
    this.server = '',
    this.username = '',
    this.password = '',
    this.webdavDir = '/Legado/',
  });

  String server;
  String username;
  String password;
  String webdavDir;

  bool get isConfigured =>
      server.trim().isNotEmpty && Uri.tryParse(server.trim())?.hasScheme == true;

  factory WebDavConfig.fromJson(Map<String, dynamic> m) => WebDavConfig(
        server: (m['server'] ?? '') as String,
        username: (m['username'] ?? '') as String,
        password: (m['password'] ?? '') as String,
        webdavDir: (m['webdavDir'] ?? '/Legado/') as String,
      );

  Map<String, dynamic> toJson() => {
        'server': server,
        'username': username,
        'password': password,
        'webdavDir': webdavDir,
      };
}

/// 远程目录条目。
class WebDavItem {
  WebDavItem({required this.name, required this.href, required this.size, required this.modified});

  final String name;
  final String href;
  final int size;
  final DateTime? modified;
}

/// WebDAV 客户端（对齐官方 `WebDav` 的 propfind/get/put）。
///
/// 用标准 DAV XML 实现 MKCOL/PROPFIND/GET/PUT；基础认证可选。
class WebDavClient {
  WebDavClient(this.config);

  final WebDavConfig config;
  final http.Client _client = http.Client();

  Uri _base() {
    var server = config.server.trim();
    if (server.endsWith('/')) server = server.substring(0, server.length - 1);
    return Uri.parse(server);
  }

  Map<String, String> _headers({String contentType = 'text/plain'}) {
    final h = <String, String>{
      'Content-Type': '$contentType; charset=utf-8',
      'Accept': '*/*',
    };
    if (config.username.isNotEmpty) {
      final cred = base64Encode(
          utf8.encode('${config.username}:${config.password}'));
      h['Authorization'] = 'Basic $cred';
    }
    return h;
  }

  /// 规范化远端目录路径（保证以 / 结尾，去掉多余路径穿越）。
  String _dirPath() {
    var dir = config.webdavDir.trim();
    if (dir.isEmpty) dir = '/';
    if (!dir.startsWith('/')) dir = '/$dir';
    if (!dir.endsWith('/')) dir = '$dir/';
    return dir;
  }

  Uri _dirUri() => _base().resolve(_dirPath());

  Uri _fileUri(String name) => _dirUri().resolve(Uri.encodeComponent(name));

  /// 确保目录存在（逐级 MKCOL，可容忍已存在）。
  Future<void> ensureDir() async {
    final dir = _dirUri();
    // 只对根目录执行一次 MKCOL（已存在时忽略 405/301）。
    final req = http.Request('MKCOL', dir);
    req.headers.addAll(_headers());
    final resp = await _client.send(req).then(http.Response.fromStream);
    if (resp.statusCode == 201 || resp.statusCode == 405) return;
    throw WebDavException('创建目录失败：HTTP ${resp.statusCode}');
  }

  /// PROPFIND 列出目录下文件。
  Future<List<WebDavItem>> list() async {
    final req = http.Request('PROPFIND', _dirUri());
    req.headers.addAll(_headers(contentType: 'application/xml'));
    req.headers['Depth'] = '1';
    req.body = '<?xml version="1.0"?>'
        '<d:propfind xmlns:d="DAV:">'
        '<d:prop><d:displayname/><d:getcontentlength/><d:getlastmodified/></d:prop>'
        '</d:propfind>';
    final resp = await _client.send(req).then(http.Response.fromStream);
    if (resp.statusCode != 207 && resp.statusCode != 200) {
      throw WebDavException('列出目录失败：HTTP ${resp.statusCode}');
    }
    return _parseMultistatus(resp.body, _dirUri());
  }

  /// 公开入口：解析 PROPFIND 207 XML（调试/测试用）。
  static List<WebDavItem> parseMultistatus(String xml, Uri base) =>
      _parseMultistatus(xml, base);

  /// 解析 PROPFIND 207 XML 响应。
  static List<WebDavItem> _parseMultistatus(String xml, Uri base) {
    final items = <WebDavItem>[];
    // 用 <response> 块切分，逐块取 href / displayname / size / modified。
    final responses = RegExp(r'<d:response>.*?</d:response>|<response>.*?</response>',
            dotAll: true)
        .allMatches(xml);
    for (final m in responses) {
      final block = m.group(0)!;
      final hrefM =
          RegExp(r'<d:href>(.*?)</d:href>|<href>(.*?)</href>', dotAll: true)
              .firstMatch(block);
      if (hrefM == null) continue;
      final href = (hrefM.group(1) ?? hrefM.group(2) ?? '').trim();
      final nameM = RegExp(r'<d:displayname>(.*?)</d:displayname>'
              r'|<displayname>(.*?)</displayname>', dotAll: true)
          .firstMatch(block);
      final name = (nameM?.group(1) ?? nameM?.group(2) ?? '').trim();
      final sizeM = RegExp(r'<d:getcontentlength>(.*?)</d:getcontentlength>'
              r'|<getcontentlength>(.*?)</getcontentlength>', dotAll: true)
          .firstMatch(block);
      final size = int.tryParse(sizeM?.group(1) ?? sizeM?.group(2) ?? '') ?? 0;
      final modM = RegExp(r'<d:getlastmodified>(.*?)</d:getlastmodified>'
              r'|<getlastmodified>(.*?)</getlastmodified>', dotAll: true)
          .firstMatch(block);
      DateTime? modified;
      final modStr = modM?.group(1) ?? modM?.group(2);
      if (modStr != null) {
        modified = DateTime.tryParse(modStr.trim());
      }
      // 跳过目录自身（href 以 / 结尾即目录）。
      final decodedName = Uri.decodeComponent(name.isEmpty ? href : name);
      if (decodedName.isEmpty || href.endsWith('/')) continue;
      items.add(WebDavItem(
        name: decodedName,
        href: href,
        size: size,
        modified: modified,
      ));
    }
    return items;
  }

  /// GET 下载远端文件。
  Future<Uint8List> get(String name) async {
    final resp = await _client
        .get(_fileUri(name), headers: _headers())
        .timeout(const Duration(seconds: 30));
    if (resp.statusCode != 200) {
      throw WebDavException('下载 $name 失败：HTTP ${resp.statusCode}');
    }
    return resp.bodyBytes;
  }

  /// PUT 上传文件内容。
  Future<void> put(String name, Uint8List bytes) async {
    await ensureDir();
    final req = http.Request('PUT', _fileUri(name));
    req.headers.addAll(_headers(contentType: 'application/json'));
    req.bodyBytes = bytes;
    final resp = await _client.send(req).then(http.Response.fromStream);
    if (resp.statusCode != 201 && resp.statusCode != 200 && resp.statusCode != 204) {
      throw WebDavException('上传 $name 失败：HTTP ${resp.statusCode}');
    }
  }

  /// 删除远端文件。
  Future<void> delete(String name) async {
    final req = http.Request('DELETE', _fileUri(name));
    req.headers.addAll(_headers());
    final resp = await _client.send(req).then(http.Response.fromStream);
    if (resp.statusCode != 204 && resp.statusCode != 200 && resp.statusCode != 404) {
      throw WebDavException('删除 $name 失败：HTTP ${resp.statusCode}');
    }
  }
}

class WebDavException implements Exception {
  WebDavException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// WebDAV 配置持久化 + 备份同步入口。
class WebDavService {
  WebDavService._();

  static final WebDavService instance = WebDavService._();

  static const String _prefsKey = 'webdav_config_v1';

  WebDavConfig _config = WebDavConfig();
  bool initialized = false;

  WebDavConfig get config => _config;

  bool get isConfigured => _config.isConfigured;

  Future<void> init() async {
    if (initialized) return;
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_prefsKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        _config = WebDavConfig.fromJson(
            jsonDecode(raw) as Map<String, dynamic>);
      } catch (_) {
        _config = WebDavConfig();
      }
    }
    initialized = true;
  }

  Future<void> saveConfig(WebDavConfig cfg) async {
    _config = cfg;
    final p = await SharedPreferences.getInstance();
    await p.setString(_prefsKey, jsonEncode(cfg.toJson()));
  }

  /// 上传备份：以 [prefix] 命名（时间戳后缀），返回远端文件名。
  Future<String> uploadBackup({
    required String content,
    String prefix = 'legado_backup',
  }) async {
    if (!isConfigured) throw WebDavException('请先配置 WebDAV');
    final client = WebDavClient(_config);
    final name = '${prefix}_${DateTime.now().millisecondsSinceEpoch}.json';
    await client.put(name, Uint8List.fromList(utf8.encode(content)));
    return name;
  }

  /// 下载最新备份并返回内容（无文件返回 null）。
  Future<String?> downloadLatest({String prefix = 'legado_backup'}) async {
    if (!isConfigured) throw WebDavException('请先配置 WebDAV');
    final client = WebDavClient(_config);
    final items = await client.list();
    final backs = items
        .where((i) => i.name.startsWith('${prefix}_') && i.name.endsWith('.json'))
        .toList()
      ..sort((a, b) {
        final av = a.modified?.millisecondsSinceEpoch ?? 0;
        final bv = b.modified?.millisecondsSinceEpoch ?? 0;
        return bv.compareTo(av);
      });
    if (backs.isEmpty) return null;
    final bytes = await client.get(backs.first.name);
    return utf8.decode(bytes, allowMalformed: true);
  }
}
