// 简化的JSON解析（用dart:convert实现）
import 'dart:convert' as convert;

class JsonSelector {
  final Object? root;

  JsonSelector(this.root);

  /// 简易JSONPath: $.field.subfield[0]
  JsonSelector? select(String path) {
    if (path.isEmpty || path == '$') return this;
    var p = path.startsWith(r'$.') ? path.substring(2) : path;
    if (p.isEmpty) return this;
    return _selectPath(p);
  }

  JsonSelector? _selectPath(String path) {
    final segments = _parsePath(path);
    dynamic cur = root;
    for (final seg in segments) {
      if (cur == null) return null;
      if (seg.isIndex) {
        if (cur is List && seg.index! < cur.length) {
          cur = cur[seg.index];
        } else {
          return null;
        }
      } else {
        if (cur is Map) {
          cur = cur[seg.name];
        } else {
          return null;
        }
      }
    }
    return cur == null ? null : JsonSelector(cur);
  }

  String? get string {
    if (root == null) return null;
    if (root is String) return root as String;
    if (root is num || root is bool) return root.toString();
    return null;
  }

  List<dynamic> toList() {
    if (root is List) return root as List;
    return [];
  }

  List<JsonSelector> selectList(String path) {
    final sel = select(path);
    if (sel == null) return [];
    return sel.toList().map((e) => JsonSelector(e)).toList();
  }

  static List<_Segment> _parsePath(String path) {
    final result = <_Segment>[];
    final buf = StringBuffer();
    var i = 0;
    while (i < path.length) {
      final c = path[i];
      if (c == '.') {
        if (buf.isNotEmpty) {
          result.add(_Segment.name(buf.toString()));
          buf.clear();
        }
      } else if (c == '[') {
        if (buf.isNotEmpty) {
          result.add(_Segment.name(buf.toString()));
          buf.clear();
        }
        final end = path.indexOf(']', i);
        if (end < 0) break;
        final idx = int.tryParse(path.substring(i + 1, end));
        if (idx != null) result.add(_Segment.index(idx));
        i = end;
      } else {
        buf.write(c);
      }
      i++;
    }
    if (buf.isNotEmpty) result.add(_Segment.name(buf.toString()));
    return result;
  }

  /// 解析JSON字符串
  static Object? decode(String s) {
    try {
      return convert.jsonDecode(s);
    } catch (_) {
      return null;
    }
  }
}

class _Segment {
  final String? name;
  final int? index;
  _Segment.name(this.name) : index = null;
  _Segment.index(this.index) : name = null;
  bool get isIndex => index != null;
}
