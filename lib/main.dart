import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'app.dart';
import 'book_source/js/fjs_engine.dart';
import 'book_source/services/auto_task_service.dart';
import 'book_source/services/book_cache_service.dart';
import 'book_source/services/book_source_service.dart';
import 'book_source/services/bookmark_service.dart';
import 'book_source/services/comic_offline_service.dart';
import 'book_source/services/cookie_service.dart';
import 'book_source/services/dict_service.dart';
import 'book_source/services/font_service.dart';
import 'book_source/services/highlight_service.dart';
import 'book_source/services/note_service.dart';
import 'book_source/services/read_stat_service.dart';
import 'book_source/services/replace_rule_service.dart';
import 'book_source/services/rss_service.dart';
import 'book_source/services/rule_subscription_service.dart';
import 'book_source/services/proxy_service.dart';
import 'book_source/services/shelf_service.dart';
import 'book_source/services/tts_service.dart';
import 'book_source/services/webdav_service.dart';
import 'core/reading_pref.dart';
import 'core/audio_playback_service.dart';
import 'core/app_link_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 初始化数据服务：书源 + 书架 + 阅读偏好 + RSS + TTS + 书签 + 替换规则 + 阅读统计。
  await BookSourceService.instance.init();
  await ShelfService.instance.init();
  await ReadingPref.instance.load();
  await RssService.instance.init();
  await TtsEngineService.instance.init();
  await BookmarkService.instance.init();
  await ReplaceRuleService.instance.init();
  await ReadStatService.instance.init();
  await WebDavService.instance.init();
  await RuleSubscriptionService.instance.init();
  await ProxyService.instance.init();
  await CookieService.instance.init();
  await DictService.instance.init();
  await HighlightService.instance.init();
  await NoteService.instance.init();
  await AutoTaskService.instance.init();
  // 漫画离线 / 文本缓存 存储根目录：应用文档目录。
  try {
    final docs = await getApplicationDocumentsDirectory();
    await ComicOfflineService.instance.setRoot(Directory(docs.path));
    await BookCacheService.instance.setRoot(Directory(docs.path));
    await FontService.instance.setRoot(Directory(docs.path));
    // 注册已启用的阅读字体到 Flutter。
    for (final f in FontService.instance.availableFamilies()) {
      unawaited(FontService.instance.register(f));
    }
  } catch (_) {
    // 非真机环境（部分测试）拿不到文档目录时跳过，离线/缓存/字体功能不可用即可。
  }
  // 后台音频播放：随启动异步初始化，失败静默降级（不影响其余功能）。
  unawaited(AudioPlaybackService.instance.init());
  unawaited(_warmUpJsEngine());
  runApp(const LegadoApp());
  // 系统分享链接接收（冷/热启动）在根 Widget 就绪后启动。
  unawaited(AppLinkService.instance.init());
  // 定时任务驱动：每分钟调度一次 AutoTaskService，触发书架新章节检测 / RSS 刷新等。
  Timer.periodic(const Duration(minutes: 1), (_) {
    unawaited(AutoTaskService.instance.tick());
  });
  // 后台恢复补算：App 回到前台时立即执行一轮到期检测，弥补运行期间错过的定时任务。
  final autoTick = _AppLifecycleAutoTick();
  WidgetsBinding.instance.addObserver(autoTick);
}

/// 生命周期观察者：App 从后台恢复到前台时，立即补算一次 AutoTaskService 到期任务。
class _AppLifecycleAutoTick with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(AutoTaskService.instance.tick());
    }
  }
}

/// 预热 fjs 引擎并记录可用性。
///
/// 提前加载原生 QuickJS 库并完成一次 `$api` 桥自检，避免首段 JS 规则求值时才
/// 触发初始化带来的卡顿；同时把引擎可用性写入日志便于排查（不可用时规则自动降级 DartJs）。
Future<void> _warmUpJsEngine() async {
  try {
    final engine = FjsJsEngine.instance;
    await engine.ensureReady();
    if (engine.isAvailable) {
      final v = await engine.evaluate(r'''$api.base64Encode('fjs-ok')''');
      debugPrint('[FjsJsEngine] warmup ok, \$api test result: $v');
    } else {
      debugPrint('[FjsJsEngine] unavailable, JS 规则走 DartJs 降级');
    }
  } catch (e) {
    debugPrint('[FjsJsEngine] warmup failed: $e');
  }
}