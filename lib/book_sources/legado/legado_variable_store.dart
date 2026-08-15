// 文件说明：Legado 跨请求变量池。
// Legado 协议中 `@put:{name:rule}` 在规则求值过程中存值（如搜索结果页
// 提取 bookUrl 时顺带存下 token），`@get:{name}` 在后续请求的 URL/规则
// 中取值（如 tocUrl: `@get:{t}`）。变量按书源 URL 隔离，跨搜索→详情→
// 目录→正文整个阅读链路共享。缺失该机制时 `@get:{t}` 会被当普通规则
// 解析成空串，导致目录页请求 404——这是阅读链路大面积失败的主因之一。
// 技术要点：按源隔离的 key-value 存储、容量上限防泄漏。

class LegadoVariableStore {
  LegadoVariableStore._();

  static final LegadoVariableStore instance = LegadoVariableStore._();

  /// 每个源最多保留的变量数。真实书源最多用到十几个变量。
  static const int _maxVarsPerSource = 128;

  /// 全局源数量上限，防止导入大量源后内存无界增长。
  static const int _maxSources = 512;

  final Map<String, Map<String, String>> _bySource = {};

  String? get(String sourceUrl, String name) {
    final vars = _bySource[sourceUrl];
    if (vars == null) return null;
    return vars[name];
  }

  void put(String sourceUrl, String name, String value) {
    if (sourceUrl.isEmpty || name.isEmpty) return;
    var vars = _bySource[sourceUrl];
    if (vars == null) {
      if (_bySource.length >= _maxSources) {
        _bySource.remove(_bySource.keys.first);
      }
      _bySource[sourceUrl] = vars = {};
    }
    if (vars.length >= _maxVarsPerSource && !vars.containsKey(name)) {
      vars.remove(vars.keys.first);
    }
    vars[name] = value;
  }

  Map<String, String> snapshot(String sourceUrl) =>
      Map.unmodifiable(_bySource[sourceUrl] ?? const {});

  void merge(String sourceUrl, Map<String, String> updates) {
    for (final entry in updates.entries) {
      put(sourceUrl, entry.key, entry.value);
    }
  }

  void clearSource(String sourceUrl) => _bySource.remove(sourceUrl);

  void clearAll() => _bySource.clear();
}

/// `@get:{name}` / `@put:{name:rule}` 语法解析与展开工具。
class LegadoVariableSyntax {
  static final RegExp getPattern = RegExp(r'@get:\{([^{}]+)\}');
  // @put:{name:rule} —— rule 可含 @、: 等字符，取第一个 `:` 之后全部。
  static final RegExp putPattern = RegExp(r'@put:\{([^{}:]+):([\s\S]*?)\}');

  /// 展开 URL/规则文本中的 `@get:{name}`。
  /// 未命中的变量保持原样（由调用方决定是否报错）。
  static String expandGets(
    String input,
    String Function(String name) lookup,
  ) {
    if (!input.contains('@get:')) return input;
    return input.replaceAllMapped(getPattern, (match) {
      final value = lookup(match.group(1)!.trim());
      return value; // 未命中返回原样
    });
  }

  /// 未命中时保留原始 `@get:{...}` 文本的展开变体。
  static String expandGetsStrict(
    String input,
    String? Function(String name) lookup,
  ) {
    if (!input.contains('@get:')) return input;
    return input.replaceAllMapped(getPattern, (match) {
      final value = lookup(match.group(1)!.trim());
      return value ?? match.group(0)!;
    });
  }
}
