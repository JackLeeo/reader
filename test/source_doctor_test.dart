// source doctor 的 flutter test 驱动入口。
// 工具核心逻辑在 tool/source_doctor.dart（复用应用真实链路，依赖
// Flutter 插件运行时，因此不能直接 dart run，用 flutter test 承载）。
//
// 注意: TestWidgetsFlutterBinding 会安装全局 HttpOverrides 把所有
// HttpClient 请求 mock 成空 body 的 HTTP 400; doctor 内部已通过
// `HttpOverrides.global = null` 恢复真实网络, 切勿在别处重设。
//
// 该测试走真实网络且耗时分钟级，默认跳过；在 tool/doctor_config.json
// 里加 "run": true 或设置环境变量 SD_RUN=1 显式启用。
//
// 用法示例（PowerShell 受限时直接改 tool/doctor_config.json）:
//   {"mode":"health","run":true,"concurrency":16,"timeoutSec":8}
//   {"mode":"chain","run":true,"source":"奇书"}
//   {"mode":"export","run":true}
// 或:
//   $env:SD_RUN='1'; $env:SD_MODE='health'; flutter test test/source_doctor_test.dart

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/source_doctor.dart';

bool _doctorEnabled() {
  if (Platform.environment['SD_RUN'] == '1') return true;
  try {
    final file = File('tool/doctor_config.json');
    if (!file.existsSync()) return false;
    final decoded = jsonDecode(file.readAsStringSync());
    return decoded is Map && decoded['run'] == true;
  } on FormatException {
    return false;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'source doctor',
    () async {
      await runSourceDoctor();
    },
    skip: _doctorEnabled() ? false : '设 tool/doctor_config.json "run":true 启用',
    timeout: const Timeout(Duration(minutes: 40)),
  );
}
