// 文件说明：内置书源预装服务，首次启动时把随包分发的 Legado 书源
// 导入本地注册表，跳过在线逐源验证，保证开箱即可搜索阅读。
// 技术要点：rootBundle 资产加载、compute 后台解析、SharedPreferences 一次性标记。

import 'dart:convert';

import 'package:flutter/foundation.dart' show compute, debugPrint;
import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';

import '../legado/legado_book_source.dart';
import '../models/registered_book_source.dart';
import 'book_source_registry.dart';

class BuiltinBookSourcePreloader {
  static const String assetPath = 'assets/book_sources/perfect_sources.json';
  static const String _preferenceKey = 'builtin_book_sources_preloaded_v1';

  /// 确保内置书源已导入。只在每个安装周期内执行一次；导入失败不落
  /// 标记，下次启动自动重试。已存在同 id 的源时沿用注册表合并语义，
  /// 不覆盖用户本地的启用状态。
  static Future<void> ensurePreloaded({BookSourceRegistry? registry}) async {
    final preferences = await SharedPreferences.getInstance();
    if (preferences.getBool(_preferenceKey) == true) return;

    final String text;
    try {
      final bytes = await rootBundle.load(assetPath);
      text = utf8.decode(bytes.buffer.asUint8List(), allowMalformed: false);
    } catch (error) {
      debugPrint('内置书源资产加载失败（下次启动重试）: $error');
      return;
    }

    try {
      // 2MB 级 JSON 放后台 isolate 解析，避免阻塞首启 UI。
      final parsed = await compute(parseLegadoSources, text);
      final scanner = const LegadoCompatibilityScanner();
      final registered = <RegisteredBookSource>[];
      var skipped = 0;
      for (final source in parsed.sources) {
        if (!scanner.scan(source).canRun) {
          skipped++;
          continue;
        }
        registered.add(
          source.toRegisteredSource(enabled: true, readingChainVerified: true),
        );
      }
      if (registered.isNotEmpty) {
        await (registry ?? BookSourceRegistry()).upsertAll(registered);
      }
      await preferences.setBool(_preferenceKey, true);
      debugPrint(
        '内置书源预装完成：导入 ${registered.length} 个，'
        '跳过不兼容 $skipped 个，解析错误 ${parsed.errors.length} 条。',
      );
    } catch (error) {
      debugPrint('内置书源预装失败（下次启动重试）: $error');
    }
  }
}
