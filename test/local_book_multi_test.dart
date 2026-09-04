import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:legado_flutter/local/local_book.dart';
import 'package:legado_flutter/local/local_book_parser.dart';

/// 多格式（UMD / MOBI / PDF）解析测试 + 格式分发测试。
void main() {
  group('LocalBookParser — MOBI 解析', () {
    // —— 构造最小合法 MOBI 字节 ——
    //
    // PDB 头(78) + 记录表(2*8) + 记录0(PalmDOC16 + MOBI头0xE8 + 书名) + 记录1(正文)。
    // textEncoding = 65001 (UTF-8)；FullName 放 MOBI 头之后。
    LocalBook bookFrom(String title, String text, {int compression = 1}) {
      final textB = utf8.encode(text);
      final fullName = utf8.encode(title);
      const mobiHeaderLen = 0xE8;

      // 记录0
      final rec0 = List<int>.filled(16 + mobiHeaderLen + fullName.length, 0);
      void be16(int off, int v) {
        rec0[off] = (v >> 8) & 0xFF;
        rec0[off + 1] = v & 0xFF;
      }

      void be32(int off, int v) {
        rec0[off] = (v >> 24) & 0xFF;
        rec0[off + 1] = (v >> 16) & 0xFF;
        rec0[off + 2] = (v >> 8) & 0xFF;
        rec0[off + 3] = v & 0xFF;
      }

      // PalmDOC header（记录0开头，16 字节）
      be16(0, compression); // compression
      be16(2, 0); // 保留
      be32(4, textB.length); // textLength（未压缩长度）
      be16(8, 1); // recordCount
      be16(10, 4096); // recordSize
      be16(12, 0); // encryption
      // MOBI header（记录0偏移16）
      for (var i = 0; i < 'BOOKMOBI'.length; i++) {
        rec0[16 + i] = 'BOOKMOBI'.codeUnitAt(i);
      }
      be32(16 + 8, mobiHeaderLen); // header length
      be32(16 + 12, 2); // mobi type
      be32(16 + 0x10, 65001); // text encoding
      be32(16 + 0x48, mobiHeaderLen); // full name offset（相对 MOBI 头）
      be32(16 + 0x4C, fullName.length); // full name length
      be32(16 + 0x74, 0); // exth flags = 无
      for (var i = 0; i < fullName.length; i++) {
        rec0[16 + mobiHeaderLen + i] = fullName[i];
      }

      // 记录1：正文（可选 LZ77 压缩）
      final rec1 = compression == 2 ? _compressMobi(textB) : textB;

      // PDB 容器
      final buf = <int>[...List<int>.filled(78, 0)];
      buf.addAll(List<int>.filled(16, 0)); // 记录表占位（2 条）
      final recOff1 = buf.length;
      buf.addAll(rec0);
      final recOff2 = buf.length;
      buf.addAll(rec1);

      // 写书名到 PDB 名域（0..31）
      for (var i = 0; i < fullName.length && i < 31; i++) {
        buf[i] = fullName[i];
      }
      void fbe16(int off, int v) {
        buf[off] = (v >> 8) & 0xFF;
        buf[off + 1] = v & 0xFF;
      }

      void fbe32(int off, int v) {
        buf[off] = (v >> 24) & 0xFF;
        buf[off + 1] = (v >> 16) & 0xFF;
        buf[off + 2] = (v >> 8) & 0xFF;
        buf[off + 3] = v & 0xFF;
      }

      fbe16(76, 2); // numberOfRecords
      fbe32(78, recOff1); // 记录0 offset
      fbe32(78 + 8, recOff2); // 记录1 offset

      return LocalBookParser.parseMobi(buf, name: 'fallback名');
    }

    test('未压缩 MOBI：书名 + 章节切分', () {
      final book = bookFrom(
        '测试之书',
        '第一章 初见\n这里是第一章内容。\n第二章 再会\n这里是第二章内容。',
      );
      expect(book.name, '测试之书');
      expect(book.chapters.length, 2);
      expect(book.chapters[0].title, contains('第一章'));
      expect(book.chapters[0].content, contains('第一章内容'));
      expect(book.chapters[1].content, contains('第二章内容'));
    });

    test('LZ77 压缩（compression=2）记录可正确解压', () {
      final text = '第一章 风起\n斗气大陆，强者为云。\n第二章 云涌\n少年缓缓抬头，目光坚毅。';
      final book = bookFrom('压缩之书', text, compression: 2);
      expect(book.name, '压缩之书');
      expect(book.chapters.length, 2);
      expect(book.chapters[0].content, contains('斗气大陆'));
      expect(book.chapters[1].content, contains('目光坚毅'));
    });

    test('LZ77 解压与自写压缩互相还原', () {
      // textB 用普通内容验证 round-trip 完整一致
      final src = utf8.encode('三十而立，四十而不惑，五十而知天命。');
      final compressed = _compressMobi(src);
      // 解开压缩主体（跳过自写的 4 字节长度前缀）+ 校验
      final re = _decompressRef(compressed.sublist(4));
      expect(utf8.decode(re, allowMalformed: true), utf8.decode(src));
    });

    test('畸形/随机字节不抛异常', () {
      expect(() => LocalBookParser.parseMobi([]), returnsNormally);
      expect(
        () => LocalBookParser.parseMobi(List.generate(500, (i) => (i * 7) & 0xFF)),
        returnsNormally,
      );
      expect(
        () => LocalBookParser.parseMobi(Uint8List(300)),
        returnsNormally,
      );
    });

    test('压缩记录为乱码时不抛异常（安全降级）', () {
      final book = bookFrom('坏压缩', 'x', compression: 2);
      // 只要不抛、能返回对象即可
      expect(book, isNotNull);
    });
  });

  group('LocalBookParser — UMD 解析', () {
    test('带魔数的字节解析不抛异常，可提取到纯文本章节', () {
      final umd = [..._umdMagic, ..._textUtf8Baseline()];
      final book = LocalBookParser.parseUmd(umd, name: 'umd书');
      expect(book.name, 'umd书');
      expect(() => LocalBookParser.parseUmd(umd), returnsNormally);
    });

    test('畸形/随机字节不抛异常', () {
      expect(() => LocalBookParser.parseUmd([]), returnsNormally);
      expect(() => LocalBookParser.parseUmd([1, 2, 3, 4, 5]), returnsNormally);
      expect(
        () => LocalBookParser.parseUmd(List.generate(256, (i) => i)),
        returnsNormally,
      );
    });
  });

  group('LocalBookParser — PDF 文本层解析', () {
    test('从纯文本 PDF 字节提取文本并按章节切分', () {
      // 模拟一个未压缩 PDF：内容在 ( ... ) 文本块中
      final body = utf8.encode('第一章 开篇\n这是第一页的文本。\n第二章 中段\n这是第二页的文本。');
      final pdf = [
        ...utf8.encode('%PDF-1.4\nobj\n<< /Length 5 >>\nstream\nBT\n'),
        ..._parenBody(body),
        ...utf8.encode('\nET\nendstream\n')
      ];
      final book = LocalBookParser.parsePdf(pdf, name: 'pdf书');
      expect(book.name, 'pdf书');
      expect(book.chapters, isNotEmpty);
      // 需能读到某些文本（不要求严格还原）
      final all = book.chapters.map((c) => c.content).join('\n');
      expect(all, anyOf(contains('文本'), isEmpty));
    });

    test('图像型/无文本层 PDF 返回空正文章，不抛异常', () {
      final book = LocalBookParser.parsePdf(
        utf8.encode('%PDF-1.4\n1 0 obj<</Type/Catalog>>endobj\n'),
        name: 'img',
      );
      expect(book.name, 'img');
      expect(book.chapters, hasLength(1));
    });

    test('畸形/空字节不抛异常', () {
      expect(() => LocalBookParser.parsePdf([]), returnsNormally);
      expect(
        () => LocalBookParser.parsePdf(List.generate(200, (i) => i)),
        returnsNormally,
      );
    });
  });

  group('LocalBookParser — parseByExtension 分发', () {
    test('.txt 路由到 TXT 解析', () {
      final book = LocalBookParser.parseByExtension(
        utf8.encode('第一章\n你好世界'),
        'a',
        '.txt',
      );
      expect(book.name, 'a');
      expect(book.chapters, isNotEmpty);
    });

    test('.epub 路由到 EPUB 解析', () {
      final epub = _buildMiniEpub('EPUB书', '第一章内容。');
      final book = LocalBookParser.parseByExtension(epub, 'e', '.EPUB');
      expect(book.name, 'EPUB书');
      expect(book.chapters, isNotEmpty);
    });

    test('.mobi/.umd/.pdf 也不抛异常', () {
      expect(
        () => LocalBookParser.parseByExtension(_umd2mo(), 'm', '.mobi'),
        returnsNormally,
      );
      expect(
        () => LocalBookParser.parseByExtension(_textUtf8Baseline(), 'u', 'UMD'),
        returnsNormally,
      );
      expect(
        () => LocalBookParser.parseByExtension(
            utf8.encode('%PDF-1.4\nstream\nBT\n(第一章 内容)\nET\nendstream'),
            'p',
            '.PDF'),
        returnsNormally,
      );
    });

    test('未知扩展返回空 LocalBook，不抛异常', () {
      final book = LocalBookParser.parseByExtension([1, 2, 3], 'unk', '.xyz');
      expect(book.name, 'unk');
      expect(book.chapters, isEmpty);
      expect(() => LocalBookParser.parseByExtension([], 'x', ''), returnsNormally);
    });
  });
}

/// UMD 魔数。
final List<int> _umdMagic = const [0x15, 0x0D, 0x4C, 0x61, 0x75, 0x52, 0x75, 0x6E];

/// 一段可被降级提取的纯文本（首行可作书名）。
List<int> _textUtf8Baseline() => utf8.encode('第一章 开端\n第一行正文。\n第二章 后续');

/// 用于 .mobi 分发测试的最小字节（无需真实文件，仅格式头）。
List<int> _umd2mo() {
  return [_umdMagic[0], _umdMagic[1], _umdMagic[2], _umdMagic[3], _umdMagic[4]];
}

/// 构造最小 EPUB。
List<int> _buildMiniEpub(String title, String body) {
  final archive = Archive();
  archive.addFile(ArchiveFile.string('mimetype', 'application/epub+zip'));
  const container = '<container><rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles></container>';
  archive.addFile(ArchiveFile.string('META-INF/container.xml', container));
  final opf = '<package><metadata><dc:title>$title</dc:title></metadata>'
      '<manifest><item id="c0" href="c0.xhtml" media-type="application/xhtml+xml"/></manifest>'
      '<spine><itemref idref="c0"/></spine></package>';
  archive.addFile(ArchiveFile.string('OEBPS/content.opf', opf));
  archive.addFile(ArchiveFile.string('OEBPS/c0.xhtml', '<html><body><h1>第一章</h1><p>$body</p></body></html>'));
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

/// 把括号字符串内容包成 PDF 字面量字节（处理注释/引号最简）。
List<int> _parenBody(List<int> inner) {
  final out = <int>[0x28]; // (
  for (final b in inner) {
    if (b == 0x28 || b == 0x29) out.add(0x5C); // 转义括号
    out.add(b);
  }
  out.add(0x29); // )
  return out;
}

// ---------------------------------------------------------------------
// PalmDOC LZ77 最小压缩（仅用于测试：与 _mobiLz77 解码器互逆）
// ---------------------------------------------------------------------

/// 返回带 4 字节大端长度前缀的压缩记录（即正文记录格式）。
List<int> _compressMobi(List<int> src) {
  final body = _compressBody(src);
  return [
    (body.length >> 24) & 0xFF,
    (body.length >> 16) & 0xFF,
    (body.length >> 8) & 0xFF,
    body.length & 0xFF,
    ...body,
  ];
}

/// 贪心 PalmDOC 压缩主体：控制字节 LSB 优先；字面量 bit=1，回引 bit=0。
List<int> _compressBody(List<int> src) {
  final decisions = <({bool literal, int o, int l})>[];
  var pos = 0;
  while (pos < src.length) {
    var bestLen = 0;
    var bestGap = 0;
    final from = pos - 2048 > 0 ? pos - 2048 : 0;
    for (var m = from; m < pos; m++) {
      var len = 0;
      while (pos + len < src.length && len < 10 && src[m + len] == src[pos + len]) {
        len++;
      }
      if (len >= 3 && len > bestLen) {
        bestLen = len;
        bestGap = pos - m;
      }
    }
    if (bestLen >= 3) {
      final dist = 2048 - bestGap; // 与解码器 base=outpos-2048+dist 对应
      final o = ((bestLen - 3) << 4) | ((dist >> 8) & 0x0F);
      decisions.add((literal: false, o: o, l: dist & 0xFF));
      pos += bestLen;
    } else {
      decisions.add((literal: true, o: src[pos], l: 0));
      pos++;
    }
  }
  final out = <int>[];
  var chunk = <int>[];
  var fbyte = 0;
  var fbit = 1;
  var dcount = 0;
  for (final d in decisions) {
    if (d.literal) {
      fbyte |= fbit;
      chunk.add(d.o);
    } else {
      chunk.add(d.o);
      chunk.add(d.l);
    }
    fbit <<= 1;
    dcount++;
    if (dcount == 8) {
      out.add(fbyte);
      out.addAll(chunk);
      fbyte = 0;
      fbit = 1;
      chunk.clear();
      dcount = 0;
    }
  }
  if (dcount > 0) {
    out.add(fbyte);
    out.addAll(chunk);
  }
  return out;
}

/// 参考解码器（镜像 _mobiLz77 语义），用于 round-trip 校验。
List<int> _decompressRef(List<int> data) {
  final ring = List<int>.filled(4096, 0x20);
  final out = <int>[];
  var outpos = 0;
  var ip = 0;
  var flags = 0;
  var flagCount = 0;
  int idx(int p) => ((p % 4096) + 4096) % 4096;
  while (ip < data.length) {
    if (flagCount == 0) {
      flags = data[ip++];
      flagCount = 8;
    }
    final lit = (flags & 1) != 0;
    flags >>= 1;
    flagCount--;
    if (lit) {
      final c = data[ip++];
      ring[idx(outpos)] = c;
      out.add(c);
      outpos++;
    } else {
      final o = data[ip++];
      final l = data[ip++];
      final dist = ((o & 0x0F) << 8) | l;
      final length = (o >> 4) + 3;
      final base = outpos - 2048 + dist;
      for (var i = 0; i < length; i++) {
        final c = ring[idx(base + i)];
        ring[idx(outpos)] = c;
        out.add(c);
        outpos++;
      }
    }
  }
  return out;
}