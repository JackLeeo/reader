import 'dart:convert';

import 'http_service.dart';

/// 版本更新信息（对应官方更新检查返回）。
class UpdateInfo {
  UpdateInfo({
    required this.version,
    required this.releaseNotes,
    required this.downloadUrl,
  });

  /// 新版本号。
  final String version;

  /// 更新说明。
  final String releaseNotes;

  /// 下载地址。
  final String downloadUrl;
}

/// 更新检查服务（对齐官方 help/update）。
///
/// 拉取远端版本 JSON，与当前版本比较；有新版则返回 [UpdateInfo]，
/// 否则 / 请求失败 / JSON 非法时返回 null，**不抛异常**。
class UpdateService {
  UpdateService._();

  static final UpdateService instance = UpdateService._();

  /// 更新检查地址。默认留空：未配置真实发布地址时，[checkForUpdates] 直接返回
  /// null（不发起无意义请求）。可经 [updateUrl] 注入（如面向自签/TrollStore 的
  /// 发布 JSON 地址）后接入。
  static String _updateUrl = '';

  /// 配置更新检查地址（运行时覆盖默认）。
  void setUpdateUrl(String? url) {
    final u = url?.trim() ?? '';
    if (u.isNotEmpty) _updateUrl = u;
  }

  String get updateUrl => _updateUrl;

  /// 检查是否有新版本。
  ///
  /// [currentVersion] 当前版本号；[url] 版本检查地址（缺省用已配置地址；均为空
  /// 则直接判为“无更新”，避免请求占位域名）。
  /// 远端返回 `{"version":"x.y.z","releaseNotes":"...","downloadUrl":"..."}`。
  Future<UpdateInfo?> checkForUpdates({
    required String currentVersion,
    String? url,
  }) async {
    final target = (url ?? _updateUrl).trim();
    if (target.isEmpty) return null;
    try {
      final resp = await HttpService.instance.get(target);
      if (!resp.ok) return null;
      final decoded = jsonDecode(resp.body);
      if (decoded is! Map<String, dynamic>) return null;
      final remoteVersion = decoded['version']?.toString() ?? '';
      if (remoteVersion.isEmpty) return null;
      if (compareVersions(remoteVersion, currentVersion) <= 0) return null;
      return UpdateInfo(
        version: remoteVersion,
        releaseNotes: decoded['releaseNotes']?.toString() ?? '',
        downloadUrl: decoded['downloadUrl']?.toString() ?? '',
      );
    } catch (_) {
      return null;
    }
  }

  /// 版本号比较（如 "1.2.3" vs "1.10.0"）。
  ///
  /// 按 `.` 分段、逐段整型比较；缺少的段按 0 补足。
  /// 返回 >0 表示 a 更新，=0 相同，<0 表示 a 更旧。
  static int compareVersions(String a, String b) {
    final as = a.split('.').map(int.tryParse).toList();
    final bs = b.split('.').map(int.tryParse).toList();
    final len = as.length > bs.length ? as.length : bs.length;
    for (var i = 0; i < len; i++) {
      final av = i < as.length ? (as[i] ?? 0) : 0;
      final bv = i < bs.length ? (bs[i] ?? 0) : 0;
      if (av != bv) return av < bv ? -1 : 1;
    }
    return 0;
  }
}