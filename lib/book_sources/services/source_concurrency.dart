// 文件说明：书源聚合请求的并发限制器。
// 技术要点：信号量模式。聚合搜索/发现页会同时向数百个书源发起请求，
// 无限制的并发会打爆移动设备的 DNS 解析与连接池，导致大面积超时失败。

import 'dart:async';

/// 限制同时在途的异步任务数量；超出部分排队等待。
class BookSourceConcurrencyLimiter {
  BookSourceConcurrencyLimiter(this.maxConcurrent)
    : assert(maxConcurrent > 0, 'maxConcurrent must be positive.');

  final int maxConcurrent;

  int _active = 0;
  final List<void Function()> _pending = [];

  /// 运行 [task]，返回其结果；任务完成或失败后释放槽位给排队任务。
  Future<T> run<T>(Future<T> Function() task) {
    final completer = Completer<T>();
    void start() {
      _active++;
      unawaited(
        () async {
          try {
            completer.complete(await task());
          } catch (error, stack) {
            completer.completeError(error, stack);
          } finally {
            _active--;
            if (_pending.isNotEmpty) {
              _pending.removeAt(0)();
            }
          }
        }(),
      );
    }

    if (_active < maxConcurrent) {
      start();
    } else {
      _pending.add(start);
    }
    return completer.future;
  }
}
