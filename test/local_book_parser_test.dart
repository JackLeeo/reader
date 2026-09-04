import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:legado_flutter/book_source/services/txt_toc_rule_service.dart';
import 'package:legado_flutter/local/local_book_parser.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('TxtTocRuleService', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      TxtTocRuleService.instance.clear();
    });

    test('默认内置一条规则且生效', () async {
      final svc = TxtTocRuleService.instance;
      await svc.init();
      expect(svc.rules.length, 1);
      expect(svc.rules.first.name, '默认');
      expect(svc.activePattern, isNotNull);
    });

    test('新增启用/停用规则并取首个启用', () async {
      final svc = TxtTocRuleService.instance;
      await svc.init();
      svc.upsert(TxtTocRule(
          name: '卷一', patternField: r'^卷\s*[一二三0-9]+'));
      final active1 = svc.activePattern!;
      expect(active1, r'^第\s*[零一二三四五六七八九十百千0-9]+\s*[章节卷集话部回]');
      // 停用默认，启用新版
      final def = svc.rules.firstWhere((r) => r.name == '默认');
      svc.upsert(TxtTocRule(
        name: def.name,
        patternField: def.patternField,
        enabled: false,
        defaultRule: true,
      ));
      expect(svc.activePattern, r'^卷\s*[一二三0-9]+');
    });

    test('默认规则不可删除', () async {
      final svc = TxtTocRuleService.instance;
      await svc.init();
      svc.remove('默认');
      expect(svc.rules.any((r) => r.name == '默认'), isTrue);
    });
  });

  group('LocalBookParser — TXT 解析', () {
    test('按章节标题切分', () {
      const txt = '''
斗破苍穹 第一章 陨落的天才
　　这里是萧炎的家。
　　少年眼神坚毅。

　　第二章 斗气大陆
　　大陆辽阔，强者如云。
　　这一日，风起云涌。
''';
      final book = LocalBookParser.parseTxt(txt, '斗破苍穹');
      expect(book.name, '斗破苍穹');
      expect(book.chapters.length, 2);
      expect(book.chapters[0].title, contains('第一章'));
      expect(book.chapters[0].content, contains('萧炎的家'));
      expect(book.chapters[1].title, contains('第二章'));
      expect(book.chapters[1].content, contains('风起云涌'));
    });

    test('English Chapter 分章', () {
      const txt = 'Chapter 1\nhello world\ncontent here\nChapter 2\nnext part\nend';
      final book = LocalBookParser.parseTxt(txt, 'en');
      expect(book.chapters.length, 2);
      expect(book.chapters[0].title, 'Chapter 1');
      expect(book.chapters[0].content, 'hello world\ncontent here');
    });

    test('无章节标题兜底为单正文', () {
      const txt = '这是没有章节标题的文本，全部归入正文。';
      final book = LocalBookParser.parseTxt(txt, 'novel');
      expect(book.chapters.length, 1);
      expect(book.chapters[0].content, contains('正文'));
    });

    test('自定义目录规则分章', () {
      const txt = '卷一 风起\n正文一\n正文二\n卷二 云涌\n正文三\nend';
      final book = LocalBookParser.parseTxt(txt, 'novel',
          chapterRegex: r'^卷\s*[一二三四五六七八九十0-9]+');
      expect(book.chapters.length, 2);
      expect(book.chapters[0].title, '卷一 风起');
      expect(book.chapters[1].title, '卷二 云涌');
      expect(book.chapters[0].content, isNot(contains('卷二')));
    });
  });

  group('LocalBookParser — EPUB 解析', () {
    List<int> buildEpub({required String title, required String author, required List<(String, String)> spine}) {
      final archive = Archive();
      // mimetype
      archive.addFile(ArchiveFile.string('mimetype', 'application/epub+zip'));

      // container
      const container = '''
<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>''';
      archive.addFile(ArchiveFile.string('META-INF/container.xml', container));

      // OPF
      final items = StringBuffer();
      final itemrefs = StringBuffer();
      for (var i = 0; i < spine.length; i++) {
        items.writeln('    <item id="c$i" href="chapter$i.xhtml" media-type="application/xhtml+xml"/>');
        itemrefs.writeln('    <itemref idref="c$i"/>');
      }
      final opf = '''
<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>$title</dc:title>
    <dc:creator>$author</dc:creator>
  </metadata>
  <manifest>
$items  </manifest>
  <spine>
$itemrefs  </spine>
</package>''';
      archive.addFile(ArchiveFile.string('OEBPS/content.opf', opf));

      // chapters
      for (var i = 0; i < spine.length; i++) {
        final (_, body) = spine[i];
        final xhtml = '<?xml version="1.0" encoding="UTF-8"?>'
            '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>第${i + 1}章</title></head>'
            '<body><h1>第${i + 1}章</h1><p>$body</p></body></html>';
        archive.addFile(ArchiveFile.string('OEBPS/chapter$i.xhtml', xhtml));
      }

      final zip = ZipEncoder().encode(archive);
      return Uint8List.fromList(zip!);
    }

    test('解析基本信息与章节', () {
      final bytes = buildEpub(
        title: '测试之书',
        author: '作者甲',
        spine: [('', '第一章的内容。'), ('', '第二章的内容。')],
      );
      final book = LocalBookParser.parseEpub(bytes);
      expect(book.name, '测试之书');
      expect(book.author, '作者甲');
      expect(book.chapters.length, 2);
      expect(book.chapters[0].content, contains('第一章的内容'));
      expect(book.chapters[1].content, contains('第二章的内容'));
    });

    test('中文内容正确解码（UTF-8）', () {
      final bytes = buildEpub(title: '中文书', author: '佚名', spine: [('', '斗破苍穹第一章，风起云涌。')]);
      final book = LocalBookParser.parseEpub(bytes);
      expect(book.chapters.first.content, contains('斗破苍穹'));
    });
  });

  group('LocalBookParser — 纯函数正确性', () {
    test('UTF-8 中文解码不乱码', () {
      // 构造含中文的 EPUB，验证 UTF-8 解码
      final archive = Archive()..addFile(ArchiveFile.string('mimetype', 'application/epub+zip'));
      const container = '<container><rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles></container>';
      archive.addFile(ArchiveFile.string('META-INF/container.xml', container));
      final opf = '<package><metadata><dc:title>中文</dc:title></metadata><manifest><item id="c0" href="c0.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="c0"/></spine></package>';
      archive.addFile(ArchiveFile.string('OEBPS/content.opf', opf));
      final xhtml = '<html><body><p>你好，世界</p></body></html>';
      archive.addFile(ArchiveFile.string('OEBPS/c0.xhtml', xhtml));
      final bytes = Uint8List.fromList(ZipEncoder().encode(archive)!);

      final book = LocalBookParser.parseEpub(bytes);
      expect(book.name, '中文');
      expect(book.chapters.first.content, contains('你好，世界'));
    });
  });
}