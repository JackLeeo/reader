import 'dart:convert';

import '../entities/source_rule.dart';

/// JSONPath 分析器（对应官方 `AnalyzeByJSonPath`，基于 json-path）。
///
/// 支持常用子集：`$`、`.key`、`[index]`、`..recursive`、通配 `*`、slice、filter。
class AnalyzeJson {
  AnalyzeJson._();

  /// 取第一条匹配字符串（官方 `getString`）。
  static String getString(RuleValue ctx, String path) {
    final v = value(ctx);
    final result = evaluate(v, path);
    return _stringify(result);
  }

  /// 取列表（官方 `getList`）。
  static List<RuleValue> getList(RuleValue ctx, String path) {
    final v = value(ctx);
    final result = evaluate(v, path);
    if (result is List) {
      return result.map((e) => RuleJsonValue(e)).toList();
    }
    return const [];
  }

  /// 取对象（官方 `getObject`）。
  static Object? getObject(RuleValue ctx, String path) {
    final v = value(ctx);
    return evaluate(v, path);
  }

  static Object? value(RuleValue ctx) => switch (ctx) {
        RuleJsonValue(:final value) => value,
        RuleTextValue(:final text) => _tryDecode(text),
        RuleElementValue() => null,
      };

  static Object? _tryDecode(String text) {
    try {
      return _decode(text);
    } catch (_) {
      return null;
    }
  }

  // 极简 JSON decode（不用 dart:convert 以避免平台差异——实际上可用，这里直接列 import fix）
  static Object? _decode(String s) {
    try {
      return jsonDecode(s);
    } catch (_) {
      return null;
    }
  }

  static String _stringify(Object? result) {
    if (result == null) return '';
    if (result is String) return result;
    if (result is num || result is bool) return result.toString();
    if (result is Map || result is List) {
      // json encode 精简字符串
      return _compact(result);
    }
    return result.toString();
  }

  static String _compact(Object? v) {
    if (v == null) return 'null';
    if (v is String) return '"$v"';
    if (v is num || v is bool) return v.toString();
    if (v is List) return '[${v.map(_compact).join(',')}]';
    if (v is Map) {
      return '{${v.entries.map((e) => '"${e.key}":${_compact(e.value)}').join(',')}}';
    }
    return 'null';
  }

  /// 求值主逻辑。
  static Object? evaluate(Object? root, String path) {
    if (path.isEmpty) return root;
    var p = path.trim();
    if (p.startsWith('\$')) p = p.substring(1);
    if (p.isEmpty) return root;

    Object? current = root;
    var rest = p;

    // 处理递归 `..name`
    if (rest.startsWith('..')) {
      final key = rest.substring(2);
      return _recursiveFirst(root, key);
    }

    while (rest.isNotEmpty) {
      rest = rest.trimLeft();
      if (rest.startsWith('.')) {
        rest = rest.substring(1).trimLeft();
        final (key, remain) = _takeKey(rest);
        if (key.isEmpty) break;
        current = _lookup(current, key);
        rest = remain;
      } else if (rest.startsWith('[')) {
        final close = _findCloseBracket(rest);
        if (close < 0) break;
        final expr = rest.substring(1, close).trim();
        rest = rest.substring(close + 1);
        current = _applyIndex(current, expr);
      } else {
        final (key, remain) = _takeKey(rest);
        current = _lookup(current, key);
        rest = remain;
      }
      if (current == null) break;
    }
    return current;
  }

  static (String, String) _takeKey(String s) {
    var i = 0;
    while (i < s.length && s[i] != '.' && s[i] != '[') {
      i++;
    }
    return (s.substring(0, i), s.substring(i));
  }

  static int _findCloseBracket(String s) {
    var depth = 0;
    for (var i = 0; i < s.length; i++) {
      if (s[i] == '[') depth++;
      if (s[i] == ']') {
        depth--;
        if (depth == 0) return i;
      }
    }
    return -1;
  }

  static Object? _lookup(Object? current, String key) {
    if (current is Map) return current[key];
    if (current is List && key.isNotEmpty) {
      final idx = int.tryParse(key);
      if (idx != null && idx >= 0 && idx < current.length) return current[idx];
      return null;
    }
    return null;
  }

  static Object? _applyIndex(Object? current, String expr) {
    if (current is! List) return null;
    // slice: start:end:step
    if (expr.contains(':')) {
      return _slice(current, expr);
    }
    // filter [?(...)]
    if (expr.startsWith('?(') && expr.endsWith(')')) {
      final cond = expr.substring(2, expr.length - 1);
      final hits = <Object?>[];
      for (final item in current) {
        if (item is Map) {
          final m = RegExp(r'@\.(\w+)\s*[=!<>]+\s*(.+)').firstMatch(cond);
          if (m == null) continue;
          final key = m.group(1);
          final rhsRaw = m.group(2)!.trim();
          final val = item[key];
          if (_cmp(val, rhsRaw, cond)) hits.add(item);
        }
      }
      return hits;
    }
    // * wildcard
    if (expr == '*') return current;
    final idx = int.tryParse(expr);
    if (idx != null && idx >= 0) return idx < current.length ? current[idx] : null;
    return null;
  }

  static bool _cmp(Object? val, String rhs, String fullCond) {
    // 支持 `==` `!=` `>` `<` 比较
    final v = (fullCond.contains('==') || fullCond.contains('!='))
        ? val
        : (val is num ? val : int.tryParse(val?.toString() ?? ''));
    if (fullCond.contains('==')) return val?.toString() == stripQuotes(rhs);
    if (fullCond.contains('!=')) return val?.toString() != stripQuotes(rhs);
    if (fullCond.contains('>=')) return _num(v) >= _num(double.tryParse(rhs));
    if (fullCond.contains('<=')) return _num(v) <= _num(double.tryParse(rhs));
    if (fullCond.contains('>')) return _num(v) > _num(double.tryParse(rhs));
    if (fullCond.contains('<')) return _num(v) < _num(double.tryParse(rhs));
    return false;
  }

  static double _num(Object? v) => (v is num) ? v.toDouble() : double.tryParse(v?.toString() ?? '') ?? 0;

  static String stripQuotes(String s) {
    var t = s.trim();
    while (t.length >= 2 &&
        ((t.startsWith("'") && t.endsWith("'")) ||
            (t.startsWith('"') && t.endsWith('"')))) {
      t = t.substring(1, t.length - 1);
    }
    return t;
  }

  static List<Object?> _slice(List list, String expr) {
    final parts = expr.split(':');
    final start = parts.isNotEmpty && parts[0].isNotEmpty ? int.tryParse(parts[0]) : null;
    final end = parts.length > 1 && parts[1].isNotEmpty ? int.tryParse(parts[1]) : null;
    final step = parts.length > 2 && parts[2].isNotEmpty ? int.tryParse(parts[2]) : null;
    final s = start ?? 0;
    final e = end ?? list.length;
    final st = step ?? 1;
    return [for (var i = s; (st > 0 ? i < e : i > e); i += st) if (i >= 0 && i < list.length) list[i]];
  }

  static Object? _recursiveFirst(Object? root, String key) {
    if (root is Map) {
      if (root.containsKey(key)) return root[key];
      for (final v in root.values) {
        final r = _recursiveFirst(v, key);
        if (r != null) return r;
      }
    } else if (root is List) {
      for (final v in root) {
        final r = _recursiveFirst(v, key);
        if (r != null) return r;
      }
    }
    return null;
  }
}