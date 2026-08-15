// 文件说明：书源诊断工具（source doctor）——在 flutter test 环境里复用
// 应用真实的解析/搜索/目录/正文链路，用于离线调试书源问题与治理书源质量。
//
// 用法（PowerShell）:
//   $env:SD_MODE='chain';  flutter test test/source_doctor_test.dart
//   $env:SD_MODE='chain';  $env:SD_SOURCE='奇书,笔尖'; flutter test test/source_doctor_test.dart
//   $env:SD_MODE='health'; flutter test test/source_doctor_test.dart
//   $env:SD_MODE='export'; flutter test test/source_doctor_test.dart
//
// 可选环境变量 (或等价字段写入 tool/doctor_config.json, 环境变量优先):
//   SD_QUERY        搜索关键词, 默认 "剑来"
//   SD_SOURCE       chain 模式的源名过滤(逗号分隔子串); 未指定时均匀抽样
//   SD_LIMIT        chain 抽样数量, 默认 12
//   SD_CONCURRENCY  health 并发上限, 默认 16
//   SD_TIMEOUT_SEC  单请求超时秒数, 默认 8
//   SD_REPORT_DIR   报告输出目录, 默认 tool/reports
//
// doctor_config.json 示例:
//   { "mode": "chain", "source": "奇书,笔尖", "query": "剑来", "limit": 12 }
//
// 模式:
//   chain  — 选中源逐个跑 搜索→详情→目录→正文→发现页 全链路, 输出每步
//            耗时/结果/错误, 用于定位"哪一环断了、为什么断"。
//   health — 全量可运行源并发体检, 按失败根因分类(DNS/拒连/SSL/4xx/
//            超时/JS...), 产出 markdown 报告与机器可读 json。
//   export — 读取 health 结果, 从预装书源剔除"确定性死站"(DNS 失败/
//            拒连/SSL/4xx), 生成优化后的书源文件供审查后替换。
//
// 重要: flutter test 环境没有 QuickJS 运行时, 依赖 JS 的源在这里会报
// "uses scripting" / "unsupported template expression"; 这些源在真机上
// 是可用的, 工具绝不会把这类源当作死源剔除。

import 'dart:convert';
import 'dart:io';

import 'package:xxread/book_sources/legado/legado_book_source.dart';
import 'package:xxread/book_sources/legado/legado_request.dart';
import 'package:xxread/book_sources/legado/legado_runtime.dart';
import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/services/source_concurrency.dart';

class SourceDoctorConfig {
  const SourceDoctorConfig({
    required this.mode,
    required this.query,
    required this.sourceFilters,
    required this.limit,
    required this.concurrency,
    required this.timeoutSec,
    required this.reportDir,
  });

  factory SourceDoctorConfig.fromEnvironment() {
    final env = Platform.environment;
    // 配置文件作为基础值(便于受限终端/一键运行), 环境变量优先覆盖。
    Map<String, dynamic> file = const {};
    final configFile = File('tool/doctor_config.json');
    if (configFile.existsSync()) {
      try {
        final decoded = jsonDecode(configFile.readAsStringSync());
        if (decoded is Map) file = decoded.cast<String, dynamic>();
      } on FormatException {
        // 配置文件损坏时忽略, 全部走默认值/环境变量。
      }
    }
    String pickString(String envKey, String fileKey, String fallback) {
      final value = env[envKey] ?? file[fileKey];
      return value == null ? fallback : '$value';
    }

    int pickInt(String envKey, String fileKey, int fallback) {
      final value = env[envKey] ?? file[fileKey];
      return value == null ? fallback : int.tryParse('$value') ?? fallback;
    }

    final filters = pickString('SD_SOURCE', 'source', '')
        .split(',')
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toList(growable: false);
    return SourceDoctorConfig(
      mode: pickString('SD_MODE', 'mode', 'chain'),
      query: pickString('SD_QUERY', 'query', '剑来'),
      sourceFilters: filters,
      limit: pickInt('SD_LIMIT', 'limit', 12),
      concurrency: pickInt('SD_CONCURRENCY', 'concurrency', 16),
      timeoutSec: pickInt('SD_TIMEOUT_SEC', 'timeoutSec', 8),
      reportDir: pickString('SD_REPORT_DIR', 'reportDir', 'tool/reports'),
    );
  }

  final String mode;
  final String query;
  final List<String> sourceFilters;
  final int limit;
  final int concurrency;
  final int timeoutSec;
  final String reportDir;
}

/// 单源体检结果。
class SourceProbeResult {
  SourceProbeResult({
    required this.name,
    required this.url,
    required this.group,
    required this.outcome,
    required this.failureClass,
    required this.ms,
    this.items,
    this.error,
  });

  final String name;
  final String url;
  final String group;
  /// ok / empty / failed / invalid
  final String outcome;
  /// dns / connect-refused / ssl / http-4xx / http-5xx / timeout / reset /
  /// template / scripting / parse / blocked / invalid / ''(成功)
  final String failureClass;
  final int ms;
  final int? items;
  final String? error;

  bool get isDead =>
      failureClass == 'dns' ||
      failureClass == 'connect-refused' ||
      failureClass == 'ssl' ||
      failureClass == 'http-4xx';

  Map<String, dynamic> toJson() => {
    'name': name,
    'url': url,
    'group': group,
    'outcome': outcome,
    'class': failureClass,
    'ms': ms,
    if (items != null) 'items': items,
    if (error != null) 'error': error,
  };
}

const _deadClasses = ['dns', 'connect-refused', 'ssl', 'http-4xx'];

/// 把异常文本归类为失败根因。顺序敏感: 超时判定要在 socket 类之前,
/// 因为 "SocketException: Connection timed out" 同时命中两者。
String classifyError(String message) {
  final m = message.toLowerCase();
  if (m.contains('failed host lookup') ||
      m.contains('nodename nor servname') ||
      m.contains('dns resolution')) {
    return 'dns';
  }
  if (m.contains('connection refused')) return 'connect-refused';
  if (m.contains('handshakeexception') ||
      m.contains('certificate') ||
      m.contains('tls client')) {
    return 'ssl';
  }
  if (RegExp(r'(status code of|http)\s*4\d\d').hasMatch(m)) return 'http-4xx';
  if (RegExp(r'(status code of|http)\s*5\d\d').hasMatch(m)) return 'http-5xx';
  if (m.contains('timed out') || m.contains('timeout')) return 'timeout';
  if (m.contains('connection reset') ||
      m.contains('connection closed') ||
      m.contains('network is unreachable') ||
      m.contains('socketexception') ||
      m.contains('connection terminated')) {
    return 'reset';
  }
  if (m.contains('unsupported template')) return 'template';
  if (m.contains('scripting')) return 'scripting';
  if (m.contains('redirected too many') ||
      m.contains('not allowed as a book source target')) {
    return 'blocked';
  }
  return 'other';
}

Future<void> runSourceDoctor() async {
  final cfg = SourceDoctorConfig.fromEnvironment();
  // 关键: TestWidgetsFlutterBinding 会安装全局 HttpOverrides, 把所有
  // HttpClient 请求 mock 成空 body 的 HTTP 400 (flutter_test 防止测试
  // 意外联网的机制)。doctor 依赖真实网络, 必须显式恢复默认实现,
  // 否则所有书源统一 400、体检结果全部失真。
  HttpOverrides.global = null;
  final reportDir = Directory(cfg.reportDir);
  await reportDir.create(recursive: true);
  final items = await _loadSourceItems();
  final sources = <LegadoBookSource>[];
  for (final item in items) {
    if (item is! Map) continue;
    try {
      sources.add(
        LegadoBookSource.fromJson(item.cast<String, dynamic>()),
      );
    } on FormatException {
      // 无效条目在 health 报告里单独统计。
    }
  }
  print('source-doctor: mode=${cfg.mode} sources=${sources.length}');
  switch (cfg.mode) {
    case 'health':
      await _runHealth(cfg, reportDir, sources, items);
    case 'export':
      await _runExport(cfg, reportDir, items);
    default:
      await _runChain(cfg, reportDir, sources);
  }
}

Future<List<dynamic>> _loadSourceItems() async {
  final raw = await File(
    'assets/book_sources/perfect_sources.json',
  ).readAsString();
  final decoded = jsonDecode(raw);
  return decoded is List ? decoded : (decoded as Map)['items'] as List? ?? [];
}

LegadoRuntime _buildRuntime(
  SourceDoctorConfig cfg, {
  bool logging = false,
}) => LegadoRuntime(
  transport: logging
      ? _LoggingTransport(
          LegadoHttpTransport(
            requestTimeout: Duration(seconds: cfg.timeoutSec),
          ),
        )
      : LegadoHttpTransport(
          requestTimeout: Duration(seconds: cfg.timeoutSec),
        ),
);

/// 传输层日志装饰器(chain 模式): 打印每个请求的 URL 与结果, 用于
/// 定位"哪一环断了、发去了哪里"。
class _LoggingTransport implements LegadoTransport {
  _LoggingTransport(this.inner);

  final LegadoTransport inner;

  @override
  Future<LegadoResponse> send(LegadoRequestTemplate request) async {
    final sw = Stopwatch()..start();
    final label =
        '${request.method == LegadoRequestMethod.post ? 'POST' : 'GET'} '
        '${request.url}';
    try {
      final resp = await inner.send(request);
      print(
        '  [net] $label -> ${resp.finalUri} ${resp.body.length}B '
        '${sw.elapsedMilliseconds}ms',
      );
      return resp;
    } catch (e) {
      print('  [net] $label -> FAIL ${sw.elapsedMilliseconds}ms $e');
      rethrow;
    }
  }
}

RegisteredBookSource _registeredOf(LegadoBookSource source) =>
    RegisteredBookSource(
      id: 'doctor-${source.stableId}',
      name: source.name,
      description: '',
      manifestUrl: source.baseUri,
      apiBaseUrl: source.baseUri,
      protocolVersion: 'legado-3',
      languages: const [],
      capabilities: const {'search', 'detail', 'catalog', 'content'},
      enabled: true,
      addedAt: DateTime.now(),
      sourceProtocol: BookSourceProtocolKind.legado,
      sourceConfig: source.raw,
    );

// ---------------------------------------------------------------------------
// chain: 单源/抽样全链路深调
// ---------------------------------------------------------------------------

Future<void> _runChain(
  SourceDoctorConfig cfg,
  Directory reportDir,
  List<LegadoBookSource> sources,
) async {
  final runnable = sources
      .where((source) => const LegadoCompatibilityScanner().scan(source).canRun)
      .toList(growable: false);
  final selected = _selectForChain(cfg, runnable);
  final runtime = _buildRuntime(cfg);
  final buffer = StringBuffer();
  buffer.writeln('# 书源全链路诊断 ${_now()}');
  buffer.writeln();
  buffer.writeln(
    '- 查询词: ${cfg.query}  源数: ${selected.length}/${runnable.length} '
    '(可运行 ${runnable.length}/${sources.length})  单步超时: ${cfg.timeoutSec}s',
  );
  print('chain: selected ${selected.length} of ${runnable.length} runnable');

  for (final source in selected) {
    buffer.writeln();
    buffer.writeln('## ${source.name}  ${source.baseUri}');
    final registered = _registeredOf(source);
    final lines = <String>[];

    // 1) 搜索
    var bookId = '';
    final searchSw = Stopwatch()..start();
    try {
      final page = await runtime
          .search(registered, cfg.query)
          .timeout(_stepBudget(cfg));
      final first = page.items.isEmpty ? '' : page.items.first.title;
      final firstLabel = first.isEmpty ? '' : ' first="$first"';
      lines.add(
        '- search: ok ${searchSw.elapsedMilliseconds}ms '
        'items=${page.items.length}$firstLabel',
      );
      if (page.items.isEmpty) {
        lines.add('- chain stop: 搜索无结果');
      } else {
        bookId = page.items.first.id;
      }
    } catch (error) {
      lines.add(
        '- search: FAIL[${classifyError(error.toString())}] '
        '${searchSw.elapsedMilliseconds}ms ${_short(error.toString())}',
      );
    }

    // 2) 详情 + 3) 目录 + 4) 正文
    if (bookId.isNotEmpty) {
      final detailSw = Stopwatch()..start();
      try {
        final book = await runtime
            .getBook(registered, bookId)
            .timeout(_stepBudget(cfg));
        lines.add(
          '- detail: ok ${detailSw.elapsedMilliseconds}ms '
          '"${book.title}" / "${book.author}"',
        );
      } catch (error) {
        lines.add(
          '- detail: FAIL[${classifyError(error.toString())}] '
          '${detailSw.elapsedMilliseconds}ms ${_short(error.toString())}',
        );
      }

      final tocSw = Stopwatch()..start();
      var firstChapterId = '';
      try {
        final chapters = await runtime
            .getChapters(registered, bookId)
            .timeout(_stepBudget(cfg));
        lines.add(
          '- toc: ok ${tocSw.elapsedMilliseconds}ms chapters=${chapters.length}',
        );
        if (chapters.isNotEmpty) firstChapterId = chapters.first.id;
      } catch (error) {
        lines.add(
          '- toc: FAIL[${classifyError(error.toString())}] '
          '${tocSw.elapsedMilliseconds}ms ${_short(error.toString())}',
        );
      }

      if (firstChapterId.isNotEmpty) {
        final contentSw = Stopwatch()..start();
        try {
          final content = await runtime
              .getChapterContent(
                registered,
                bookId: bookId,
                chapterId: firstChapterId,
              )
              .timeout(_stepBudget(cfg));
          final text = content.content;
          final preview = text.isEmpty && (content.imageUrls?.isNotEmpty ?? false)
              ? '[图片章节 ${content.imageUrls!.length} 张]'
              : '"${text.length > 60 ? '${text.substring(0, 60)}…' : text}"';
          lines.add(
            '- content: ok ${contentSw.elapsedMilliseconds}ms '
            'len=${text.length} $preview',
          );
        } catch (error) {
          lines.add(
            '- content: FAIL[${classifyError(error.toString())}] '
            '${contentSw.elapsedMilliseconds}ms ${_short(error.toString())}',
          );
        }
      }
    }

    // 5) 发现页链路
    if (source.exploreEntries.isNotEmpty) {
      final exploreSw = Stopwatch()..start();
      try {
        final discovery = await runtime
            .getDiscovery(registered)
            .timeout(_stepBudget(cfg));
        final sections = discovery.sections;
        final count = sections.fold<int>(
          0,
          (sum, section) => sum + section.items.length,
        );
        lines.add(
          '- explore: ok ${exploreSw.elapsedMilliseconds}ms '
          'entries=${source.exploreEntries.length} '
          'sections=${sections.length} items=$count '
          '"${sections.isEmpty ? '' : sections.first.title}"',
        );
      } catch (error) {
        lines.add(
          '- explore: FAIL[${classifyError(error.toString())}] '
          '${exploreSw.elapsedMilliseconds}ms ${_short(error.toString())}',
        );
      }
    } else {
      lines.add('- explore: 无发现页入口');
    }

    for (final line in lines) {
      buffer.writeln(line);
      print('  $line');
    }
  }
  runtime.close();
  await File(
    '${reportDir.path}${Platform.pathSeparator}source_doctor_chain.md',
  ).writeAsString(buffer.toString());
  print('chain report written to tool/reports/source_doctor_chain.md');
}

Duration _stepBudget(SourceDoctorConfig cfg) =>
    Duration(seconds: cfg.timeoutSec + 12);

List<LegadoBookSource> _selectForChain(
  SourceDoctorConfig cfg,
  List<LegadoBookSource> runnable,
) {
  if (cfg.sourceFilters.isNotEmpty) {
    final matched = runnable
        .where(
          (source) => cfg.sourceFilters.any(
            (filter) => source.name.contains(filter),
          ),
        )
        .toList(growable: false);
    if (matched.isNotEmpty) return matched;
    print('chain: no source matches ${cfg.sourceFilters}, falling back to sample');
  }
  if (runnable.length <= cfg.limit) return runnable;
  final step = runnable.length ~/ cfg.limit;
  return [
    for (var i = 0; i < runnable.length; i += step) runnable[i],
  ];
}

// ---------------------------------------------------------------------------
// health: 全量体检
// ---------------------------------------------------------------------------

Future<void> _runHealth(
  SourceDoctorConfig cfg,
  Directory reportDir,
  List<LegadoBookSource> sources,
  List<dynamic> rawItems,
) async {
  final scanner = const LegadoCompatibilityScanner();
  final runnable = <LegadoBookSource>[];
  final blockedIssues = <String, int>{};
  for (final source in sources) {
    final report = scanner.scan(source);
    if (report.canRun) {
      runnable.add(source);
    } else {
      for (final issue in report.issues) {
        final key = issue.name;
        blockedIssues[key] = (blockedIssues[key] ?? 0) + 1;
      }
    }
  }
  final runtime = _buildRuntime(cfg);
  final limiter = BookSourceConcurrencyLimiter(cfg.concurrency);
  final budget = Duration(seconds: cfg.timeoutSec + 7);
  var done = 0;
  final results = await Future.wait(
    runnable.map((source) {
      return limiter.run(() async {
        final result = await _probeSearch(source, runtime, cfg, budget);
        done++;
        if (done % 25 == 0) print('health: $done/${runnable.length}');
        return result;
      });
    }),
  );
  runtime.close();

  final ordered = results.toList()
    ..sort((a, b) => _classRank(a.failureClass).compareTo(_classRank(b.failureClass)));
  await _writeHealthJson(cfg, reportDir, ordered, sources, rawItems);
  _writeHealthMarkdown(cfg, reportDir, ordered, runnable.length, blockedIssues);
}

int _classRank(String failureClass) => switch (failureClass) {
  '' => 0,
  'empty' => 1,
  'timeout' => 2,
  'reset' => 3,
  'http-5xx' => 4,
  'parse' || 'other' => 5,
  'template' || 'scripting' => 6,
  'http-4xx' => 7,
  'ssl' => 8,
  'connect-refused' => 9,
  'dns' => 10,
  _ => 11,
};

Future<SourceProbeResult> _probeSearch(
  LegadoBookSource source,
  LegadoRuntime runtime,
  SourceDoctorConfig cfg,
  Duration budget,
) async {
  final sw = Stopwatch()..start();
  final url = source.baseUri.toString();
  if (!url.startsWith('http')) {
    return SourceProbeResult(
      name: source.name,
      url: url,
      group: source.group,
      outcome: 'invalid',
      failureClass: 'invalid',
      ms: 0,
      error: '书源地址不是有效 HTTP 地址',
    );
  }
  try {
    final page = await runtime
        .search(_registeredOf(source), cfg.query)
        .timeout(budget);
    return SourceProbeResult(
      name: source.name,
      url: url,
      group: source.group,
      outcome: page.items.isEmpty ? 'empty' : 'ok',
      failureClass: page.items.isEmpty ? 'empty' : '',
      ms: sw.elapsedMilliseconds,
      items: page.items.length,
      error: page.items.isEmpty ? '搜索关键词无结果(规则可能失效或站点改版)' : null,
    );
  } catch (error) {
    return SourceProbeResult(
      name: source.name,
      url: url,
      group: source.group,
      outcome: 'failed',
      failureClass: classifyError(error.toString()),
      ms: sw.elapsedMilliseconds,
      error: _short(error.toString(), 160),
    );
  }
}

Future<void> _writeHealthJson(
  SourceDoctorConfig cfg,
  Directory reportDir,
  List<SourceProbeResult> results,
  List<LegadoBookSource> sources,
  List<dynamic> rawItems,
) async {
  final payload = {
    'generatedAt': _now(),
    'query': cfg.query,
    'timeoutSec': cfg.timeoutSec,
    'totalRaw': rawItems.length,
    'parsed': sources.length,
    'results': [for (final result in results) result.toJson()],
  };
  await File(
    '${reportDir.path}${Platform.pathSeparator}source_doctor_results.json',
  ).writeAsString(
    const JsonEncoder.withIndent('  ').convert(payload),
  );
}

void _writeHealthMarkdown(
  SourceDoctorConfig cfg,
  Directory reportDir,
  List<SourceProbeResult> results,
  int runnableCount,
  Map<String, int> blockedIssues,
) {
  final byClass = <String, List<SourceProbeResult>>{};
  for (final result in results) {
    byClass
        .putIfAbsent(result.failureClass.isEmpty ? 'ok' : result.failureClass, () => [])
        .add(result);
  }
  final ok = byClass['ok'] ?? const [];
  final okAvg = ok.isEmpty
      ? 0
      : ok.fold<int>(0, (sum, r) => sum + r.ms) ~/ ok.length;
  final dead = results.where((result) => result.isDead).toList();
  final slowest = [...results]..sort((a, b) => b.ms.compareTo(a.ms));

  final buffer = StringBuffer();
  buffer.writeln('# 书源体检报告 ${_now()}');
  buffer.writeln();
  buffer.writeln(
    '- 查询词: ${cfg.query}  单源超时: ${cfg.timeoutSec}s  并发: ${cfg.concurrency}',
  );
  buffer.writeln('- 体检源数(可运行): $runnableCount');
  buffer.writeln(
    '- 扫描拦截(应用内同样不可用): ${blockedIssues.isEmpty ? "无" : blockedIssues.entries.map((e) => "${e.key}=${e.value}").join(", ")}',
  );
  buffer.writeln();
  buffer.writeln('## 总览');
  buffer.writeln();
  buffer.writeln('| 分类 | 数量 | 说明 |');
  buffer.writeln('| --- | --- | --- |');
  buffer.writeln('| 搜索成功 | ${ok.length} | 平均 ${okAvg}ms |');
  for (final entry in {
    'empty': '搜索无结果(规则可能失效)',
    'timeout': '超时(网络波动或站点慢, 保留观察)',
    'reset': '连接被重置(可能反爬/网络不稳, 保留观察)',
    'http-5xx': '服务器 5xx(可能临时故障, 保留观察)',
    'template': 'URL 模板本地无法求值(真机有 JS 引擎, 可用)',
    'scripting': '依赖 JS 脚本(真机有 QuickJS, 可用)',
    'parse': '解析失败(规则不匹配, 需修规则)',
    'other': '其他错误',
    'blocked': '重定向循环/地址被安全策略拦截',
    'http-4xx': 'HTTP 4xx(站点拒绝/已下线, 判定死站)',
    'ssl': 'TLS 证书失败, 判定死站',
    'connect-refused': '连接被拒, 判定死站',
    'dns': '域名解析失败(站点已消失), 判定死站',
    'invalid': '书源地址无效',
  }.entries) {
    final list = byClass[entry.key];
    if (list == null || list.isEmpty) continue;
    buffer.writeln('| ${entry.key} | ${list.length} | ${entry.value} |');
  }
  buffer.writeln();
  buffer.writeln('> 确定性死站合计: **${dead.length}** (dns/connect-refused/ssl/http-4xx)');
  buffer.writeln();

  void writeTable(String title, List<SourceProbeResult> list, {bool withMs = true}) {
    if (list.isEmpty) return;
    buffer.writeln('## $title');
    buffer.writeln();
    final msColumn = withMs ? '耗时 | ' : '';
    final msAlign = withMs ? '---: | ' : '';
    buffer.writeln('| 书源 | 分类 | ${msColumn}错误 |');
    buffer.writeln('| --- | --- | ${msAlign}--- |');
    for (final result in list) {
      final outcome = result.failureClass.isEmpty ? 'ok' : result.failureClass;
      final msCell = withMs ? '${result.ms}ms | ' : '';
      final errorCell = _escapeCell(result.error ?? '');
      buffer.writeln('| ${_escapeCell(result.name)} | $outcome | ${msCell}$errorCell |');
    }
    buffer.writeln();
  }

  writeTable('确定性死站清单 (export 模式会剔除)', dead);
  writeTable('超时/最慢源 top 20', slowest.take(20).toList());
  writeTable('解析失败清单', [
    ...?byClass['parse'],
    ...?byClass['other'],
  ]);
  writeTable('JS/模板依赖清单 (真机可用, 不剔除)', [
    ...?byClass['template'],
    ...?byClass['scripting'],
  ]);
  writeTable('空结果清单', byClass['empty'] ?? const []);

  File(
    '${reportDir.path}${Platform.pathSeparator}source_doctor_health.md',
  ).writeAsStringSync(buffer.toString());
  print(
    'health: ok=${ok.length} empty=${(byClass['empty'] ?? const []).length} '
    'dead=${dead.length} report -> tool/reports/source_doctor_health.md',
  );
}

// ---------------------------------------------------------------------------
// export: 剔除死站, 生成优化书源
// ---------------------------------------------------------------------------

Future<void> _runExport(
  SourceDoctorConfig cfg,
  Directory reportDir,
  List<dynamic> rawItems,
) async {
  final resultsFile = File(
    '${reportDir.path}${Platform.pathSeparator}source_doctor_results.json',
  );
  if (!resultsFile.existsSync()) {
    print('export: 先跑 health 模式生成 source_doctor_results.json');
    return;
  }
  final payload = jsonDecode(await resultsFile.readAsString()) as Map;
  // URL 匹配前统一去掉末尾斜杠: baseUri 解析会自动补 "/", 原始
  // bookSourceUrl 则两种写法都有, 不规范化会漏剔。
  String normalizeUrl(String url) {
    var normalized = url.trim();
    while (normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return normalized.toLowerCase();
  }

  final deadUrls = <String>{};
  final deadNames = <String>{};
  for (final raw in payload['results'] as List) {
    final entry = raw as Map;
    final failureClass = '${entry['class']}';
    if (!_deadClasses.contains(failureClass)) continue;
    final url = '${entry['url']}';
    if (url.startsWith('http')) deadUrls.add(normalizeUrl(url));
    deadNames.add('${entry['name']}');
  }
  final kept = <Map<String, dynamic>>[];
  final removed = <Map<String, dynamic>>[];
  for (final item in rawItems) {
    if (item is! Map) continue;
    final map = item.cast<String, dynamic>();
    final url = '${map['bookSourceUrl'] ?? ''}';
    final name = '${map['bookSourceName'] ?? ''}';
    if (deadUrls.contains(normalizeUrl(url)) ||
        (!url.startsWith('http') && deadNames.contains(name))) {
      removed.add(map);
    } else {
      kept.add(map);
    }
  }
  final outFile = File(
    '${reportDir.path}${Platform.pathSeparator}perfect_sources_optimized.json',
  );
  await outFile.writeAsString(
    const JsonEncoder.withIndent('  ').convert(kept),
  );
  print(
    'export: kept=${kept.length} removed=${removed.length} '
    '-> tool/reports/perfect_sources_optimized.json',
  );
  final listBuffer = StringBuffer();
  for (final item in removed) {
    listBuffer.writeln('- ${item['bookSourceName']}  ${item['bookSourceUrl']}');
  }
  await File(
    '${reportDir.path}${Platform.pathSeparator}removed_sources.md',
  ).writeAsString(listBuffer.toString());
}

// ---------------------------------------------------------------------------
// 小工具
// ---------------------------------------------------------------------------

String _now() => DateTime.now().toIso8601String().substring(0, 19);

String _short(String text, [int max = 100]) {
  final line = text.split('\n').first.trim();
  return line.length > max ? '${line.substring(0, max)}…' : line;
}

String _escapeCell(String text) => text.replaceAll('|', r'\|');
