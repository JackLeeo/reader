import 'package:flutter_test/flutter_test.dart';
import 'package:legado_flutter/book_source/services/read_stat_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
  });

  group('ReadStatService', () {
    test('init / 空状态安全', () async {
      final s = ReadStatService.instance;
      await s.init();
      expect(s.totalSeconds, 0);
      expect(s.todaySeconds, 0);
      expect(s.topBooks, isEmpty);
    });

    test('addSeconds 累计并按书汇总', () async {
      final s = ReadStatService.instance;
      await s.init();
      s.clear();

      s.addSeconds('a|1', title: '书A', seconds: 30);
      s.addSeconds('a|1', title: '书A', seconds: 30);
      s.addSeconds('b|2', title: '书B', seconds: 10);

      expect(s.totalSeconds, 70);
      expect(s.todaySeconds, 70);
      final top = s.topBooks;
      expect(top.length, 2);
      expect(top.first.bookKey, 'a|1');
      expect(top.first.seconds, 60);
      expect(top.last.seconds, 10);
    });

    test('持久化往返', () async {
      final s = ReadStatService.instance;
      await s.init();
      s.clear();
      s.addSeconds('x|9', title: 'X', seconds: 120);

      // 重新实例化（同一 prefs 存储）应恢复累计。
      final s2 = ReadStatService.instance;
      await s2.init();
      expect(s2.totalSeconds, 120);
      expect(s2.topBooks.single.title, 'X');
    });
  });
}
