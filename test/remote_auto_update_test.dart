import 'package:flutter_test/flutter_test.dart';
import 'package:legado_flutter/book_source/services/auto_task_service.dart';
import 'package:legado_flutter/book_source/services/remote_book_service.dart';
import 'package:legado_flutter/book_source/services/update_service.dart';
import 'package:legado_flutter/book_source/services/webdav_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    AutoTaskService.instance.clear();
  });

  group('UpdateService.compareVersions', () {
    test('相等', () {
      expect(UpdateService.compareVersions('1.2.3', '1.2.3'), 0);
      expect(UpdateService.compareVersions('2.0', '2.0'), 0);
    });

    test('大版本升级', () {
      expect(UpdateService.compareVersions('1.10.0', '1.2.3'), greaterThan(0));
      expect(UpdateService.compareVersions('2.0.0', '1.9.9'), greaterThan(0));
    });

    test('子版本 / 缺少段按 0 补足', () {
      expect(UpdateService.compareVersions('1.2', '1.2.0'), 0);
      expect(UpdateService.compareVersions('1.3', '1.2.9'), greaterThan(0));
      expect(UpdateService.compareVersions('1.2.9', '1.3'), lessThan(0));
    });
  });

  group('UpdateService.checkForUpdates', () {
    test('非法/空 url 时不抛异常返回 null', () async {
      // 故意传空字符串，走空校验直接失败，不产生真实请求
      final info = await UpdateService.instance.checkForUpdates(
        currentVersion: '1.0.0',
        url: '',
      );
      expect(info, isNull);
    });

    test('构造失败请求（非法 url）返回 null 不抛异常', () async {
      final info = await UpdateService.instance.checkForUpdates(
        currentVersion: '1.0.0',
        url: 'not a valid url',
      );
      expect(info, isNull);
    });
  });

  group('AutoTaskService 持久化往返 + 到期判断 + tick', () {
    test('保存后 clear 再 init 可读回', () async {
      final s = AutoTaskService.instance;
      s.addTask(AutoTask(name: 'a', intervalMin: 30, action: 'notify'));
      s.addTask(AutoTask(name: 'b', enabled: false, intervalMin: 10));
      await s.save();

      s.clear(); // 清掉内存，模拟重启
      await s.init(); // 从 prefs 读回
      expect(s.tasks.length, 2);
      expect(s.taskByName('a')!.intervalMin, 30);
      expect(s.taskByName('a')!.action, 'notify');
      expect(s.taskByName('b')!.enabled, false);
    });

    test('dueTasks 按 enabled + interval 判定', () {
      final s = AutoTaskService.instance;
      final now = DateTime.now().toUtc();

      // 从未执行过 -> 到期
      s.addTask(AutoTask(name: 'never', intervalMin: 60));
      // 上次 2 小时前、间隔 60 分钟 -> 到期
      s.addTask(AutoTask(
        name: 'due',
        intervalMin: 60,
        lastRunAt: now.subtract(const Duration(minutes: 120)),
      ));
      // 上次 10 分钟前、间隔 60 分钟 -> 未到期
      s.addTask(AutoTask(
        name: 'notDue',
        intervalMin: 60,
        lastRunAt: now.subtract(const Duration(minutes: 10)),
      ));
      // 禁用 -> 不到期
      s.addTask(AutoTask(
        name: 'disabled',
        enabled: false,
        intervalMin: 5,
        lastRunAt: now.subtract(const Duration(days: 1)),
      ));

      final due = s.dueTasks().map((t) => t.name).toSet();
      expect(due, contains('never'));
      expect(due, contains('due'));
      expect(due, isNot(contains('notDue')));
      expect(due, isNot(contains('disabled')));
    });

    test('tick 执行到期任务并容错（未知动作不丢异常）', () async {
      final s = AutoTaskService.instance;
      // 未知动作导致 runTask 走默认分支，仍应更新 lastRunAt 且不抛异常
      s.addTask(AutoTask(
        name: 'unknown',
        intervalMin: 1,
        action: 'no_such_action',
        lastRunAt: DateTime.now().toUtc().subtract(const Duration(hours: 1)),
      ));

      await s.tick(); // 不应抛出
      final t = s.taskByName('unknown');
      expect(t, isNotNull);
      expect(t!.lastRunAt, isNotNull); // lastRunAt 已更新
    });

    test('新增到期任务 runTask 后不再到期', () async {
      final s = AutoTaskService.instance;
      s.addTask(AutoTask(name: 'n', intervalMin: 60)); // lastRunAt 为空，到期
      expect(s.dueTasks(), isNotEmpty);

      await s.runTask(s.taskByName('n')!);
      expect(s.dueTasks(), isEmpty); // 刚执行过，未到下一个周期
    });
  });

  group('RemoteBookService 未配置容错', () {
    test('未配置时列表为空、操作返回 false、不抛异常', () async {
      // 显式重置为未配置状态
      await WebDavService.instance.saveConfig(WebDavConfig());

      final r = RemoteBookService.instance;
      expect(r.isConfigured, false);

      final books = await r.listBooks();
      expect(books, isEmpty);

      final book = RemoteBook(name: 'a.txt', path: '/Legado/a.txt');
      expect(await r.download(book, saveDir: ''), false);
      expect(await r.upload(localPath: 'D:/no_such_file.txt'), false);
      expect(await r.delete(book), false);
    });
  });
}