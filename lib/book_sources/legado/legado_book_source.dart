import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../models/registered_book_source.dart';

enum LegadoCompatibilityLevel { supported, partial, unsupported }

/// 发现页入口：标题 + 展开前的地址模板。
class LegadoExploreEntry {
  const LegadoExploreEntry({required this.title, required this.url});

  final String title;
  final String url;
}

enum LegadoCompatibilityIssue {
  video,
  login,
  customDns,
  customProxy,
  missingSearch,
  missingReadingRules,
}

class LegadoBookSource {
  const LegadoBookSource._(this.raw);

  factory LegadoBookSource.fromJson(Map<String, dynamic> json) {
    final raw = Map<String, dynamic>.unmodifiable(json);
    if (_string(raw['bookSourceUrl']).isEmpty ||
        _string(raw['bookSourceName']).isEmpty) {
      throw const FormatException(
        'Legado source requires bookSourceUrl and bookSourceName.',
      );
    }
    final uri = Uri.tryParse(_string(raw['bookSourceUrl']).split('#').first);
    if (uri == null ||
        !uri.hasAuthority ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw const FormatException(
        'Legado bookSourceUrl must be an absolute HTTP(S) URL.',
      );
    }
    return LegadoBookSource._(raw);
  }

  final Map<String, dynamic> raw;

  String get url => _string(raw['bookSourceUrl']);
  String get name => _string(raw['bookSourceName']);
  String get group => _string(raw['bookSourceGroup']);
  String get comment => _string(raw['bookSourceComment']);
  int get type => _integer(raw['bookSourceType']);
  String get searchUrl => _string(raw['searchUrl']);
  String get exploreUrl => _string(raw['exploreUrl']);
  bool get enabledCookieJar => raw['enabledCookieJar'] == true;
  int get lastUpdateTime => _integer(raw['lastUpdateTime']);
  int get respondTime => _integer(raw['respondTime']);

  Uri get baseUri => Uri.parse(url.split('#').first);

  /// 解析发现页入口。Legado 的 exploreUrl 有两种写法：
  /// 文本行 `标题::地址`，或 JSON 数组 `[{"title":"..","url":".."}]`。
  List<LegadoExploreEntry> get exploreEntries {
    final text = exploreUrl;
    if (text.isEmpty) return const [];
    final entries = <LegadoExploreEntry>[];
    if (text.trim().startsWith('[')) {
      try {
        final decoded = jsonDecode(text);
        if (decoded is List) {
          for (final item in decoded) {
            if (item is! Map) continue;
            final title = _string(item['title']);
            final url = _string(item['url']);
            if (url.isNotEmpty) {
              entries.add(LegadoExploreEntry(title: title, url: url));
            }
          }
        }
      } on FormatException {
        return const [];
      }
      return entries;
    }
    for (final line in text.split(RegExp(r'[\n\r]+'))) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final separator = trimmed.indexOf('::');
      final title = separator > 0 ? trimmed.substring(0, separator).trim() : '';
      final url = separator > 0
          ? trimmed.substring(separator + 2).trim()
          : trimmed;
      final cleanedUrl = url.split(RegExp(r'\s*,\s*')).first.trim();
      if (cleanedUrl.isNotEmpty) {
        entries.add(LegadoExploreEntry(title: title, url: cleanedUrl));
      }
    }
    return entries;
  }

  String get stableId =>
      'legado.${sha256.convert(utf8.encode(url)).toString().substring(0, 24)}';

  Map<String, dynamic> rule(String name) {
    final value = raw[name];
    if (value is Map) {
      return value.map((key, value) => MapEntry('$key', value));
    }
    if (value is String && value.trim().startsWith('{')) {
      try {
        final decoded = jsonDecode(value);
        if (decoded is Map) {
          return decoded.map((key, value) => MapEntry('$key', value));
        }
      } on FormatException {
        return const {};
      }
    }
    return const {};
  }

  bool get hasMalformedRuleJson {
    for (final name in const [
      'ruleSearch',
      'ruleBookInfo',
      'ruleToc',
      'ruleContent',
    ]) {
      final value = raw[name];
      if (value is! String || !value.trim().startsWith('{')) continue;
      try {
        if (jsonDecode(value) is! Map) return true;
      } on FormatException {
        return true;
      }
    }
    return false;
  }

  RegisteredBookSource toRegisteredSource({
    bool enabled = false,
    bool readingChainVerified = false,
  }) {
    final report = const LegadoCompatibilityScanner().scan(this);
    final canEnable = report.canRun && readingChainVerified;
    // 带 exploreUrl 的源同时开放发现页能力：分类=发现入口列表，
    // 浏览=按入口地址拉取书籍列表（Legado 的发现走 ruleExplore）。
    final capabilities = <String>{
      if (canEnable) 'search',
      if (canEnable) 'detail',
      if (canEnable) 'catalog',
      if (canEnable) 'content',
      if (canEnable && exploreEntries.isNotEmpty) ...const [
        'discover',
        'categories',
        'browse',
      ],
    };
    return RegisteredBookSource(
      id: stableId,
      name: name,
      description: comment,
      manifestUrl: baseUri,
      apiBaseUrl: baseUri,
      websiteUrl: baseUri,
      protocolVersion: 'legado-3',
      languages: const [],
      capabilities: capabilities,
      enabled: enabled && canEnable,
      addedAt: DateTime.now(),
      sourceProtocol: BookSourceProtocolKind.legado,
      sourceConfig: {
        ...raw,
        if (readingChainVerified)
          '_openReadingReadingChainVerifiedAt': DateTime.now()
              .toUtc()
              .toIso8601String(),
      },
    );
  }
}

bool isReadingChainVerifiedLegadoSource(RegisteredBookSource source) {
  return source.sourceProtocol == BookSourceProtocolKind.legado &&
      source.sourceConfig?['_openReadingReadingChainVerifiedAt'] is String;
}

class LegadoCompatibilityReport {
  const LegadoCompatibilityReport({required this.level, required this.issues});

  final LegadoCompatibilityLevel level;
  final Set<LegadoCompatibilityIssue> issues;

  bool get canRun => level == LegadoCompatibilityLevel.supported;
}

class LegadoCompatibilityScanner {
  const LegadoCompatibilityScanner();

  LegadoCompatibilityReport scan(LegadoBookSource source) {
    final issues = <LegadoCompatibilityIssue>{};
    // 听书(1)/漫画(2)/文件(3) 源已由引擎支持：音频走播放器、图片走
    // 媒体阅读视图、文件源正文即文本。仅视频(4)超出阅读器能力。
    if (source.type == 4) {
      issues.add(LegadoCompatibilityIssue.video);
    }
    if (source.searchUrl.isEmpty) {
      issues.add(LegadoCompatibilityIssue.missingSearch);
    }
    if (source.hasMalformedRuleJson) {
      issues.add(LegadoCompatibilityIssue.missingReadingRules);
    }
    if (source.rule('ruleToc').isEmpty || source.rule('ruleContent').isEmpty) {
      issues.add(LegadoCompatibilityIssue.missingReadingRules);
    }
    // 自定义引擎已支持：JS 脚本（QuickJS 桥）、Cookie（CookieJar）、
    // XPath 与完整 JSONPath 规则，这些不再构成兼容性问题。
    _walk(source.raw, (key, value) {
      if (value is! String || value.trim().isEmpty) return;
      final field = key.toLowerCase();
      final text = value.toLowerCase();
      if (field == 'loginurl' ||
          field == 'loginui' ||
          field == 'logincheckjs') {
        issues.add(LegadoCompatibilityIssue.login);
      }
      if (text.contains('"dnsip"')) {
        issues.add(LegadoCompatibilityIssue.customDns);
      }
      if (text.contains('"proxy"')) {
        issues.add(LegadoCompatibilityIssue.customProxy);
      }
    });

    const blocked = {
      LegadoCompatibilityIssue.video,
      LegadoCompatibilityIssue.login,
      LegadoCompatibilityIssue.customDns,
      LegadoCompatibilityIssue.customProxy,
      LegadoCompatibilityIssue.missingSearch,
      LegadoCompatibilityIssue.missingReadingRules,
    };
    final hasBlockedIssue = issues.any(blocked.contains);
    final level = hasBlockedIssue
        ? LegadoCompatibilityLevel.unsupported
        : issues.isEmpty
        ? LegadoCompatibilityLevel.supported
        : LegadoCompatibilityLevel.partial;
    return LegadoCompatibilityReport(
      level: level,
      issues: Set.unmodifiable(issues),
    );
  }
}

class LegadoSourceImportResult {
  const LegadoSourceImportResult({
    required this.sources,
    required this.sourceUrls,
    required this.errors,
  });

  final List<LegadoBookSource> sources;
  final List<Uri> sourceUrls;
  final List<String> errors;
}

LegadoSourceImportResult parseLegadoSources(
  String input, {
  int maxSources = 10000,
  int maxNestedUrls = 50,
}) {
  final text = input.replaceFirst('\ufeff', '').trim();
  if (text.isEmpty) throw const FormatException('Source JSON is empty.');
  final decoded = jsonDecode(text);
  final sourceUrls = <Uri>[];
  final candidates = <Object?>[];
  if (decoded is List) {
    candidates.addAll(decoded);
  } else if (decoded is Map) {
    final nested = decoded['sourceUrls'];
    if (nested is List) {
      if (nested.length > maxNestedUrls) {
        throw FormatException(
          'Too many nested source URLs (max $maxNestedUrls).',
        );
      }
      for (final value in nested) {
        final uri = Uri.tryParse('$value');
        if (uri == null ||
            !uri.hasAuthority ||
            (uri.scheme != 'http' && uri.scheme != 'https')) {
          throw const FormatException('Nested source URL must use HTTP(S).');
        }
        sourceUrls.add(uri);
      }
    } else if (decoded.containsKey('bookSourceUrl')) {
      candidates.add(decoded);
    } else {
      for (final key in const ['bookSourceList', 'sources', 'data']) {
        final value = decoded[key];
        if (value is List) {
          candidates.addAll(value);
          break;
        }
      }
    }
  } else {
    throw const FormatException('Expected a source object or array.');
  }
  if (candidates.length > maxSources) {
    throw FormatException('Too many sources (max $maxSources).');
  }
  final byUrl = <String, LegadoBookSource>{};
  final errors = <String>[];
  for (var index = 0; index < candidates.length; index++) {
    final candidate = candidates[index];
    if (candidate is! Map) {
      errors.add('Item ${index + 1} is not an object.');
      continue;
    }
    try {
      final source = LegadoBookSource.fromJson(
        candidate.map((key, value) => MapEntry('$key', value)),
      );
      byUrl[source.url] = source;
    } on FormatException catch (error) {
      errors.add('Item ${index + 1}: ${error.message}');
    }
  }
  return LegadoSourceImportResult(
    sources: List.unmodifiable(byUrl.values),
    sourceUrls: List.unmodifiable(sourceUrls),
    errors: List.unmodifiable(errors),
  );
}

void _walk(Object? value, void Function(String key, Object? value) visitor) {
  if (value is Map) {
    for (final entry in value.entries) {
      final key = '${entry.key}';
      visitor(key, entry.value);
      _walk(entry.value, visitor);
    }
  } else if (value is List) {
    for (final item in value) {
      _walk(item, visitor);
    }
  }
}

String _string(Object? value) => value is String ? value.trim() : '';

int _integer(Object? value) => switch (value) {
  num number => number.toInt(),
  String text => int.tryParse(text) ?? 0,
  _ => 0,
};
