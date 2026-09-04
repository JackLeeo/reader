import 'package:flutter/foundation.dart';

/// JS 引擎抽象（对应官方 Rhino / BackstageWebView 的 JS 执行层）。
///
/// 跨平台版通过平台桥接注入具体实现：
/// - Android / iOS: fjs / QuickJS
/// - 桌面: Node 或 quickjs
/// - 不可用时 [evaluate] 返回 null，规则链退化为非 JS 求值。
abstract class JsEngine {
  const JsEngine();

  bool get isAvailable;

  /// 执行 [js]，注入 [bindings]，返回 TOSTRING 结果或 null。
  Future<String?> evaluate(
    String js, {
    Map<String, Object?> bindings = const {},
  });

  /// 测试用：判断给定 JS 是否可能包含变量引用（非精确）。
  @protected
  static const kVoid = '';
}

/// 占位实现：什么都不执行，返回 null。
/// 直到平台 JS 引擎接入前用于保证整体可编译可单测非 JS 部分。
class JsEngineStub extends JsEngine {
  const JsEngineStub();

  @override
  bool get isAvailable => false;

  @override
  Future<String?> evaluate(
    String js, {
    Map<String, Object?> bindings = const {},
  }) async {
    return null;
  }
}