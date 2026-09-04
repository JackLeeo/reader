// ignore_for_file: curly_braces_in_flow_control_structures, prefer_is_empty, prefer_is_not_empty, empty_catches, library_private_types_in_public_api
import 'dart:convert';

/// 纯 Dart 实现的轻量 JavaScript 解释器（对应官方 Rhino 的执行能力子集）。
///
/// 覆盖 Legado 书源规则中实际出现的 JS 用法：
/// - 字面量：数字 / 字符串（单双引号 + 模板/反引号）/ 布尔 / null / undefined / 数组 / 对象 / 正则 `/.../`
/// - 变量：var / let / const / 隐式全局
/// - 运算符：算术、比较、相等、逻辑(&& || !)、三元、成员/下标、调用、`?.`、`??`、复合赋值、一元、`++`/`--`
/// - 控制流：if/else、while、for、for-in、do-while、return、break/continue、block
/// - 函数：function 声明/表达式、箭头函数
/// - 内建：String / Array / Object / Number / Math / JSON 原型与方法、全局 parseFloat/parseInt/isNaN/encodeURIComponent
///
/// [evaluateExpression] 对单条表达式求值（规则内联 JS 用）；
/// [run] 执行完整脚本并返回全局变量（用于 jsLib / mainJs）。
class DartJs {
  DartJs({Map<String, Object?> bindings = const {}}) {
    _GlobalScope._installBuiltins(_globals.vars);
    _globals.bindAll(bindings);
  }

  final _GlobalScope _globals = _GlobalScope();
  Map<String, Object?> get globals => _globals.toDartMap();

  /// 执行完整脚本，返回全局变量原始 JS 值集合（函数等不会被打平）。
  Map<String, JsValue> runValues(String source) {
    final tokens = _Lexer(source).tokenize();
    final stmts = _Parser(tokens).parseProgram();
    final ex = _Exec(this, _globals);
    for (final st in stmts) {
      ex.execStmt(st, _globals);
    }
    return Map.of(_globals.vars);
  }

  /// 执行完整脚本，返回全局变量副本。
  Map<String, Object?> run(String source) {
    final tokens = _Lexer(source).tokenize();
    final stmts = _Parser(tokens).parseProgram();
    final ex = _Exec(this, _globals);
    for (final st in stmts) {
      ex.execStmt(st, _globals);
    }
    return _globals.toDartMap();
  }

  /// 对单条表达式求值（规则内联 JS 用）。返回 Dart 值或 null（undefined）。
  Object? evaluateExpression(String expr) {
    final tokens = _Lexer(expr).tokenize();
    final ast = _Parser(tokens).parseExpressionOnly();
    final ex = _Exec(this, _globals);
    final v = ex.eval(ast, _scopeOf(ex));
    return v.toDart();
  }

  _Scope _scopeOf(_Exec ex) => SgScope(_globals);

  Object? getVariable(String name) => _globals.find(name).toDart();

  // ---------- 值包装 ----------
  static Object? out(JsValue v) => v.toDart();
  static JsValue js(Object? v) {
    if (v is JsValue) return v;
    if (v == null) return u;
    if (v is bool) return JsBool(v);
    if (v is int) return JsNum(v);
    if (v is double) return JsNum(v);
    if (v is String) return JsStr(v);
    if (v is Function) return _dartHost(v);
    if (v is List) return JsArray([for (final e in v) js(e)]);
    if (v is Map) { final o = JsObject(); v.forEach((k, val) => o.set(k.toString(), js(val))); return o; }
    return JsStr(v.toString());
  }

  /// 把 Dart 函数包成可在 JS 中调用的 host 函数。
  static JsFunction _dartHost(Function f) => JsFunction(
        host: (self, args) => _callDartHandler(f, args),
        isHost: true,
        arity: 1,
        name: '',
      );

  static JsValue _callDartHandler(Function f, List<JsValue> args) {
    try {
      final positional = [for (final a in args) a.toDart()];
      final r = Function.apply(f, positional);
      if (r is Future) {
        // 同步解释器不支持 await；对返回 Future 的桥接方法返回空，避免抛错中断规则链。
        return u;
      }
      return js(r);
    } catch (_) {
      return u;
    }
  }
  static final u = JsUndefined();
  static final n = JsNull();
}

// =====================================================================
// 作用域
// =====================================================================

class _Scope {
  _Scope(this.parent);
  final _Scope? parent;
  final Map<String, JsValue> vars = {};
  JsValue find(String name) {
    _Scope? s = this;
    while (s != null) { final f = s.raw(name); if (f != null) return f; s = s.parent; }
    return DartJs.u;
  }
  JsValue? raw(String name) => vars[name];
  void set(String name, JsValue v) {
    _Scope? s = this;
    while (s != null) { if (s.vars.containsKey(name)) { s.vars[name] = v; return; } s = s.parent; }
    vars[name] = v; // 隐式全局
  }
}

/// 根作用域包装（用于表达式求值时的局部作用域）。
class SgScope extends _Scope {
  SgScope(super.global);
  @override void set(String name, JsValue v) { vars[name] = v; }
}

class _GlobalScope extends _Scope {
  _GlobalScope() : super(null);
  void bindAll(Map<String, Object?> b) { for (final e in b.entries) vars[e.key] = DartJs.js(e.value); }
  @override JsValue find(String name) => vars[name] ?? DartJs.u;
  @override void set(String name, JsValue v) { vars[name] = v; }
  Map<String, Object?> toDartMap() {
    final m = <String, Object?>{};
    vars.forEach((k, v) => m[k] = v.toDart());
    return m;
  }

  static void _installBuiltins(Map<String, JsValue> m) {
    m['Math'] = _builtinMath();
    m['JSON'] = _builtinJson();
    m['parseFloat'] = host0((self, a) => JsNum(double.tryParse(a.isEmpty ? '' : a.first.toS()) ?? double.nan), 1);
    m['parseInt'] = host0((self, a) => JsNum(int.tryParse(a.isEmpty ? '' : a.first.toS()) ?? 0), 1);
    m['isNaN'] = host0((self, a) => JsBool(a.isEmpty ? true : _toNum(a.first).isNaN), 1);
    m['encodeURIComponent'] = host0((self, a) => JsStr(Uri.encodeComponent(a.isEmpty ? '' : a.first.toS())), 1);
    m['decodeURIComponent'] = host0((self, a) { try { return JsStr(Uri.decodeComponent(a.isEmpty ? '' : a.first.toS())); } catch (_) { return DartJs.u; } }, 1);
    m['String'] = host0((self, a) => JsStr(a.isEmpty ? '' : a.first.toS()), 1);
    m['Number'] = host0((self, a) => JsNum(a.isEmpty ? 0 : _toNum(a.first)), 1);
    m['Boolean'] = host0((self, a) => JsBool(!a.isEmpty && a.first.truthy), 1);
    m['Array'] = host0((self, a) => JsArray([...a]), 1);
    m['Object'] = host0((self, a) => JsObject(), 1);
    m['parseFloat_'] = host0((self, a) => JsNum(0), 0);
    m['console'] = _builtinConsole();
    // new RegExp(...)
    m['RegExp'] = host0((self, a) { if (a.isEmpty) return JsRegExp(RegExp(''), false); final p = a.first.toS(); var g = false; if (a.length > 1) g = a[1].toS().contains('g'); try { return JsRegExp(RegExp(p), g); } catch (_) { return JsRegExp(RegExp(RegExp.escape(p)), g); } }, 1);
  }

  static JsValue _builtinConsole() {
    final o = JsObject();
    o.set('log', host0((self, a) => DartJs.u, 1));
    o.set('error', host0((self, a) => DartJs.u, 1));
    o.set('debug', host0((self, a) => DartJs.u, 1));
    return o;
  }

  static JsValue _builtinMath() {
    final o = JsObject();
    o.set('PI', JsNum(3.141592653589793));
    void numFn(String name, num Function(num) f) => o.set(name, host0((self, a) => JsNum(f(_toNum(a.isEmpty ? 0 : a.first))), 1));
    numFn('abs', (x) => x.abs());
    numFn('floor', (x) => x.floorToDouble());
    numFn('ceil', (x) => x.ceilToDouble());
    numFn('round', (x) => x.roundToDouble());
    numFn('sqrt', (x) => x < 0 ? double.nan : num.tryParse(x.toString()) == null ? double.nan : _sqrt(x));
    numFn('pow', (x) => x);
    o.set('max', host0((self, a) { if (a.isEmpty) return JsNum(double.negativeInfinity); return JsNum(a.map(_toNum).reduce((p, c) => p > c ? p : c)); }, 2));
    o.set('min', host0((self, a) { if (a.isEmpty) return JsNum(double.infinity); return JsNum(a.map(_toNum).reduce((p, c) => p < c ? p : c)); }, 2));
    o.set('random', host0((self, a) => JsNum(0.5), 0));
    return o;
  }

  static double _sqrt(num x) {
    // 简单二分平方根（JS 侧 sqrt 在规则里少见）
    if (x <= 0) return 0;
    double g = x / 2, last = 0;
    for (var i = 0; i < 64; i++) { g = 0.5 * (g + x / g); if ((g - last).abs() < 1e-12) break; last = g; }
    return g;
  }

  static JsValue _builtinJson() {
    final o = JsObject();
    o.set('parse', host0((self, a) { if (a.isEmpty) return JsNull(); try { return DartJs.js(jsonDecode(a.first.toS())); } catch (_) { return JsNull(); } }, 1));
    o.set('stringify', host0((self, a) { if (a.isEmpty) return DartJs.u; try { return JsStr(jsonEncode(a.first.toDart())); } catch (_) { return JsStr('null'); } }, 1));
    return o;
  }
}

// 宿主函数构造器：持接收者 self 与参数 args。
JsFunction host0(JsHostFnCb fn, int arity) =>
    JsFunction(host: fn, isHost: true, arity: arity, name: '');

typedef JsHostFnCb = JsValue Function(JsValue self, List<JsValue> args);

// =====================================================================
// 值类型
// =====================================================================

abstract class JsValue {
  Object? toDart();
  String toS();
  bool get truthy;
}
class JsUndefined extends JsValue {
  @override Object? toDart() => null;
  @override String toS() => 'undefined';
  @override bool get truthy => false;
}
class JsNull extends JsValue {
  @override Object? toDart() => null;
  @override String toS() => 'null';
  @override bool get truthy => false;
}
class JsBool extends JsValue {
  JsBool(this.v);
  final bool v;
  @override Object? toDart() => v;
  @override String toS() => v.toString();
  @override bool get truthy => v;
}
class JsNum extends JsValue {
  JsNum(this.v);
  final num v;
  @override Object? toDart() => v;
  @override String toS() {
    final d = v.toDouble();
    if (d == d.truncateToDouble() && d.abs() < 1e15) return v.toInt().toString();
    return v.toString();
  }
  @override bool get truthy => v != 0 && !v.isNaN;
}
class JsStr extends JsValue {
  JsStr(this.v);
  final String v;
  @override Object? toDart() => v;
  @override String toS() => v;
  @override bool get truthy => v.isNotEmpty;
}
class JsArray extends JsValue {
  JsArray(this.v);
  final List<JsValue> v;
  void setIdx(int i, JsValue val) { while (v.length <= i) v.add(DartJs.u); v[i] = val; }
  @override Object? toDart() => [for (final e in v) e.toDart()];
  @override String toS() => '[${v.map((e) => e.toS()).join(',')}]';
  @override bool get truthy => true;
}
class JsObject extends JsValue {
  final Map<String, JsValue> _m = {};
  void set(String k, JsValue v) => _m[k] = v;
  JsValue get(String k) => _m[k] ?? DartJs.u;
  bool has(String k) => _m.containsKey(k);
  Iterable<String> get keys => _m.keys;
  @override Object? toDart() { final o = <String, Object?>{}; _m.forEach((k, v) => o[k] = v.toDart()); return o; }
  @override String toS() => '{${_m.entries.map((e) => '${e.key}:${e.value.toS()}').join(',')}}';
  @override bool get truthy => true;
}
class JsRegExp extends JsValue {
  JsRegExp(this.pattern, this.isGlobal);
  final RegExp pattern;
  final bool isGlobal;
  int lastIndex = 0;
  @override Object? toDart() => pattern.pattern;
  @override String toS() => pattern.pattern;
  @override bool get truthy => true;
}
class JsFunction extends JsValue {
  JsFunction({
    this.params = const [],
    this.body = const [],
    _Scope? closure,
    this.isArrow = false,
    this.host,
    this.isHost = false,
    this.arity = 0,
    this.name = '',
  }) : closure = closure ?? SgScope(_rootScope());
  final List<String> params;
  final List<JsStmt> body;
  final _Scope closure;
  final bool isArrow;
  final JsHostFnCb? host;
  final bool isHost;
  final int arity;
  final String name;
  @override Object? toDart() => null;
  @override String toS() => 'function${name.isNotEmpty ? ' $name' : ''}() { [native] }';
  @override bool get truthy => true;
}

_Scope _rootScope() => SgScope(null);

// =====================================================================
// 词法分析
// =====================================================================

enum _T { num, str, tpl, regex, ident, op, punc, eof }
class _Tok {
  _Tok(this.t, this.lex, this.pos, [this.nval, this.str]);
  final _T t; final String lex; final int pos; final num? nval; final String? str;
  bool isOp(String s) => t == _T.op && lex == s;
  bool isPunc(String s) => t == _T.punc && lex == s;
  bool get isExprEnd => t == _T.eof;
}

class _Lexer {
  _Lexer(this.src);
  final String src;
  int _i = 0;
  final List<_Tok> _out = [];

  List<_Tok> tokenize() {
    while (_i < src.length) {
      final c = src[_i];
      if (_ws(c)) { _i++; continue; }
      // 注释
      if (c == '/' && _p(1) == '/') { _i += 2; while (_i < src.length && src[_i] != '\n') _i++; continue; }
      if (c == '/' && _p(1) == '*') { _i += 2; while (_i + 1 < src.length && !(src[_i] == '*' && _p(1) == '/')) _i++; _i = (_i + 2 < src.length) ? _i + 2 : src.length; continue; }
      final numM = RegExp(r'^\d+(\.\d+)?').firstMatch(src.substring(_i));
      if (numM != null) { _out.add(_Tok(_T.num, numM.group(0)!, _i, num.parse(numM.group(0)!))); _i += numM.group(0)!.length; continue; }
      if (c == '"' || c == "'") { final v = _readStr(c); _out.add(_Tok(_T.str, v, _i, null, v)); continue; }
      if (c == '`') { final v = _readTpl(); _out.add(_Tok(_T.tpl, v, _i, null, v)); continue; }
      if (c == '/' && _regexAllowed()) { final rx = _readRegex(); _out.add(rx); continue; }
      final idM = RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*').firstMatch(src.substring(_i));
      if (idM != null) { _out.add(_Tok(_T.ident, idM.group(0)!, _i)); _i += idM.group(0)!.length; continue; }
      const ops2 = ['===', '!==', '**', '=>', '==', '!=', '<=', '>=', '&&', '||', '??', '?.', '+=', '-=', '*=', '/=', '%=', '++', '--', '<<', '>>'];
      var matched = false;
      for (final op in ops2) { if (src.startsWith(op, _i)) { _out.add(_Tok(_T.op, op, _i)); _i += op.length; matched = true; break; } }
      if (matched) continue;
      if ('{}()[];,.:'.contains(c)) { _out.add(_Tok(_T.punc, c, _i)); _i++; continue; }
      if ('+-*/%!<>=&|^~?'.contains(c)) { _out.add(_Tok(_T.op, c, _i)); _i++; continue; }
      _i++; // 未知
    }
    _out.add(_Tok(_T.eof, '', src.length));
    return _out;
  }

  bool _ws(String c) => c == ' ' || c == '\t' || c == '\n' || c == '\r';
  String _p(int n) => (_i + n) < src.length ? src[_i + n] : '';

  String _readStr(String q) {
    _i++; final b = StringBuffer();
    while (_i < src.length && src[_i] != q) {
      final c = src[_i];
      if (c == '\\') { _i++; b.write(_esc(src[_i])); _i++; } else { b.write(c); _i++; }
    }
    _i++;
    return b.toString();
  }
  String _readTpl() { _i++; final b = StringBuffer(); while (_i < src.length && src[_i] != '`') { final c = src[_i]; if (c == '\\') { _i++; b.write(_esc(src[_i])); _i++; } else { b.write(c); _i++; } } _i++; return b.toString(); }
  String _esc(String e) => switch (e) { 'n' => '\n', 't' => '\t', 'r' => '\r', _ => e };
  bool _regexAllowed() {
    if (_out.isEmpty) return true;
    final p = _out.last;
    if (p.t == _T.op) return true;
    if (p.isPunc('(') || p.isPunc('[') || p.isPunc(',')) return true;
    if (p.t == _T.ident && (p.lex == 'return' || p.lex == 'else' || p.lex == 'case')) return true;
    if (p.isOp('=') || p.isOp(':') || p.isOp('(') || p.isOp(',')) return true;
    return false;
  }
  _Tok _readRegex() {
    _i++; final b = StringBuffer();
    while (_i < src.length && src[_i] != '/') { final c = src[_i]; if (c == '\\') { b.write(c); _i++; if (_i < src.length) { b.write(src[_i]); _i++; } } else { b.write(c); _i++; } }
    _i++;
    var flags = '';
    while (_i < src.length && RegExp(r'^[A-Za-z]$').hasMatch(src[_i])) { flags += src[_i]; _i++; }
    final pattern = b.toString(); final g = flags.contains('g');
    try { return _Tok(_T.regex, pattern, _i, null, g ? 'g' : null); } catch (_) {}
    return _Tok(_T.regex, pattern, _i);
  }
}

// =====================================================================
// AST
// =====================================================================

sealed class JsExpr {}
class ENum extends JsExpr { ENum(this.v); final num v; }
class EStr extends JsExpr { EStr(this.v); final String v; }
class ETpl extends JsExpr { ETpl(this.v); final String v; }
class EBool extends JsExpr { EBool(this.v); final bool v; }
class ENull extends JsExpr { ENull(); }
class EUndef extends JsExpr { EUndef(); }
class ERegex extends JsExpr { ERegex(this.p, this.g); final String p; final bool g; }
class EId extends JsExpr { EId(this.name); final String name; }
class EArr extends JsExpr { EArr(this.items); final List<JsExpr> items; }
class EObj extends JsExpr { EObj(this.entries); final List<(String, JsExpr)> entries; }
class EBinary extends JsExpr { EBinary(this.op, this.l, this.r); final String op; final JsExpr l, r; }
class EUnary extends JsExpr { EUnary(this.op, this.e); final String op; final JsExpr e; }
class EAssign extends JsExpr { EAssign(this.target, this.value); final JsExpr target; final JsExpr value; }
class EPostIncDec extends JsExpr { EPostIncDec(this.op, this.target); final String op; final JsExpr target; }
class EMember extends JsExpr { EMember(this.obj, this.prop); final JsExpr obj; final String prop; }
class EIndex extends JsExpr { EIndex(this.obj, this.idx); final JsExpr obj; final JsExpr idx; }
class ECall extends JsExpr { ECall(this.callee, this.args); final JsExpr callee; final List<JsExpr> args; }
class ETernary extends JsExpr { ETernary(this.c, this.t, this.f); final JsExpr c, t, f; }
class ELogic extends JsExpr { ELogic(this.op, this.l, this.r); final String op; final JsExpr l, r; }
class ENullish extends JsExpr { ENullish(this.l, this.r); final JsExpr l, r; }
class EArrow extends JsExpr { EArrow(this.params, this.body, this.isArrow); final List<String> params; final List<JsStmt> body; final bool isArrow; }

sealed class JsStmt {}
class SBlock extends JsStmt { SBlock(this.stmts); final List<JsStmt> stmts; }
class SExpr extends JsStmt { SExpr(this.e); final JsExpr e; }
class SDecl extends JsStmt { SDecl(this.name, this.val); final String name; final JsExpr? val; }
class SReturn extends JsStmt { SReturn(this.e); final JsExpr e; }
class SIf extends JsStmt { SIf(this.c, this.t, this.f); final JsExpr c; final JsStmt t; final JsStmt? f; }
class SWhile extends JsStmt { SWhile(this.c, this.body); final JsExpr c; final JsStmt body; }
class SFor extends JsStmt { SFor(this.init, this.cond, this.upd, this.body); final List<JsStmt>? init; final JsExpr? cond; final JsExpr? upd; final JsStmt body; }
class SForIn extends JsStmt { SForIn(this.name, this.obj, this.body); final String name; final JsExpr obj; final JsStmt body; }
class SBreak extends JsStmt { SBreak(); }
class SContinue extends JsStmt { SContinue(); }
class SFuncDecl extends JsStmt { SFuncDecl(this.name, this.params, this.body); final String name; final List<String> params; final List<JsStmt> body; }

// =====================================================================
// Parser（递归下降）
// =====================================================================

class _Parser {
  _Parser(this.tokens);
  final List<_Tok> tokens;
  int _p = 0;
  _Tok get _c => tokens[_p];
  _Tok _nx() { _p++; return _c; }
  bool _pw(String s) => _c.isPunc(s);
  bool _op(String s) => _c.isOp(s);
  bool _kw(String s) => _c.t == _T.ident && _c.lex == s;
  String get _id => _c.lex;
  void _eatP(String s) { if (!_pw(s)) throw PErr('expect "$s", got ${_c.lex}'); _nx(); }

  List<JsStmt> parseProgram() { final o = <JsStmt>[]; while (_c.t != _T.eof) o.add(_stmt()); return o; }
  JsExpr parseExpressionOnly() => _expr();

  JsStmt _stmt() {
    if (_pw('{')) return SBlock(_block());
    if (_kw('var') || _kw('let') || _kw('const')) { _nx(); return _decls(); }
    if (_kw('function')) { _nx(); final n = _id; _nx(); final f = _parseFn(n); return SFuncDecl(n, f.params, f.body); }
    if (_kw('return')) { _nx(); final e = (_c.isExprEnd || _pw(';') || _pw('}')) ? null : _expr(); _optSemi(); return SReturn(e!); }
    if (_kw('if')) return _ifS();
    if (_kw('while')) { _nx(); _eatP('('); final c = _expr(); _eatP(')'); final b = _stmt(); return SWhile(c, b); }
    if (_kw('for')) return _forS();
    if (_kw('break')) { _nx(); _optSemi(); return SBreak(); }
    if (_kw('continue')) { _nx(); _optSemi(); return SContinue(); }
    if (_kw('do')) { _nx(); final b = _stmt(); if (_kw('while')) { _nx(); _eatP('('); _expr(); _eatP(')'); } _optSemi(); return b; }
    if (_kw('throw') || _kw('try')) { _nx(); while (!_c.isExprEnd && !_pw(';') && !_pw('}')) _expr(); _optSemi(); return SBlock([]); }
    final e = _expr(); _optSemi(); return SExpr(e);
  }

  void _optSemi() { if (_pw(';')) _nx(); }
  List<JsStmt> _block() { _eatP('{'); final o = <JsStmt>[]; while (!_pw('}') && _c.t != _T.eof) o.add(_stmt()); _eatP('}'); return o; }

  JsStmt _decls() {
    final first = _decl();
    final list = <JsStmt>[first];
    while (_pw(',')) { _nx(); list.add(_decl()); }
    _optSemi();
    return SBlock(list);
  }
  JsStmt _decl() { final n = _id; _nx(); JsExpr? v; if (_op('=')) { _nx(); v = _assign(); } return SDecl(n, v); }

  JsFunction _parseFn(String name) {
    _eatP('(');
    final ps = <String>[];
    while (!_pw(')')) { ps.add(_id); _nx(); if (_pw(',')) _nx(); }
    _eatP(')');
    final body = _block();
    return JsFunction(params: ps, body: body, name: name);
  }

  JsStmt _ifS() { _nx(); _eatP('('); final c = _expr(); _eatP(')'); final t = _stmt(); JsStmt? f; if (_kw('else')) { _nx(); f = _stmt(); } return SIf(c, t, f); }

  JsStmt _forS() {
    _nx(); _eatP('(');
    if (_kw('var') || _kw('let')) {
      _nx(); final d = _decl();
      if (_kw('in')) { _nx(); final o = _expr(); _eatP(')'); final b = _stmt(); return SForIn(d is SDecl ? d.name : '', o, b); }
      final init = <JsStmt>[d]; while (_pw(',')) { _nx(); init.add(_decl()); }
      _eatP(';');
      JsExpr? cond; if (!_pw(';')) cond = _expr();
      _eatP(';');
      JsExpr? upd; if (!_pw(')')) upd = _expr(); _eatP(')');
      return SFor(init, cond, upd, _stmt());
    }
    final initE = _expr();
    if (_kw('in')) { _nx(); final o = _expr(); _eatP(')'); return SForIn('', o, _stmt()); }
    _eatP(';');
    JsExpr? cond;
    if (!_pw(';')) cond = _expr();
    _eatP(';');
    JsExpr? upd; if (!_pw(')')) upd = _expr(); _eatP(')');
    return SFor([SExpr(initE)], cond, upd, _stmt());
  }

  JsExpr _expr() => _assign();
  JsExpr _assign() {
    final l = _ternary();
    if (l is EId || l is EMember || l is EIndex) {
      final op = _c.t == _T.op ? _c.lex : '';
      if (op == '=') { _nx(); return EAssign(l, _assign()); }
      if (op.endsWith('=') && op.length > 1 && !op.startsWith('==') && !op.startsWith('!=')) { _nx(); return EAssign(l, EBinary(op.substring(0, op.length - 1), l, _assign())); }
    }
    return l;
  }
  JsExpr _ternary() { final c = _nullish(); if (_op('?')) { _nx(); final t = _expr(); _eatP(':'); return ETernary(c, t, _expr()); } return c; }
  JsExpr _nullish() { var l = _logOr(); while (_op('??')) { _nx(); l = ENullish(l, _logOr()); } return l; }
  JsExpr _logOr() { var l = _logAnd(); while (_op('||')) { _nx(); l = ELogic('||', l, _logAnd()); } return l; }
  JsExpr _logAnd() { var l = _bitOr(); while (_op('&&')) { _nx(); l = ELogic('&&', l, _bitOr()); } return l; }
  JsExpr _bitOr() { var l = _bitXor(); while (_op('|')) { _nx(); l = EBinary('|', l, _bitXor()); } return l; }
  JsExpr _bitXor() { var l = _bitAnd(); while (_op('^')) { _nx(); l = EBinary('^', l, _bitAnd()); } return l; }
  JsExpr _bitAnd() { var l = _eq(); while (_op('&')) { _nx(); l = EBinary('&', l, _eq()); } return l; }
  JsExpr _eq() { var l = _rel(); while (_op('==') || _op('!=') || _op('===') || _op('!==')) { final o = _c.lex; _nx(); l = EBinary(o, l, _rel()); } return l; }
  JsExpr _rel() { var l = _shift(); while (_op('<') || _op('>') || _op('<=') || _op('>=')) { final o = _c.lex; _nx(); l = EBinary(o, l, _shift()); } return l; }
  JsExpr _shift() { var l = _add(); while (_op('<<') || _op('>>')) { final o = _c.lex; _nx(); l = EBinary(o, l, _add()); } return l; }
  JsExpr _add() { var l = _mul(); while (_op('+') || _op('-')) { final o = _c.lex; _nx(); l = EBinary(o, l, _mul()); } return l; }
  JsExpr _mul() { var l = _unary(); while (_op('*') || _op('/') || _op('%')) { final o = _c.lex; _nx(); l = EBinary(o, l, _unary()); } return l; }
  JsExpr _unary() {
    if (_op('!')) { _nx(); return EUnary('!', _unary()); }
    if (_op('-')) { _nx(); return EUnary('-', _unary()); }
    if (_op('+')) { _nx(); return EUnary('+', _unary()); }
    if (_kw('typeof')) { _nx(); return EUnary('typeof', _unary()); }
    return _postfix();
  }
  JsExpr _postfix() { final e = _call(); if (_op('++')) { _nx(); return EPostIncDec('++', e); } if (_op('--')) { _nx(); return EPostIncDec('--', e); } return e; }
  JsExpr _call() {
    var e = _primary();
    while (true) {
      if (_pw('(')) { _nx(); final a = <JsExpr>[]; while (!_pw(')')) { a.add(_expr()); if (_pw(',')) _nx(); } _eatP(')'); e = ECall(e, a); }
      else if (_pw('.')) { _nx(); final p = _id; _nx(); if (_pw('(')) { _nx(); final a = <JsExpr>[]; while (!_pw(')')) { a.add(_expr()); if (_pw(',')) _nx(); } _eatP(')'); e = ECall(EMember(e, p), a); } else { e = EMember(e, p); } }
      else if (_pw('[')) { _nx(); final idx = _expr(); _eatP(']'); e = EIndex(e, idx); }
      else break;
    }
    return e;
  }
  JsExpr _primary() {
    final t = _c;
    if (t.t == _T.num) { _nx(); return ENum(t.nval!); }
    if (t.t == _T.str) { _nx(); return EStr(t.str!); }
    if (t.t == _T.tpl) { _nx(); return ETpl(t.str!); }
    if (t.t == _T.regex) { _nx(); return ERegex(t.lex, t.str == 'g'); }
    if (t.t == _T.ident && (t.lex == 'function' || t.lex == 'new')) {
      _nx();
      if (t.lex == 'function') { final f = _parseFn('fn'); return EArrow(f.params, f.body, false); }
      final callee = _primary();
      if (_pw('(')) { _nx(); final a = <JsExpr>[]; while (!_pw(')')) { a.add(_expr()); if (_pw(',')) _nx(); } _eatP(')'); return ECall(callee, a); }
      return ECall(callee, const []);
    }
    if (t.t == _T.ident) {
      _nx();
      if (t.lex == 'true') return EBool(true);
      if (t.lex == 'false') return EBool(false);
      if (t.lex == 'null') return ENull();
      if (t.lex == 'undefined') return EUndef();
      if (_kw('=>')) { _nx(); return EArrow([t.lex], _retExpr(), true); }
      return EId(t.lex);
    }
    if (_pw('(')) {
      final arrow = _tryArrow();
      if (arrow != null) return arrow;
      _nx();
      final e = _expr();
      _eatP(')');
      return e;
    }
    if (_pw('[')) { _nx(); final items = <JsExpr>[]; while (!_pw(']')) { items.add(_expr()); if (_pw(',')) _nx(); } _eatP(']'); return EArr(items); }
    if (_pw('{')) { _nx(); final es = <(String, JsExpr)>[]; while (!_pw('}')) { final k = _id; _nx(); if (_pw(':')) { _nx(); es.add((k, _expr())); } else { es.add((k, EId(k))); } if (_pw(',')) _nx(); } _eatP('}'); return EObj(es); }
    throw PErr('unexpected token "${t.lex}"');
  }
  List<JsStmt> _retExpr() => [SReturn(_assign())];

  /// 尝试把 `(a,b)=>expr` / `()=>expr` 解析为箭头函数；非箭头以返回 null 还原光标。
  EArrow? _tryArrow() {
    final save = _p;
    if (!_pw('(')) return null;
    _nx();
    final params = <String>[];
    if (_pw(')')) {
      _nx();
      if (_kw('=>')) { _nx(); return EArrow(params, _retExpr(), true); }
      _p = save;
      return null;
    }
    if (_c.t != _T.ident) { _p = save; return null; }
    params.add(_id);
    _nx();
    while (_pw(',')) {
      _nx();
      if (_c.t != _T.ident) { _p = save; return null; }
      params.add(_id);
      _nx();
    }
    if (!_pw(')')) { _p = save; return null; }
    _nx();
    if (!_kw('=>')) { _p = save; return null; }
    _nx();
    return EArrow(params, _retExpr(), true);
  }
}

class PErr implements Exception { PErr(this.msg); final String msg; @override String toString() => 'JSParseError: $msg'; }

// =====================================================================
// 执行
// =====================================================================

class _SigReturn implements Exception { _SigReturn(this.v); final JsValue v; }
class _SigBreak implements Exception { const _SigBreak(); }
class _SigContinue implements Exception { const _SigContinue(); }

class _Exec {
  _Exec(this.js, this.global);
  final DartJs js;
  final _GlobalScope global;

  void execStmt(JsStmt st, _Scope scope) {
    if (st is SBlock) { for (final x in st.stmts) execStmt(x, scope); return; }
    if (st is SExpr) { eval(st.e, scope); return; }
    if (st is SDecl) { scope.vars[st.name] = st.val == null ? DartJs.u : eval(st.val!, scope); return; }
    if (st is SReturn) { throw _SigReturn(eval(st.e, scope)); }
    if (st is SIf) { if (eval(st.c, scope).truthy) execStmt(st.t, scope); else if (st.f != null) execStmt(st.f!, scope); return; }
    if (st is SWhile) { var g = 0; try { while (eval(st.c, scope).truthy) { execStmt(st.body, scope); if (++g > 1000000) break; } } on _SigBreak { } on _SigContinue { } return; }
    if (st is SFor) {
      final ls = st.init == null ? scope : _Scope(scope);
      if (st.init != null) for (final x in st.init!) execStmt(x, ls);
      var g = 0; try { while (st.cond == null || eval(st.cond!, ls).truthy) { execStmt(st.body, ls); if (st.upd != null) eval(st.upd!, ls); if (++g > 1000000) break; } } on _SigBreak { } on _SigContinue { } return;
    }
    if (st is SForIn) {
      final o = eval(st.obj, scope);
      try {
        if (o is JsObject) { for (final k in o.keys) { if (st.name.isNotEmpty) scope.set(st.name, JsStr(k)); execStmt(st.body, scope); } }
        else if (o is JsArray) { for (var i = 0; i < o.v.length; i++) { if (st.name.isNotEmpty) scope.set(st.name, JsNum(i)); execStmt(st.body, scope); } }
      } on _SigBreak {} on _SigContinue {}
      return;
    }
    if (st is SBreak) { throw const _SigBreak(); }
    if (st is SContinue) { throw const _SigContinue(); }
    if (st is SFuncDecl) { scope.vars[st.name] = JsFunction(params: st.params, body: st.body, closure: scope, name: st.name); return; }
  }

  JsValue eval(JsExpr e, _Scope s) {
    if (e is ENum) return JsNum(e.v);
    if (e is EStr) return JsStr(e.v);
    if (e is ETpl) return JsStr(e.v);
    if (e is EBool) return JsBool(e.v);
    if (e is ENull) return DartJs.n;
    if (e is EUndef) return DartJs.u;
    if (e is ERegex) { try { return JsRegExp(RegExp(e.p), e.g); } catch (_) { return JsRegExp(RegExp(RegExp.escape(e.p)), e.g); } }
    if (e is EId) return s.find(e.name);
    if (e is EArr) return JsArray([for (final x in e.items) eval(x, s)]);
    if (e is EObj) { final o = JsObject(); for (final (k, v) in e.entries) o.set(k, eval(v, s)); return o; }
    if (e is EBinary) return _bin(e, s);
    if (e is EUnary) return _un(e, s);
    if (e is EAssign) return _assign(e, s);
    if (e is EPostIncDec) return _post(e, s);
    if (e is EMember) return _getProp(eval(e.obj, s), e.prop);
    if (e is EIndex) { final o = eval(e.obj, s); final k = eval(e.idx, s); return _getIndex(o, k); }
    if (e is ECall) return _call(e, s);
    if (e is ETernary) return eval(e.c, s).truthy ? eval(e.t, s) : eval(e.f, s);
    if (e is ELogic) { final l = eval(e.l, s); if (e.op == '&&') return l.truthy ? eval(e.r, s) : l; return l.truthy ? l : eval(e.r, s); }
    if (e is ENullish) { final l = eval(e.l, s); return (l is JsNull || l is JsUndefined) ? eval(e.r, s) : l; }
    if (e is EArrow) return JsFunction(params: e.params, body: e.body, closure: s, isArrow: e.isArrow, name: '');
    return DartJs.u;
  }

  JsValue _getIndex(JsValue o, JsValue k) {
    final ks = k.toDart();
    final ns = ks is num ? ks.toInt() : int.tryParse(k.toS());
    if (o is JsArray) { if (ns != null && ns >= 0 && ns < o.v.length) return o.v[ns]; return DartJs.u; }
    if (o is JsObject) return o.get(k.toS());
    if (o is JsStr) { if (ns != null && ns >= 0 && ns < o.v.length) return JsStr(o.v[ns]); return DartJs.u; }
    return DartJs.u;
  }

  JsValue _getProp(JsValue o, String p) {
    if (o is JsObject) return o.get(p);
    if (o is JsArray) {
      if (p == 'length') return JsNum(o.v.length);
      final n = int.tryParse(p);
      if (n != null && n >= 0 && n < o.v.length) return o.v[n];
      return _arrayMethod(o, p);
    }
    if (o is JsStr) {
      if (p == 'length') return JsNum(o.v.length);
      final n = int.tryParse(p);
      if (n != null && n >= 0 && n < o.v.length) return JsStr(o.v[n]);
      return _strMethod(o, p);
    }
    if (o is JsNum) {
      if (p == 'constructor') return DartJs.u;
      return _numMethod(o, p);
    }
    if (o is JsFunction) { if (p == 'length') return JsNum(o.arity); if (p == 'name') return JsStr(o.name); }
    if (o is JsRegExp) { if (p == 'lastIndex') return JsNum(o.lastIndex); if (p == 'global') return JsBool(o.isGlobal); }
    return DartJs.u;
  }

  JsValue _bin(EBinary e, _Scope s) {
    final l = eval(e.l, s);
    if (e.op == '&&') return l.truthy ? eval(e.r, s) : l;
    if (e.op == '||') return l.truthy ? l : eval(e.r, s);
    if (e.op == '??') return (l is JsNull || l is JsUndefined) ? eval(e.r, s) : l;
    final r = eval(e.r, s);
    switch (e.op) {
      case '+':
        if (l is JsStr || r is JsStr) return JsStr(l.toS() + r.toS());
        if (l is JsArray && r is JsArray) return JsArray([...l.v, ...r.v]);
        return JsNum(_toNum(l) + _toNum(r));
      case '-': return JsNum(_toNum(l) - _toNum(r));
      case '*': return JsNum(_toNum(l) * _toNum(r));
      case '/': return JsNum(_toNum(l) / _toNum(r));
      case '%': return JsNum(_toNum(l) % _toNum(r));
      case '==': return JsBool(_looseEq(l, r));
      case '!=': return JsBool(!_looseEq(l, r));
      case '===': return JsBool(_strictEq(l, r));
      case '!==': return JsBool(!_strictEq(l, r));
      case '<': return JsBool(_cmp(l, r) < 0);
      case '>': return JsBool(_cmp(l, r) > 0);
      case '<=': return JsBool(_cmp(l, r) <= 0);
      case '>=': return JsBool(_cmp(l, r) >= 0);
      case '&': return JsNum(_toNum(l).toInt() & _toNum(r).toInt());
      case '|': return JsNum(_toNum(l).toInt() | _toNum(r).toInt());
      case '^': return JsNum(_toNum(l).toInt() ^ _toNum(r).toInt());
      case '<<': return JsNum(_toNum(l).toInt() << _toNum(r).toInt());
      case '>>': return JsNum(_toNum(l).toInt() >> _toNum(r).toInt());
      case '**': return JsNum(num.parse('${mathPow(_toNum(l), _toNum(r))}'));
    }
    return DartJs.u;
  }

  num mathPow(num a, num b) {
    var r = 1.0; final e0 = b.toInt() < 0 ? -b.toInt() : b.toInt();
    for (var i = 0; i < e0; i++) r *= a;
    if (b < 0) return 1 / r;
    return r;
  }

  bool _strictEq(JsValue l, JsValue r) {
    if (l is JsNull || l is JsUndefined) return r.runtimeType == l.runtimeType;
    if (l is JsNum && r is JsNum) return _toNum(l) == _toNum(r);
    if (l is JsStr && r is JsStr) return l.v == r.v;
    if (l is JsBool && r is JsBool) return l.v == r.v;
    return identical(l, r);
  }
  bool _looseEq(JsValue l, JsValue r) {
    if (l is JsNull || l is JsUndefined || r is JsNull || r is JsUndefined) return (l is JsNull || l is JsUndefined) && (r is JsNull || r is JsUndefined);
    if ((l is JsNum || l is JsStr) && (r is JsNum || r is JsStr)) { final a = _toNum(l), b = _toNum(r); if (a.isNaN || b.isNaN) return false; return a == b; }
    if (l is JsBool) return _looseEq(JsNum(l.v ? 1 : 0), r);
    if (r is JsBool) return _looseEq(l, JsNum(r.v ? 1 : 0));
    return _strictEq(l, r);
  }
  int _cmp(JsValue l, JsValue r) {
    if (l is JsStr && r is JsStr) return l.v.compareTo(r.v);
    final a = _toNum(l), b = _toNum(r); if (a.isNaN || b.isNaN) return 0; return a < b ? -1 : a > b ? 1 : 0;
  }

  JsValue _un(EUnary e, _Scope s) {
    if (e.op == '!') return JsBool(!eval(e.e, s).truthy);
    if (e.op == '-') return JsNum(-_toNum(eval(e.e, s)));
    if (e.op == '+') return JsNum(_toNum(eval(e.e, s)));
    if (e.op == 'typeof') { final v = eval(e.e, s); return JsStr(v is JsUndefined ? 'undefined' : v is JsNum ? 'number' : v is JsStr ? 'string' : v is JsBool ? 'boolean' : v is JsFunction ? 'function' : 'object'); }
    return DartJs.u;
  }

  JsValue _assign(EAssign e, _Scope s) {
    final v = eval(e.value, s);
    if (e.target is EId) { final id = e.target as EId; s.set(id.name, v); return v; }
    if (e.target is EMember) { final m = e.target as EMember; final o = eval(m.obj, s); _setProp(o, m.prop, v); return v; }
    if (e.target is EIndex) { final ix = e.target as EIndex; final o = eval(ix.obj, s); final k = eval(ix.idx, s); _setIndex(o, k, v); return v; }
    return DartJs.u;
  }
  JsValue _post(EPostIncDec e, _Scope s) {
    if (e.target is EId) { final id = e.target as EId; final cur = _toNum(s.find(id.name)); final delta = e.op == '++' ? 1 : -1; s.set(id.name, JsNum(cur + delta)); return JsNum(cur); }
    return DartJs.u;
  }
  void _setProp(JsValue o, String p, JsValue v) { if (o is JsObject) o.set(p, v); else if (o is JsArray) { if (p == 'length') return; final n = int.tryParse(p); if (n != null) o.setIdx(n, v); } }
  void _setIndex(JsValue o, JsValue k, JsValue v) { if (o is JsArray) { final ns = k.toDart(); if (ns is num) o.setIdx(ns.toInt(), v); else { final n = int.tryParse(k.toS()); if (n != null) o.setIdx(n, v); } } else if (o is JsObject) o.set(k.toS(), v); }

  JsValue _call(ECall c, _Scope s) {
    // 成员方法调用
    JsValue? self;
    JsValue? calleeV;
    if (c.callee is EMember) { final m = c.callee as EMember; self = eval(m.obj, s); calleeV = _getProp(self, m.prop); }
    else if (c.callee is EIndex) { final ix = c.callee as EIndex; self = eval(ix.obj, s); calleeV = _getIndex(self, eval(ix.idx, s)); }
    else { calleeV = eval(c.callee, s); }
    final args = [for (final a in c.args) eval(a, s)];
    if (calleeV is JsFunction && calleeV.isHost) return calleeV.host!(self ?? DartJs.u, args);
    if (calleeV is JsFunction) { return _callUser(calleeV, args, self); }
    return DartJs.u;
  }

  JsValue _callUser(JsFunction fn, List<JsValue> args, JsValue? self) {
    final sc = _Scope(fn.closure);
    for (var i = 0; i < fn.params.length; i++) sc.vars[fn.params[i]] = i < args.length ? args[i] : DartJs.u;
    if (fn.params.isNotEmpty && fn.params.first == '_self') {}
    try { for (final st in fn.body) execStmt(st, sc); } on _SigReturn catch (r) { return r.v; }
    return DartJs.u;
  }

  // ---------- String methods ----------
  JsValue _strMethod(JsStr self, String p) {
    final v = self.v;
    switch (p) {
      case 'toString': case 'valueOf': return host0((s, a) => self, 0);
      case 'toUpperCase': return host0((s, a) => JsStr(v.toUpperCase()), 0);
      case 'toLowerCase': return host0((s, a) => JsStr(v.toLowerCase()), 0);
      case 'trim': return host0((s, a) => JsStr(v.trim()), 0);
      case 'charAt': return host0((s, a) => JsStr(v.length > 0 ? v[_toNum(a.isEmpty ? 0 : a.first).toInt().clamp(0, v.length - 1)] : ''), 1);
      case 'indexOf': return host0((s, a) => JsNum(v.indexOf(a.isEmpty ? '' : a.first.toS(), a.length > 1 ? _toNum(a[1]).toInt() : 0)), 2);
      case 'lastIndexOf': return host0((s, a) => JsNum(v.lastIndexOf(a.isEmpty ? '' : a.first.toS())), 1);
      case 'includes': return host0((s, a) => JsBool(v.contains(a.isEmpty ? '' : a.first.toS())), 1);
      case 'startsWith': return host0((s, a) => JsBool(v.startsWith(a.isEmpty ? '' : a.first.toS())), 1);
      case 'endsWith': return host0((s, a) => JsBool(v.endsWith(a.isEmpty ? '' : a.first.toS())), 1);
      case 'split': return host0((s, a) { final sep = a.isEmpty ? '' : a.first.toS(); final xs = sep.isEmpty ? v.split('') : v.split(RegExp(RegExp.escape(sep))); return JsArray([for (final x in xs) JsStr(x)]); }, 1);
      case 'substring': return host0((s, a) { final s0 = (_toNum(a.isEmpty ? 0 : a[0])).toInt().clamp(0, v.length); final e0 = a.length > 1 ? _toNum(a[1]).toInt().clamp(0, v.length) : v.length; return JsStr(v.substring(s0 < e0 ? s0 : e0, s0 < e0 ? (a.length > 1 ? e0 : v.length) : s0)); }, 2);
      case 'substr': return host0((s, a) { var from = _toNum(a.isNotEmpty ? a[0] : 0).toInt(); if (from < 0) from += v.length; from = from.clamp(0, v.length); final len = a.length > 1 ? _toNum(a[1]).toInt() : v.length - from; final e0 = (from + len).clamp(0, v.length); return JsStr(v.substring(from, e0)); }, 2);
      case 'slice': return host0((s, a) { var s0 = _toNum(a.isNotEmpty ? a[0] : 0).toInt(); if (s0 < 0) s0 += v.length; var e0 = a.length > 1 ? _toNum(a[1]).toInt() : v.length; if (e0 < 0) e0 += v.length; return JsStr(v.substring(s0.clamp(0, v.length), e0.clamp(0, v.length))); }, 2);
      case 'replace': case 'replaceAll': return _strReplace(self, p == 'replaceAll');
      case 'match': return host0((s, a) { if (a.isEmpty || a.first is! JsRegExp) return JsNull(); final re = (a.first as JsRegExp).pattern; final m = re.firstMatch(v); if (m == null) return JsNull(); return JsArray([JsStr(m.group(0)!), for (var i = 1; i <= m.groupCount; i++) JsStr(m.group(i) ?? '')]); }, 1);
      case 'padStart': return host0((s, a) { var out = v; final len = _toNum(a.isNotEmpty ? a[0] : 0).toInt(); final pad = a.length > 1 ? a[1].toS() : ' '; while (out.length < len) out = pad + out; return JsStr(out); }, 2);
      case 'padEnd': return host0((s, a) { var out = v; final len = _toNum(a.isNotEmpty ? a[0] : 0).toInt(); final pad = a.length > 1 ? a[1].toS() : ' '; while (out.length < len) out = out + pad; return JsStr(out); }, 2);
    }
    return DartJs.u;
  }
  JsValue _strReplace(JsStr self, bool all) {
    return host0((s, a) { if (a.isEmpty) return self; final rep = a.length > 1 ? _replaceStr(a[1]) : ''; final pat = a.first; if (pat is JsRegExp) { final re = pat; if (all || re.isGlobal) return JsStr(self.v.replaceAllMapped(re.pattern, (m) => rep.replaceAllMapped(RegExp(r'\$(\d+)'), (g) { final i = int.parse(g.group(1)!); return m.group(i) ?? ''; }))); final m = re.pattern.firstMatch(self.v); if (m == null) return self; return JsStr(self.v.replaceRange(m.start, m.end, rep.replaceAllMapped(RegExp(r'\$(\d+)'), (g) { final i = int.parse(g.group(1)!); return m.group(i) ?? ''; }))); } return JsStr(self.v.replaceAll(RegExp(RegExp.escape(pat.toS())), rep)); }, 2);
  }
  String _replaceStr(JsValue v) => v is JsFunction ? '' : v.toS();

  // ---------- Array methods ----------
  JsValue _arrayMethod(JsArray self, String p) {
    final list = self.v;
    switch (p) {
      case 'toString': case 'join':
        return host0((s, a) { final sep = p == 'join' && a.isNotEmpty ? a.first.toS() : ','; return JsStr(list.map((x) => x.toS()).join(sep)); }, 1);
      case 'push': return host0((s, a) { list.addAll(a); return JsNum(list.length); }, 1);
      case 'pop': return host0((s, a) => list.isEmpty ? DartJs.u : list.removeLast(), 0);
      case 'shift': return host0((s, a) => list.isEmpty ? DartJs.u : list.removeAt(0), 0);
      case 'unshift': return host0((s, a) { for (final x in a) list.insert(0, x); return JsNum(list.length); }, 1);
      case 'indexOf': return host0((s, a) { final t = a.isEmpty ? '' : a.first.toS(); final from = a.length > 1 ? _toNum(a[1]).toInt() : 0; for (var i = from; i < list.length; i++) if (list[i].toS() == t) return JsNum(i); return JsNum(-1); }, 2);
      case 'includes': return host0((s, a) { final t = a.isEmpty ? '' : a.first.toS(); return JsBool(list.any((x) => x.toS() == t)); }, 1);
      case 'slice': return host0((s, a) { var s0 = _toNum(a.isNotEmpty ? a[0] : 0).toInt(); if (s0 < 0) s0 += list.length; var e0 = a.length > 1 ? _toNum(a[1]).toInt() : list.length; if (e0 < 0) e0 += list.length; return JsArray(list.sublist(s0.clamp(0, list.length), e0.clamp(0, list.length))); }, 2);
      case 'concat': return host0((s, a) { final out = [...list]; for (final x in a) { out.addAll(x is JsArray ? x.v : [x]); } return JsArray(out); }, 1);
      case 'map': return _cbMethod(self, 'map');
      case 'filter': return _cbMethod(self, 'filter');
      case 'forEach': return _cbMethod(self, 'forEach');
      case 'some': return _cbMethod(self, 'some');
      case 'every': return _cbMethod(self, 'every');
      case 'find': return _cbMethod(self, 'find');
      case 'findIndex': return _cbMethod(self, 'findIndex');
      case 'reverse': return host0((s, a) { final r = [...list.reversed]; list.clear(); list.addAll(r); return self; }, 0);
    }
    return DartJs.u;
  }
  JsValue _cbMethod(JsArray self, String kind) {
    final list = self.v;
    return host0((s0, a) {
      final cb = a.isEmpty ? null : a.first;
      final out = <JsValue>[];
      for (var i = 0; i < list.length; i++) {
        final r = _invokeCb(cb, [list[i], JsNum(i), self], i);
        switch (kind) {
          case 'map': out.add(r);
          case 'filter': if (r.truthy) out.add(list[i]);
          case 'forEach': break;
          case 'some': if (r.truthy) return JsBool(true);
          case 'every': if (!r.truthy) return JsBool(false);
          case 'find': if (r.truthy) return list[i];
          case 'findIndex': if (r.truthy) return JsNum(i);
        }
      }
      switch (kind) {
        case 'map': case 'filter': return JsArray(out);
        case 'forIn': break;
        case 'some': return JsBool(false);
        case 'every': return JsBool(true);
        case 'find': return DartJs.u;
        case 'findIndex': return JsNum(-1);
      }
      return DartJs.u;
    }, 1);
  }
  JsValue _invokeCb(JsValue? cb, List<JsValue> args, int index) {
    if (cb == null) return DartJs.u;
    if (cb is JsFunction && cb.isHost) return cb.host!(DartJs.u, args);
    if (cb is JsFunction) { final sc = _Scope(cb.closure); for (var i = 0; i < cb.params.length; i++) sc.vars[cb.params[i]] = i < args.length ? args[i] : DartJs.u; try { for (final st in cb.body) execStmt(st, sc); } on _SigReturn catch (r) { return r.v; } return DartJs.u; }
    return DartJs.u;
  }

  // ---------- Number methods ----------
  JsValue _numMethod(JsNum self, String p) {
    if (p == 'toString' || p == 'valueOf') return host0((s, a) => JsStr(self.toS()), 0);
    if (p == 'toFixed') return host0((s, a) => JsStr(self.v.toStringAsFixed(a.isEmpty ? 0 : _toNum(a.first).toInt())), 1);
    if (p == 'toExponential') return host0((s, a) => JsStr(self.v.toString()), 0);
    return DartJs.u;
  }
}

// scope 引用（兼容不同调用形态）

num _toNum(Object? v) {
  if (v is JsNum) return v.v;
  if (v is JsBool) return v.v ? 1 : 0;
  if (v is JsValue) {
    // 其它 JS 值：尝试字符串语义
    if (v is JsStr) return _numFromString(v.v);
    return double.nan;
  }
  if (v is num) return v;
  if (v is bool) return v ? 1 : 0;
  if (v is String) return _numFromString(v);
  return double.nan;
}

num _numFromString(String s) {
  final t = s.trim();
  if (t.isEmpty) return 0;
  return num.tryParse(t) ?? double.nan;
}