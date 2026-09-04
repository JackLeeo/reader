import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'http_service.dart';

/// 一个已下载 / 可下载的字体（对应官方「字体」）。
class FontEntry {
  FontEntry({
    required this.name,
    this.url = '',
    this.filePath = '',
    this.enabled = false,
  });

  /// 字体显示名，也是运行时注册的 fontFamily。
  final String name;

  /// 来源地址（空表示预置/手动本地）。
  final String url;

  /// 本地文件路径（已下载后非空）。
  final String filePath;

  /// 是否已注册到 Flutter（可在阅读器中使用）。
  final bool enabled;

  FontEntry copyWith({String? filePath, bool? enabled}) => FontEntry(
        name: name,
        url: url,
        filePath: filePath ?? this.filePath,
        enabled: enabled ?? this.enabled,
      );

  factory FontEntry.fromJson(Map<String, dynamic> m) => FontEntry(
        name: (m['name'] ?? '') as String,
        url: (m['url'] ?? '') as String,
        filePath: (m['filePath'] ?? '') as String,
        enabled: (m['enabled'] as bool?) ?? false,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'url': url,
        'filePath': filePath,
        'enabled': enabled,
      };
}

/// 阅读字体管理：下载 TTF/OTF 并运行时注册为可用的 fontFamily。
///
/// - [download] 把 URL 字体拉取保存到 `{root}/fonts/{name}.ttf`。
/// - [register] 用 Flutter `FontLoader` 把本地字体字节注册为 `name` family，
///   之后任何 `TextStyle(fontFamily: name)` 都能使用。
/// - 注册状态持久化，重复注册幂等。
class FontService {
  FontService._();

  static final FontService instance = FontService._();

  Directory? _root;
  bool _ready = false;
  final List<FontEntry> _fonts = [];
  final Set<String> _registered = {};

  static const String _prefsKey = 'read_fonts_v1';

  /// 可注入的字体字节获取函数（测试用；为空走 [HttpService]）。
  Future<List<int>?> Function(String url)? fetchOverride;

  List<FontEntry> get fonts => List.unmodifiable(_fonts);

  bool get ready => _ready;

  Future<void> setRoot(Directory dir) async {
    _root = Directory('${dir.path}${Platform.pathSeparator}fonts');
    if (!_root!.existsSync()) await _root!.create(recursive: true);
    await _load();
    _ready = true;
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_prefsKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        _fonts
          ..clear()
          ..addAll((jsonDecode(raw) as List)
              .map((e) => FontEntry.fromJson(e as Map<String, dynamic>)));
      } catch (_) {
        _fonts.clear();
      }
    }
    _ready = true;
  }

  Future<void> _persist() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_prefsKey, jsonEncode(_fonts.map((f) => f.toJson()).toList()));
  }

  void reset() {
    _fonts.clear();
    _registered.clear();
    _ready = false;
  }

  bool has(String name) => _fonts.any((f) => f.name == name);

  FontEntry? byName(String name) {
    for (final f in _fonts) {
      if (f.name == name) return f;
    }
    return null;
  }

  /// 添加字体（同名覆盖，保留已有下载/注册状态）。
  void add(FontEntry entry) {
    _fonts.removeWhere((f) => f.name == entry.name);
    _fonts.add(entry);
    _persist();
  }

  void remove(String name) {
    final f = byName(name);
    if (f != null && f.filePath.isNotEmpty) {
      final file = File(f.filePath);
      if (file.existsSync()) file.deleteSync();
    }
    _fonts.removeWhere((x) => x.name == name);
    _registered.remove(name);
    _persist();
  }

  Future<File?> _fontFile(String name) async {
    if (_root == null) return null;
    final safe = name.replaceAll(RegExp(r'[^\w\u4e00-\u9fa5-]'), '_');
    return File('${_root!.path}${Platform.pathSeparator}$safe.ttf');
  }

  /// 下载字体并落盘；已下载则跳过。返回文件路径。
  Future<String?> download(String name, String url) async {
    if (name.trim().isEmpty || url.trim().isEmpty) return null;
    File? file;
    if (byName(name)?.filePath.isNotEmpty == true) {
      file = File(byName(name)!.filePath);
      if (file.existsSync()) return file.path;
    }
    file = await _fontFile(name);
    final bytes = await _fetch(url);
    if (bytes == null || bytes.isEmpty) return null;
    await file!.writeAsBytes(bytes, flush: true);
    _fonts.removeWhere((f) => f.name == name);
    _fonts.add(FontEntry(name: name, url: url, filePath: file.path));
    await _persist();
    return file.path;
  }

  Future<List<int>?> _fetch(String url) async {
    if (fetchOverride != null) return fetchOverride!(url);
    final resp = await HttpService.instance.get(url);
    if (!resp.ok) return null;
    return resp.bodyBytes;
  }

  /// 把本地字体文件注册为 `name` family，成功后标记 enable 并持久化。
  Future<bool> register(String name) async {
    if (_registered.contains(name)) {
      await _markEnabled(name);
      return false;
    }
    final f = byName(name);
    if (f == null || f.filePath.isEmpty) return false;
    final file = File(f.filePath);
    if (!file.existsSync()) return false;
    try {
      final bytes = await file.readAsBytes();
      final loader = FontLoader(name);
      loader.addFont(Future.value(ByteData.view(bytes.buffer)));
      await loader.load();
      _registered.add(name);
      await _markEnabled(name);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _markEnabled(String name) async {
    final old = byName(name);
    _fonts.removeWhere((x) => x.name == name);
    _fonts.add(FontEntry(
      name: name,
      url: old?.url ?? '',
      filePath: old?.filePath ?? '',
      enabled: true,
    ));
    await _persist();
  }

  /// 运行时可用的字体名（已注册 enabled=true）。
  List<String> availableFamilies() =>
      [for (final f in _fonts.where((f) => f.enabled)) f.name];
}