// 文件说明：Legado 完整 JSONPath 求值器，支持书源里常见的全部语法：
// 递归下降 `$..name`、数组切片 `[start:end]`、多索引 `[0,2]`、通配
// `[*]`、过滤 `[?(@.field=='v')]`、负索引与 `@` 当前节点。
// 技术要点：tokenizer + 递归求值。

class LegadoJsonPath {
  const LegadoJsonPath();

  /// 对 [root] 求值 [path]，返回匹配值列表；无匹配返回空列表。
  List<Object?> evaluate(Object? root, String path) {
    var normalized = path.trim();
    if (normalized.startsWith(r'$')) normalized = normalized.substring(1);
    final tokens = _tokenize(normalized);
    var values = <Object?>[root];
    for (final token in tokens) {
      values = _applyToken(values, token);
      if (values.isEmpty) break;
    }
    return values;
  }

  List<_JsonToken> _tokenize(String path) {
    final tokens = <_JsonToken>[];
    var index = 0;
    while (index < path.length) {
      final char = path[index];
      if (char == '.') {
        if (index + 1 < path.length && path[index + 1] == '.') {
          // `..name` 直接并入递归令牌；`..*`/`..[0]` 保持无名的全量递归。
          final deepName = index + 2 < path.length
              ? RegExp(r"[\w$\-]+").matchAsPrefix(path, index + 2)
              : null;
          if (deepName != null) {
            tokens.add(_JsonToken.recursive(text: deepName.group(0)));
            index = deepName.end;
          } else {
            tokens.add(const _JsonToken.recursive());
            index += 2;
          }
          continue;
        }
        index++;
        continue;
      }
      if (char == '[') {
        final end = _findBracketEnd(path, index);
        if (end < 0) break;
        tokens.add(_parseBracket(path.substring(index + 1, end)));
        index = end + 1;
        continue;
      }
      final nameMatch = RegExp(r"[\w$\-]+").matchAsPrefix(path, index);
      if (nameMatch != null) {
        tokens.add(_JsonToken.child(nameMatch.group(0)!));
        index = nameMatch.end;
        continue;
      }
      if (char == '*') {
        tokens.add(const _JsonToken.wildcard());
        index++;
        continue;
      }
      index++;
    }
    return tokens;
  }

  int _findBracketEnd(String path, int start) {
    var depth = 0;
    var inQuote = false;
    var quote = '';
    for (var i = start; i < path.length; i++) {
      final ch = path[i];
      if (inQuote) {
        if (ch == quote) inQuote = false;
        continue;
      }
      if (ch == "'" || ch == '"') {
        inQuote = true;
        quote = ch;
      } else if (ch == '[') {
        depth++;
      } else if (ch == ']') {
        depth--;
        if (depth == 0) return i;
      }
    }
    return -1;
  }

  _JsonToken _parseBracket(String inner) {
    final text = inner.trim();
    if (text == '*') return const _JsonToken.wildcard();
    // 切片 [start:end] / [start:] / [:end] / [::step]。
    if (RegExp(r'^-?\d*\s*:\s*-?\d*(\s*:\s*-?\d+)?$').hasMatch(text)) {
      return _JsonToken.slice(text);
    }
    // 过滤 [?(@.x=='v')]。
    if (text.startsWith('?')) {
      return _JsonToken.filter(text.substring(1).trim());
    }
    // 多键 ['a','b'] / 多索引 [0,2,-1]。
    final parts = _splitCommaTopLevel(text);
    if (parts.length > 1) {
      return _JsonToken.multi(parts.map((part) => part.trim()).toList());
    }
    final quoted = RegExp("^(['\"])(.*?)\\1\$").firstMatch(text);
    if (quoted != null) {
      return _JsonToken.child(quoted.group(2)!);
    }
    final number = int.tryParse(text);
    if (number != null) return _JsonToken.index(number);
    return _JsonToken.child(text);
  }

  static List<String> _splitCommaTopLevel(String input) {
    final parts = <String>[];
    var depth = 0;
    var inQuote = false;
    var quote = '';
    var start = 0;
    for (var i = 0; i < input.length; i++) {
      final ch = input[i];
      if (inQuote) {
        if (ch == quote) inQuote = false;
        continue;
      }
      if (ch == "'" || ch == '"') {
        inQuote = true;
        quote = ch;
      } else if (ch == '[' || ch == '(') {
        depth++;
      } else if (ch == ']' || ch == ')') {
        depth--;
      } else if (ch == ',' && depth == 0) {
        parts.add(input.substring(start, i));
        start = i + 1;
      }
    }
    parts.add(input.substring(start));
    return parts;
  }

  List<Object?> _applyToken(List<Object?> values, _JsonToken token) {
    switch (token.kind) {
      case _JsonTokenKind.child:
        return [
          for (final value in values)
            if (value is Map && value.containsKey(token.text))
              value[token.text],
        ];
      case _JsonTokenKind.wildcard:
        return [
          for (final value in values)
            if (value is List) ...value else if (value is Map) ...value.values,
        ];
      case _JsonTokenKind.positional:
        return [
          for (final value in values)
            if (value is List)
              _index(value, token.number!)
            else if (value is Map && value.containsKey(token.text))
              value[token.text],
        ];
      case _JsonTokenKind.multi:
        final result = <Object?>[];
        for (final part in token.parts!) {
          final quoted = RegExp("^(['\"])(.*?)\\1\$").firstMatch(part);
          final child = quoted?.group(2) ?? part;
          final number = int.tryParse(child);
          for (final value in values) {
            if (value is List && number != null) {
              final item = _index(value, number);
              if (item != null) result.add(item);
            } else if (value is Map && value.containsKey(child)) {
              result.add(value[child]);
            }
          }
        }
        return result;
      case _JsonTokenKind.slice:
        return [
          for (final value in values)
            if (value is List) ..._slice(value, token.text!),
        ];
      case _JsonTokenKind.recursiveWildcard:
        return [for (final value in values) ..._collectAll(value)];
      case _JsonTokenKind.filter:
        return [
          for (final value in values)
            if (value is List)
              for (final item in value)
                if (_filterMatches(item, token.text!)) item,
        ];
      case _JsonTokenKind.recursive:
        // `$..name`：递归找所有同名键。
        if (token.text != null && token.text!.isNotEmpty) {
          return [
            for (final value in values) ..._collectByKey(value, token.text!),
          ];
        }
        return [for (final value in values) ..._collectAll(value)];
    }
  }

  static Object? _index(List list, int raw) {
    final index = raw < 0 ? list.length + raw : raw;
    if (index < 0 || index >= list.length) return null;
    return list[index];
  }

  static List<Object?> _slice(List list, String expression) {
    final segments = expression.split(':');
    final length = list.length;
    int parseSegment(String text, {required bool isEnd}) {
      if (text.trim().isEmpty) return isEnd ? length : 0;
      final value = int.parse(text.trim());
      return value < 0 ? length + value : value;
    }

    final start = parseSegment(segments[0], isEnd: false);
    var end = parseSegment(segments.length > 1 ? segments[1] : '', isEnd: true);
    final step = segments.length > 2 && segments[2].trim().isNotEmpty
        ? int.parse(segments[2].trim())
        : 1;
    if (step == 0) return const [];
    final result = <Object?>[];
    if (step > 0) {
      if (start > end) return const [];
      for (var i = start; i < end && i < length; i += step) {
        result.add(list[i]);
      }
    } else {
      if (end >= length) end = length - 1;
      for (var i = start.clamp(0, length - 1); i > end; i += step) {
        if (i >= 0 && i < length) result.add(list[i]);
      }
    }
    return result;
  }

  static List<Object?> _collectAll(Object? value) {
    final result = <Object?>[];
    void visit(Object? node) {
      if (node is List) {
        result.addAll(node);
        for (final item in node) {
          visit(item);
        }
      } else if (node is Map) {
        result.addAll(node.values);
        for (final child in node.values) {
          visit(child);
        }
      }
    }

    visit(value);
    return result;
  }

  static List<Object?> _collectByKey(Object? value, String key) {
    final result = <Object?>[];
    void visit(Object? node) {
      if (node is List) {
        for (final item in node) {
          visit(item);
        }
      } else if (node is Map) {
        if (node.containsKey(key)) result.add(node[key]);
        for (final child in node.values) {
          visit(child);
        }
      }
    }

    visit(value);
    return result;
  }

  /// 过滤表达式求值：`(@.field=='v')`、`(@.n<10)`、`(@.a!=null)`。
  static bool _filterMatches(Object? item, String expression) {
    var text = expression.trim();
    if (text.startsWith('(') && text.endsWith(')')) {
      text = text.substring(1, text.length - 1).trim();
    }
    final match = RegExp(
      r"""@\.?([\w$\-]+)\s*(==|!=|<=|>=|<|>)\s*(.+)$""",
    ).firstMatch(text);
    if (match == null) return true;
    final field = match.group(1)!;
    final operator = match.group(2)!;
    final literalRaw = match.group(3)!.trim();

    Object? actual;
    if (item is Map && item.containsKey(field)) {
      actual = item[field];
    } else if (item is List && field == 'length') {
      actual = item.length;
    } else {
      actual = null;
    }

    final literal = _parseLiteral(literalRaw);
    switch (operator) {
      case '==':
        return _equals(actual, literal);
      case '!=':
        return !_equals(actual, literal);
      case '<':
        return _compare(actual, literal) < 0;
      case '<=':
        return _compare(actual, literal) <= 0;
      case '>':
        return _compare(actual, literal) > 0;
      case '>=':
        return _compare(actual, literal) >= 0;
    }
    return false;
  }

  static Object? _parseLiteral(String raw) {
    if (raw == 'null') return null;
    if (raw == 'true') return true;
    if (raw == 'false') return false;
    final quoted = RegExp("^(['\"])(.*)\\1\$").firstMatch(raw);
    if (quoted != null) return quoted.group(2);
    final number = num.tryParse(raw);
    if (number != null) return number;
    return raw;
  }

  static bool _equals(Object? a, Object? b) => '$a' == '$b';

  static int _compare(Object? a, Object? b) {
    final aNum = a is num ? a : num.tryParse('$a');
    final bNum = b is num ? b : num.tryParse('$b');
    if (aNum != null && bNum != null) return aNum.compareTo(bNum);
    return '$a'.compareTo('$b');
  }
}

enum _JsonTokenKind {
  child,
  wildcard,
  positional,
  multi,
  slice,
  filter,
  recursive,
  recursiveWildcard,
}

class _JsonToken {
  const _JsonToken.child(this.text)
    : kind = _JsonTokenKind.child,
      number = null,
      parts = null;

  const _JsonToken.index(this.number)
    : kind = _JsonTokenKind.positional,
      text = null,
      parts = null;

  const _JsonToken.wildcard()
    : kind = _JsonTokenKind.wildcard,
      text = null,
      number = null,
      parts = null;

  const _JsonToken.multi(this.parts)
    : kind = _JsonTokenKind.multi,
      text = null,
      number = null;

  const _JsonToken.slice(this.text)
    : kind = _JsonTokenKind.slice,
      number = null,
      parts = null;

  const _JsonToken.filter(this.text)
    : kind = _JsonTokenKind.filter,
      number = null,
      parts = null;

  const _JsonToken.recursive({this.text})
    : kind = _JsonTokenKind.recursive,
      number = null,
      parts = null;

  final _JsonTokenKind kind;
  final String? text;
  final int? number;
  final List<String>? parts;
}
