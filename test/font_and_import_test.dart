import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:legado_flutter/book_source/services/font_service.dart';
import 'package:legado_flutter/book_source/utils/source_import_parser.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  group('SourceImportParser', () {
    test('JSON 数组解析', () {
      final list = SourceImportParser.parse(
        '[{"bookSourceUrl":"https://a.com","bookSourceName":"A"},'
        '{"bookSourceUrl":"https://b.com","bookSourceName":"B"}]',
      );
      expect(list.length, 2);
      expect(list[0].bookSourceName, 'A');
    });

    test('单对象解析', () {
      final list = SourceImportParser.parse(
        '{"bookSourceUrl":"https://c.com","bookSourceName":"C"}',
      );
      expect(list.length, 1);
      expect(list[0].bookSourceUrl, 'https://c.com');
    });

    test('bookSources 包装解析', () {
      final list = SourceImportParser.parse(
        '{"bookSources":[{"bookSourceUrl":"https://d.com","bookSourceName":"D"}]}',
      );
      expect(list.length, 1);
      expect(list[0].bookSourceName, 'D');
    });

    test('text: 前缀与代码围栏清理', () {
      final list = SourceImportParser.parse(
        'text: ```[{"bookSourceUrl":"https://e.com","bookSourceName":"E"}]```',
      );
      expect(list.length, 1);
      expect(list[0].bookSourceUrl, 'https://e.com');
    });

    test('无有效源 / 空串 / 空白返回空', () {
      expect(SourceImportParser.parse(''), isEmpty);
      expect(SourceImportParser.parse('[{}]'), isEmpty);
      expect(SourceImportParser.parse('not json'), isEmpty);
    });
  });

  group('FontService', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('font_test_');
    });

    tearDown(() async {
      FontService.instance.reset();
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    });

    FontEntry entry(String name) =>
        FontEntry(name: name, url: '', filePath: '');

    test('add / has / byName / remove 持久化', () async {
      await FontService.instance.setRoot(tmp);
      FontService.instance.add(entry('黑体'));
      expect(FontService.instance.has('黑体'), isTrue);
      expect(FontService.instance.byName('黑体')!.name, '黑体');
      FontService.instance.remove('黑体');
      expect(FontService.instance.has('黑体'), isFalse);
    });

    test('download 存字体字节并返回路径', () async {
      await FontService.instance.setRoot(tmp);
      final svc = FontService.instance;
      svc.fetchOverride = (url) async => [1, 2, 3, 4];
      final path = await svc.download('宋体', 'https://x/font.ttf');
      expect(path, isNotNull);
      expect(File(path!).existsSync(), isTrue);
      expect(File(path).readAsBytesSync(), [1, 2, 3, 4]);
    });

    test('download 失败返回 null 且不加入列表', () async {
      await FontService.instance.setRoot(tmp);
      final svc = FontService.instance;
      svc.fetchOverride = (url) async => null;
      final path = await svc.download('失败源', 'https://x/font.ttf');
      expect(path, isNull);
      expect(svc.has('失败源'), isFalse);
    });

    test('availableFamilies 只含已启用', () async {
      await FontService.instance.setRoot(tmp);
      final svc = FontService.instance;
      svc.add(FontEntry(name: 'A', url: 'u', filePath: '/tmp/a.ttf', enabled: true));
      svc.add(FontEntry(name: 'B', url: 'u', filePath: '/tmp/b.ttf'));
      expect(svc.availableFamilies(), ['A']);
    });
  });
}