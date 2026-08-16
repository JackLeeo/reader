import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 书源诊断日志等级。
enum SourceDiagLevel { info, warn, error }

/// 书源诊断日志操作类型。
enum SourceDiagOp { search, discovery, detail, chapters, content, fallback }

/// 单条诊断日志条目。
class SourceDiagEntry {
  SourceDiagEntry({
    required this.timestamp,
    required this.sourceId,
    required this.sourceName,
    required this.op,
    required this.level,
    required this.message,
    this.details,
  });

  final DateTime timestamp;
  final String sourceId;
  final String sourceName;
  final SourceDiagOp op;
  final SourceDiagLevel level;
  final String message;
  final String? details;

  String get _opLabel {
    switch (op) {
      case SourceDiagOp.search:
        return 'search';
      case SourceDiagOp.discovery:
        return 'discovery';
      case SourceDiagOp.detail:
        return 'detail';
      case SourceDiagOp.chapters:
        return 'chapters';
      case SourceDiagOp.content:
        return 'content';
      case SourceDiagOp.fallback:
        return 'fallback';
    }
  }

  String get _levelLabel {
    switch (level) {
      case SourceDiagLevel.info:
        return 'INFO';
      case SourceDiagLevel.warn:
        return 'WARN';
      case SourceDiagLevel.error:
        return 'ERROR';
    }
  }

  /// 单行摘要，用于列表展示。
  String toOneLiner() {
    final ts =
        '${timestamp.hour.toString().padLeft(2, '0')}'
        ':${timestamp.minute.toString().padLeft(2, '0')}'
        ':${timestamp.second.toString().padLeft(2, '0')}';
    return '[$ts] [$_levelLabel] [$_opLabel] $sourceName: $message';
  }

  /// 多行详细格式，用于导出。
  List<String> toReportLines() {
    final lines = <String>[
      '## $timestamp — [$_levelLabel] $_opLabel',
      '- Source: $sourceName ($sourceId)',
      '- Message: $message',
    ];
    if (details != null && details!.isNotEmpty) {
      lines.add('- Details:');
      for (final line in details!.split('\n')) {
        lines.add('  $line');
      }
    }
    return lines;
  }
}

/// 书源诊断日志收集器。
///
/// 全局单例，在 LegadoRuntime 关键节点自动埋点；
/// 用户可在阅读页/设置页导出日志用于排查问题。
class SourceDiagnosticLogger {
  SourceDiagnosticLogger._();
  static final SourceDiagnosticLogger instance = SourceDiagnosticLogger._();

  static const int _maxEntries = 500;

  final List<SourceDiagEntry> _entries = [];
  bool enabled = true;

  List<SourceDiagEntry> get entries =>
      List<SourceDiagEntry>.unmodifiable(_entries);

  void clear() => _entries.clear();

  void log({
    required String sourceId,
    required String sourceName,
    required SourceDiagOp op,
    required SourceDiagLevel level,
    required String message,
    String? details,
  }) {
    if (!enabled) return;
    _entries.add(
      SourceDiagEntry(
        timestamp: DateTime.now(),
        sourceId: sourceId,
        sourceName: sourceName,
        op: op,
        level: level,
        message: message,
        details: details,
      ),
    );
    if (_entries.length > _maxEntries) {
      _entries.removeRange(0, _entries.length - _maxEntries);
    }
  }

  /// 按 sourceId 过滤条目。
  List<SourceDiagEntry> entriesFor(String sourceId) =>
      _entries.where((e) => e.sourceId == sourceId).toList();

  /// 生成可读的 Markdown 报告文本。
  String exportToText({String? sourceId}) {
    final buf = StringBuffer();
    buf.writeln('# Book Source Diagnostic Report');
    buf.writeln();
    buf.writeln(
      'Generated: ${DateTime.now().toIso8601String()}',
    );
    buf.writeln('Total entries: ${_entries.length}');
    if (sourceId != null) {
      buf.writeln('Filtered by source: $sourceId');
    }
    buf.writeln();

    final entries = sourceId != null ? entriesFor(sourceId) : _entries;
    if (entries.isEmpty) {
      buf.writeln('No diagnostic entries recorded.');
      return buf.toString();
    }

    // 按操作类型分组
    final byOp = <SourceDiagOp, List<SourceDiagEntry>>{};
    for (final e in entries) {
      byOp.putIfAbsent(e.op, () => []).add(e);
    }

    buf.writeln('---');
    buf.writeln();

    // 摘要表
    buf.writeln('## Summary');
    for (final op in SourceDiagOp.values) {
      final list = byOp[op];
      if (list == null || list.isEmpty) continue;
      final errors = list.where((e) => e.level == SourceDiagLevel.error).length;
      final warns = list.where((e) => e.level == SourceDiagLevel.warn).length;
      buf.writeln(
        '- ${_opLabel(op)}: ${list.length} entries'
        '${errors > 0 ? " ($errors errors)" : ""}'
        '${warns > 0 ? " ($warns warnings)" : ""}',
      );
    }
    buf.writeln();
    buf.writeln('---');
    buf.writeln();

    // 详细条目（按时间顺序）
    buf.writeln('## Entries');
    for (final e in entries) {
      buf.writeln();
      for (final line in e.toReportLines()) {
        buf.writeln(line);
      }
    }

    return buf.toString();
  }

  /// 导出到文件。返回文件路径，取消时返回 null。
  Future<String?> exportToFile({String? sourceId}) async {
    final text = exportToText(sourceId: sourceId);
    final stamp = DateTime.now().toIso8601String().replaceAll(':', '-');
    final fileName = 'book_source_diagnostic_$stamp.md';

    // 桌面端用 saveFile 让用户选保存位置
    if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      final path = await FilePicker.saveFile(
        fileName: fileName,
        type: FileType.custom,
        allowedExtensions: const ['md'],
        lockParentWindow: true,
      );
      if (path == null) return null;
      final file = File(path);
      await file.writeAsString(text);
      return path;
    }

    // 移动端保存到临时目录
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$fileName');
    await file.writeAsString(text);
    return file.path;
  }

  String _opLabel(SourceDiagOp op) {
    switch (op) {
      case SourceDiagOp.search:
        return 'Search';
      case SourceDiagOp.discovery:
        return 'Discovery';
      case SourceDiagOp.detail:
        return 'Detail';
      case SourceDiagOp.chapters:
        return 'Chapters';
      case SourceDiagOp.content:
        return 'Content';
      case SourceDiagOp.fallback:
        return 'Fallback';
    }
  }
}
