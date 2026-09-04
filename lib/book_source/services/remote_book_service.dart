import 'dart:io';
import 'dart:typed_data';

import 'webdav_service.dart';

/// 远程书（对应官方 `RemoteBook`）。
///
/// 一本远端书架上的书：名字、远端相对路径、大小、最后修改时间，
/// 以及是否已加入本地书架 [isOnBookShelf]。
class RemoteBook {
  RemoteBook({
    required this.name,
    required this.path,
    this.size = 0,
    this.lastModify,
    this.isOnBookShelf = false,
  });

  /// 文件名（含扩展名）。
  final String name;

  /// 远端路径（相对书架的完整路径）。
  final String path;

  /// 文件大小（字节）。
  final int size;

  /// 最后修改时间。
  final DateTime? lastModify;

  /// 是否已在本地书架中。
  final bool isOnBookShelf;

  RemoteBook copyWith({bool? isOnBookShelf}) => RemoteBook(
        name: name,
        path: path,
        size: size,
        lastModify: lastModify,
        isOnBookShelf: isOnBookShelf ?? this.isOnBookShelf,
      );
}

/// 远程书服务（WebDAV 远程书架，对齐官方 `RemoteBookManager`）。
///
/// 基于现有 [WebDavService] 的配置构建 [WebDavClient]，
/// 实现远端书的列表 / 下载 / 上传 / 删除。所有网络操作均做容错，
/// 失败返回 false / 空列表，**不抛异常**。
class RemoteBookService {
  RemoteBookService._();

  static final RemoteBookService instance = RemoteBookService._();

  /// 是否已配置合法 WebDAV（委托给 WebDavService 的配置）。
  bool get isConfigured => WebDavService.instance.isConfigured;

  /// 列出远程书（远端基路径下的所有文件）。
  ///
  /// 未配置或任何异常时返回空列表，不抛出异常。
  Future<List<RemoteBook>> listBooks() async {
    try {
      if (!isConfigured) return const [];
      final client = _client();
      final items = await client.list();
      return [
        for (final it in items)
          RemoteBook(
            name: it.name,
            path: it.href,
            size: it.size,
            lastModify: it.modified,
          ),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// 下载远程书并保存到 [saveDir]（目录路径，由调用方给定）。
  ///
  /// 成功返回 true，任何失败返回 false，不抛出异常。
  Future<bool> download(RemoteBook book, {required String saveDir}) async {
    try {
      if (!isConfigured) return false;
      final bytes = await _client().get(book.name);
      return _writeFile(saveDir, book.name, bytes);
    } catch (_) {
      return false;
    }
  }

  /// 上传本地文件 [localPath] 到远端书架。
  ///
  /// 成功返回 true，任何失败返回 false，不抛出异常。
  Future<bool> upload({required String localPath}) async {
    try {
      if (!isConfigured) return false;
      final file = File(localPath);
      if (!await file.exists()) return false;
      final bytes = Uint8List.fromList(await file.readAsBytes());
      await _client().put(file.uri.pathSegments.isEmpty
          ? 'book.txt'
          : file.uri.pathSegments.last, bytes);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 删除远端书。
  ///
  /// 成功返回 true，任何失败返回 false，不抛出异常。
  Future<bool> delete(RemoteBook book) async {
    try {
      if (!isConfigured) return false;
      await _client().delete(book.name);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 基于 WebDavService 当前配置构建客户端。
  WebDavClient _client() => WebDavClient(WebDavService.instance.config);

  /// 把字节写入 [saveDir]/[name]。
  Future<bool> _writeFile(String saveDir, String name, Uint8List bytes) async {
    try {
      final dir = Directory(saveDir);
      if (!await dir.exists()) await dir.create(recursive: true);
      final path = saveDir.endsWith(Platform.pathSeparator) ||
              saveDir.endsWith('/')
          ? '$saveDir$name'
          : '$saveDir/$name';
      await File(path).writeAsBytes(bytes, flush: true);
      return true;
    } catch (_) {
      return false;
    }
  }
}