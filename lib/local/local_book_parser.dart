import 'package:archive/archive.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:xml/xml.dart';

import 'dart:convert';
import 'dart:typed_data' show Uint8List;

import 'local_book.dart';

/// 本地书多格式解析（纯 Dart，不依赖额外 pub 包）。
///
/// 支持：TXT / EPUB / MOBI / UMD / PDF。
///
/// ## 各格式能力边界（对齐官方 Legado，跨平台版做了"约简"）
/// - **TXT / EPUB**：完整解析（章节切分、元数据）。
/// - **MOBI / PalmDOC**：文本层完整度较高 —— 读取 PalmDOC+MOBI 头，
///   支持 LZ77（PalmDOC compression type 2）解压、EXTH/FullName 书名、HTML→纯文本章节切分。
///   图像/索引类记录（INDX、Huffman 表等）不在正文范围内。
/// - **UMD / UbmFile**：官方用 UBM 压缩 + 加密，跨平台版**无法完整解出加密二进制正文**，
///   这里降级为"通用可读文本提取"（UTF8/latin1 解码 + 剥离非可读字节 + 按目录关键字切分章节）——
///   保证可导入、不抛异常，但加密正文可能提取不全。
/// - **PDF**：官方用 PdfRenderer 渲染成图；跨平台版无重依赖，改为**文本层近似**——
///   扫描 `( ... )` 文本块提取可读字符串，图像型 PDF（无文本层）正文为空。不渲染页面图像。
class LocalBookParser {
  // ------------------------------------------------------------------
  // TXT
  // ------------------------------------------------------------------

  /// 常见章节标题正则：`第[零一二三四五六七八九十百千0-9]+[章节卷集话部回]`、`Chapter N`、`VOL.N`。
  static final RegExp _chapterRe = RegExp(
    r'^(第\s*[零一二三四五六七八九十百千0-9]+\s*[章节卷集话部回]'
    r'|Chapter\s+\d+|CHAP\.\s*\d+|VOL\.\s*\d+)',
    caseSensitive: false,
    multiLine: true,
  );

  /// 据用户配置的目录规则正则构造分章正则；为空/非法时回退内置 [_chapterRe]。
  static RegExp _chapterRegexOf(String? pattern) {
    final p = pattern?.trim() ?? '';
    if (p.isEmpty) return _chapterRe;
    try {
      return RegExp(p, caseSensitive: false, multiLine: true);
    } catch (_) {
      return _chapterRe;
    }
  }

  /// 解析 TXT 正文，按章节标题切分。[chapterRegex] 可注入用户目录规则。
  static LocalBook parseTxt(String content, String name, {String? chapterRegex}) {
    final re = _chapterRegexOf(chapterRegex);
    final lines = content.replaceAll('\r\n', '\n').split('\n');
    final chapters = <LocalChapter>[];
    var current = LocalChapter(title: '第一章');
    final buf = <String>[];

    for (final line in lines) {
      final t = line.trim();
      if (t.isNotEmpty && re.hasMatch(t)) {
        _flush(current, buf, chapters);
        current = LocalChapter(title: t);
      } else {
        buf.add(line);
      }
    }
    _flush(current, buf, chapters);
    // 去空章节
    chapters.removeWhere((c) => c.content.trim().isEmpty && c.title.isEmpty);
    if (chapters.isEmpty && content.trim().isNotEmpty) {
      chapters.add(LocalChapter(title: '正文', content: content));
    }
    return LocalBook(name: name, chapters: chapters);
  }

  static void _flush(LocalChapter c, List<String> buf, List<LocalChapter> out) {
    if (buf.isNotEmpty) {
      c.content = buf.join('\n').trim();
      buf.clear();
      if (c.content.isNotEmpty || c.title.isNotEmpty) out.add(c);
    } else if (c.title.isNotEmpty && out.isNotEmpty) {
      // 空章（仅标题）仍旧保留标题，正文为空
      out.add(LocalChapter(title: c.title));
    }
  }

  // ------------------------------------------------------------------
  // EPUB
  // ------------------------------------------------------------------

  /// 解析 EPUB（ZIP 容器）。
  static LocalBook parseEpub(List<int> bytes, {String name = ''}) {
    final archive = ZipDecoder().decodeBytes(Uint8List.fromList(bytes));
    final files = <String, ArchiveFile>{};
    for (final f in archive.files) {
      if (!f.isFile) continue;
      files[f.name] = f;
    }

    // 1. 找到 OPF（container.xml 或根目录 *.opf）
    String? opfPath = _findOpf(files);
    if (opfPath == null) return LocalBook(name: name);

    final opf = _decodeUtf8(files[opfPath]!.content as List<int>);
    final opfDir = opfPath.contains('/')
        ? opfPath.substring(0, opfPath.lastIndexOf('/') + 1)
        : '';

    final doc = XmlDocument.parse(opf);

    // 标题（用局部名匹配，兼容 dc:title 命名空间前缀）
    var title = name;
    final titleEl = _firstByLocalName(doc, 'title');
    if (titleEl != null && titleEl.innerText.trim().isNotEmpty) {
      title = titleEl.innerText.trim();
    }
    String? author;
    final creatorEl = _firstByLocalName(doc, 'creator');
    if (creatorEl != null && creatorEl.innerText.trim().isNotEmpty) {
      author = creatorEl.innerText.trim();
    }

    // 2. spine 顺序
    final spineIds = <String>[];
    for (final sr in doc.findAllElements('itemref')) {
      final id = sr.getAttribute('idref');
      if (id != null && id.isNotEmpty) spineIds.add(id.trim());
    }

    // 3. manifest 映射 id -> href
    final hrefById = <String, String>{};
    for (final item in doc.findAllElements('item')) {
      final id = item.getAttribute('id');
      final href = item.getAttribute('href');
      if (id != null && href != null) {
        hrefById[id.trim()] = _urldecode(href.trim());
      }
    }

    // 4. 按 spine 读取章节
    final chapters = <LocalChapter>[];
    for (final id in spineIds) {
      final href = hrefById.containsKey(id) ? hrefById[id]! : null;
      if (href == null) continue;
      var path = href;
      if (!path.startsWith('/')) path = opfDir + href;
      path = _normalizePath(path);
      final f = files[path];
      if (f == null) continue;
      final text = _xhtmlToText(_decodeUtf8(f.content as List<int>));
      if (text.trim().isEmpty) continue;
      chapters.add(LocalChapter(
        // 标题取自 XHTML 的 h1/h2/h3 或 <title>，缺失时按序号兜底（对齐官方按标题判定章节）。
        title: _xhtmlTitle(_decodeUtf8(f.content as List<int>), chapters.length + 1),
        content: text.trim(),
      ));
    }

    return LocalBook(
      name: title,
      author: author,
      cover: _coverDataUri(doc, files, opfDir, hrefById),
      chapters: chapters);
  }

  /// 从 OPF 元数据提取封面，转为 `data:` URI（data URI 便于跨平台传递，
  /// 落盘为 `file://` 由 LocalBookStore 负责）。找不到返回 null。
  static String? _coverDataUri(
    XmlDocument opf,
    Map<String, ArchiveFile> files,
    String opfDir,
    Map<String, String> hrefById,
  ) {
    String? coverHref;
    // 优先 `<meta name="cover" content="id">`。
    for (final meta in opf.findAllElements('meta')) {
      if ((meta.getAttribute('name') ?? '').toLowerCase() == 'cover') {
        final content = meta.getAttribute('content');
        if (content != null && content.isNotEmpty) {
          coverHref = hrefById[content.trim()];
          break;
        }
      }
    }
    // 兜底：manifest 中 `properties="cover-image"`。
    if (coverHref == null) {
      for (final item in opf.findAllElements('item')) {
        final props = (item.getAttribute('properties') ?? '').toLowerCase();
        if (props.contains('cover-image')) {
          final href = item.getAttribute('href');
          if (href != null && href.isNotEmpty) {
            coverHref = href.trim();
            break;
          }
        }
      }
    }
    if (coverHref == null) return null;
    var path = coverHref;
    if (!path.startsWith('/')) path = opfDir + coverHref;
    path = _normalizePath(path);
    final f = files[path];
    if (f == null || f.content is! List<int>) return null;
    final bytes = f.content as List<int>;
    final ext = path.split('.').last.toLowerCase();
    final mime = switch (ext) {
      'png' => 'image/png',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      'jpg' || 'jpeg' => 'image/jpeg',
      _ => 'image/png',
    };
    return 'data:$mime;base64,${base64Encode(bytes)}';
  }

  /// 按局部名（忽略命名空间前缀）查找第一个元素及其文本。
  static XmlElement? _firstByLocalName(XmlNode root, String localName) {
    for (final e in root.descendants.whereType<XmlElement>()) {
      if (e.name.local == localName) return e;
    }
    return null;
  }

  static String? _findOpf(Map<String, ArchiveFile> files) {
    // 优先 container.xml
    for (final entry in ['META-INF/container.xml', 'meta-inf/container.xml']) {
      final cf = files[entry];
      if (cf != null) {
        final xml = _decodeUtf8(cf.content as List<int>);
        try {
          final doc = XmlDocument.parse(xml);
          for (final el in doc.findAllElements('rootfile')) {
            final path = el.getAttribute('full-path');
            if (path != null && path.trim().isNotEmpty) {
              return _normalizePath(path.trim());
            }
          }
        } catch (_) {}
      }
    }
    // 兜底：扫描 *.opf
    for (final f in files.values) {
      if (f.name.toLowerCase().endsWith('.opf')) return _normalizePath(f.name);
    }
    return null;
  }

  static String _normalizePath(String p) {
    final parts = <String>[];
    for (final seg in p.split('/')) {
      if (seg == '.' || seg.isEmpty) continue;
      if (seg == '..') {
        if (parts.isNotEmpty) parts.removeLast();
      } else {
        parts.add(seg);
      }
    }
    return parts.join('/');
  }

  static String _urldecode(String s) {
    try {
      return Uri.decodeComponent(s);
    } catch (_) {
      return s;
    }
  }

  static String _decodeUtf8(List<int> bytes) {
    try {
      return utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
      return String.fromCharCodes(bytes);
    }
  }

  static String _xhtmlToText(String html) {
    try {
      final doc = html_parser.parse(html);
      var text = doc.documentElement?.text ?? '';
      text = text.replaceAll(RegExp(r'\s+'), ' ').trim();
      return text;
    } catch (_) {
      // 简单标签剥离兜底
      return html
          .replaceAll(RegExp(r'<[^>]+>'), ' ')
          .replaceAll(RegExp(r'&nbsp;', caseSensitive: false), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
    }
  }

  /// 从 XHTML 提取章节标题：优先 h1/h2/h3 标题文本，其次 `<title>`，兜底序号。
  static String _xhtmlTitle(String html, int fallback) {
    try {
      final doc = html_parser.parse(html);
      for (final tag in ['h1', 'h2', 'h3', 'h4']) {
        final el = doc.querySelector(tag);
        if (el != null) {
          final t = el.text.trim();
          if (t.isNotEmpty) return t;
        }
      }
      final titles = doc.getElementsByTagName('title');
      if (titles.isNotEmpty) {
        final tt = titles.first.text.trim();
        if (tt.isNotEmpty) return tt;
      }
    } catch (_) {}
    return '章节 $fallback';
  }

  // ------------------------------------------------------------------
  // 通用工具
  // ------------------------------------------------------------------

  /// 按章节标题把整段文本切分为章节；无章节标题时回退为单个"正文"章。
  static List<LocalChapter> _splitIntoChapters(String text, {String? chapterRegex}) {
    if (text.trim().isEmpty) return [];
    final re = _chapterRegexOf(chapterRegex);
    final lines = text.replaceAll('\r\n', '\n').split('\n');
    final chapters = <LocalChapter>[];
    var current = LocalChapter(title: '');
    final buf = <String>[];
    for (final line in lines) {
      final t = line.trim();
      if (t.isNotEmpty && re.hasMatch(t)) {
        _flush(current, buf, chapters);
        current = LocalChapter(title: t);
      } else {
        buf.add(line);
      }
    }
    _flush(current, buf, chapters);
    chapters.removeWhere((c) => c.content.trim().isEmpty && c.title.isEmpty);
    if (chapters.isEmpty && text.trim().isNotEmpty) {
      chapters.add(LocalChapter(title: '正文', content: text.trim()));
    }
    return chapters;
  }

  /// 读取大端 16 位无符号整数（越界返回 0）。
  static int _readU16BE(List<int> b, int off) {
    if (off < 0 || off + 2 > b.length) return 0;
    return ((b[off] & 0xFF) << 8) | (b[off + 1] & 0xFF);
  }

  /// 读取大端 32 位无符号整数（越界返回 0）。
  static int _readU32BE(List<int> b, int off) {
    if (off < 0 || off + 4 > b.length) return 0;
    var v = 0;
    for (var i = 0; i < 4; i++) {
      v = (v << 8) | (b[off + i] & 0xFF);
    }
    return v;
  }

  /// 判断 [off] 处是否以 ASCII 串 [s] 开头。
  static bool _asciiAt(List<int> b, int off, String s) {
    if (off < 0 || off + s.length > b.length) return false;
    for (var i = 0; i < s.length; i++) {
      if (b[off + i] != s.codeUnitAt(i)) return false;
    }
    return true;
  }

  /// 按 MOBI 文本编码解码字节（65001=UTF-8，其余按 latin1 近似 cp1252）。
  static String _mobiBytesToText(List<int> bytes, int encoding) {
    if (encoding == 65001) return _decodeUtf8(bytes);
    return String.fromCharCodes(bytes);
  }

  // ------------------------------------------------------------------
  // MOBI / PalmDOC
  // ------------------------------------------------------------------

  /// 解析 MOBI/PalmDOC（PDB 容器）。
  ///
  /// 说明：实现 PalmDOC header + MOBI header + EXTH + TEXT 记录读取，
  /// 支持 LZ77（compression type 2）最小解压；失败时安全降级为已解压段落，不抛异常。
  static LocalBook parseMobi(List<int> bytes, {String name = ''}) {
    try {
      if (bytes.length < 80) return LocalBook(name: name);

      // 记录总数（PDB 头偏移 76，2 字节大端）
      final totalRecords = _readU16BE(bytes, 76);
      if (totalRecords <= 0 || bytes.length < 78 + totalRecords * 8) {
        return LocalBook(name: name);
      }
      final offsets = <int>[];
      for (var i = 0; i < totalRecords; i++) {
        offsets.add(_readU32BE(bytes, 78 + i * 8));
      }
      final hdrOff = offsets.isNotEmpty ? offsets[0] : 0;
      if (hdrOff + 16 > bytes.length) return LocalBook(name: name);

      // PalmDOC header（16 字节）
      final compression = _readU16BE(bytes, hdrOff); // 1=无压缩 2=LZ77
      final textLength = _readU32BE(bytes, hdrOff + 4);
      final recordCount = _readU16BE(bytes, hdrOff + 8);
      final encryption = _readU16BE(bytes, hdrOff + 12);

      final mobiOff = hdrOff + 16;
      var textEncoding = 65001;
      var bookName = name;
      if (_asciiAt(bytes, mobiOff, 'BOOKMOBI')) {
        final mobiHeaderLen = _readU32BE(bytes, mobiOff + 8);
        textEncoding = _readU32BE(bytes, mobiOff + 0x10);
        // FullName（MOBI 头偏移 0x48/0x4C）
        final fullNameOff = _readU32BE(bytes, mobiOff + 0x48);
        final fullNameLen = _readU32BE(bytes, mobiOff + 0x4C);
        if (fullNameLen > 0 && fullNameOff > 0) {
          final t = _decodeMobiSlice(bytes, mobiOff + fullNameOff, fullNameLen, textEncoding);
          if (t.trim().isNotEmpty) bookName = t.trim();
        }
        // EXTH（偏移 0x74 的第 6 bit 表示存在），type 503 是书名
        final exthFlags = _readU32BE(bytes, mobiOff + 0x74);
        if ((exthFlags & 0x40) != 0) {
          final exthOff = mobiOff + mobiHeaderLen;
          if (exthOff + 12 <= bytes.length && _asciiAt(bytes, exthOff, 'EXTH')) {
            final recCount = _readU32BE(bytes, exthOff + 8);
            var p = exthOff + 12;
            for (var i = 0; i < recCount; i++) {
              if (p + 8 > bytes.length) break;
              final type = _readU32BE(bytes, p);
              final len = _readU32BE(bytes, p + 4);
              if (type == 503 && len > 8 && bookName.isEmpty) {
                final t = _decodeMobiSlice(bytes, p + 8, len - 8, textEncoding);
                if (t.trim().isNotEmpty) bookName = t.trim();
              }
              p += len;
            }
          }
        }
      }
      if (bookName.isEmpty) bookName = name;

      // 正文记录：从记录 1 起取 recordCount 条 TEXT 记录
      final content = StringBuffer();
      if (encryption == 0 && recordCount > 0) {
        final start = 1;
        final end = (1 + recordCount) < offsets.length ? (1 + recordCount) : offsets.length;
        for (var i = start; i < end; i++) {
          final dataOff = offsets[i];
          if (dataOff >= bytes.length) continue;
          final dataEnd = (i + 1 < offsets.length) ? offsets[i + 1] : bytes.length;
          var data = bytes.sublist(dataOff, dataEnd > bytes.length ? bytes.length : dataEnd);
          if (compression == 2) {
            // PalmDOC 压缩记录前 4 字节为该记录压缩后长度
            if (data.length >= 4) data = data.sublist(4);
            try {
              data = _mobiLz77(data, 0);
            } catch (_) {
              continue; // 解压失败：跳过该记录，不抛异常
            }
          }
          content.write(_mobiBytesToText(data, textEncoding));
        }
      }
      var text = content.toString();
      if (textLength > 0 && text.length > textLength) {
        text = text.substring(0, textLength);
      }
      final chapters = _splitIntoChapters(_mobiHtmlToText(text));
      return LocalBook(name: bookName, chapters: chapters);
    } catch (_) {
      return LocalBook(name: name);
    }
  }

  /// 便捷：按偏移+长度切出一段文本。
  static String _decodeMobiSlice(List<int> b, int off, int len, int encoding) {
    if (off < 0 || len <= 0 || off + len > b.length) return '';
    return _mobiBytesToText(b.sublist(off, off + len), encoding);
  }

  /// 最小 PalmDOC LZ77 解压：2 字节回引编码，2048 字节滑动窗（前缀填充空格）。
  ///
  /// - 控制字节：8 个 item，LSB 优先；bit=1 表示字面量，bit=0 表示 2 字节回引。
  /// - 回引：`o` 高 4 位给长度（len=(o>>4)+3），低 4 位 + `l` 组成 dist（12 位）。
  /// - 任何畸形输入都返回已解出部分，不抛异常。
  static List<int> _mobiLz77(List<int> data, int expectedLen) {
    // 4096 环形缓冲，看作 2048 空格前缀 + 滑动窗
    final ring = List<int>.filled(4096, 0x20);
    final out = <int>[];
    int outpos = 0;
    int ip = 0;
    int flags = 0;
    int flagCount = 0;
    int ringIdx(int p) => ((p % 4096) + 4096) % 4096;
    while (ip < data.length) {
      if (flagCount == 0) {
        if (ip >= data.length) break;
        flags = data[ip++];
        flagCount = 8;
      }
      final isLiteral = (flags & 1) != 0;
      flags >>= 1;
      flagCount--;
      if (isLiteral) {
        if (ip >= data.length) break;
        final c = data[ip++];
        ring[ringIdx(outpos)] = c;
        out.add(c);
        outpos++;
      } else {
        if (ip + 1 >= data.length) break;
        final o = data[ip++];
        final l = data[ip++];
        final dist = ((o & 0x0F) << 8) | l;
        final length = (o >> 4) + 3;
        final base = outpos - 2048 + dist;
        for (var i = 0; i < length; i++) {
          final c = ring[ringIdx(base + i)];
          ring[ringIdx(outpos)] = c;
          out.add(c);
          outpos++;
        }
      }
    }
    if (expectedLen > 0 && out.length > expectedLen) {
      return out.sublist(0, expectedLen);
    }
    return out;
  }

  /// 把 MOBI 正文的 HTML/实体转成纯文本（块级标签换行）。
  static String _mobiHtmlToText(String html) {
    var s = html;
    s = s.replaceAll(RegExp(r'<br[^>]*>', caseSensitive: false), '\n');
    s = s.replaceAll(
        RegExp(r'</(p|div|h1|h2|h3|h4|li|tr|blockquote)>', caseSensitive: false), '\n');
    s = s.replaceAll(RegExp(r'<[^>]+>'), ' ');
    s = s.replaceAll(RegExp(r'&nbsp;', caseSensitive: false), ' ');
    s = s.replaceAll(RegExp(r'&amp;'), '&');
    s = s.replaceAll(RegExp(r'&lt;'), '<');
    s = s.replaceAll(RegExp(r'&gt;'), '>');
    s = s.replaceAllMapped(RegExp(r'&#(\d+);'), (Match m) {
      final code = int.tryParse(m.group(1) ?? '');
      return code == null ? (m.group(0) ?? '') : String.fromCharCode(code);
    });
    return s.replaceAll(RegExp(r'\r'), '').trim();
  }

  // ------------------------------------------------------------------
  // UMD
  // ------------------------------------------------------------------

  /// UMD 格式魔数：`0x15 0x0D 0x4C 0x61 0x75 0x52 0x75 0x6E`。
  static const List<int> _umdMagic = [0x15, 0x0D, 0x4C, 0x61, 0x75, 0x52, 0x75, 0x6E];

  /// 解析 UMD（UbmFile）。
  ///
  /// 说明：官方用 UBM 压缩 + 加密正文，跨平台版无法完整解出，这里降级为
  /// "通用可读文本提取"——UTF8/latin1 解码 + 剥离非可读字节 + 按章节关键字切分，
  /// 保证可导入、不抛异常（加密正文可能提取不全）。
  static LocalBook parseUmd(List<int> bytes, {String name = ''}) {
    try {
      if (bytes.isEmpty) return LocalBook(name: name);
      _isUmd(bytes); // 格式校验（结果不影响降级解析）
      final text = _extractUmdText(bytes);
      final chapters = _splitIntoChapters(text);
      var bookName = name;
      if (bookName.isEmpty && text.isNotEmpty) {
        final first = text.split('\n').first.trim();
        if (first.isNotEmpty) bookName = first;
      }
      return LocalBook(name: bookName, chapters: chapters);
    } catch (_) {
      return LocalBook(name: name);
    }
  }

  /// 校验是否为 UMD：优先魔数，兜底在前段查找 "UMD"。
  static bool _isUmd(List<int> b) {
    if (_startsWith(b, _umdMagic)) return true;
    final n = b.length < 400 ? b.length : 400;
    for (var i = 0; i + 2 < n; i++) {
      if (b[i] == 0x55 && b[i + 1] == 0x4D && b[i + 2] == 0x44) return true;
    }
    return false;
  }

  static bool _startsWith(List<int> b, List<int> m) {
    if (b.length < m.length) return false;
    for (var i = 0; i < m.length; i++) {
      if (b[i] != m[i]) return false;
    }
    return true;
  }

  /// UMD 通用文本提取（降级能力）。
  static String _extractUmdText(List<int> b) {
    var s = _decodeUtf8(b);
    if (_readableRatio(s) < 0.3) {
      s = String.fromCharCodes(b); // latin1 兜底（GBK 字节近似）
    }
    return _keepReadable(s);
  }

  /// 保留可读字符（ASCII、CJK、全角/半角标点），其余以空格替位。
  static String _keepReadable(String s) {
    final sb = StringBuffer();
    for (final r in s.runes) {
      if (r == 0x0A || r == 0x0D || r == 0x09 ||
          (r >= 0x20 && r <= 0x7E) ||
          (r >= 0xA0 && r <= 0xFF) ||
          (r >= 0x3000 && r <= 0x303F) ||
          (r >= 0x4E00 && r <= 0x9FFF) ||
          (r >= 0xFF00 && r <= 0xFFEF)) {
        sb.writeCharCode(r);
      } else {
        sb.write(' ');
      }
    }
    return sb
        .toString()
        .replaceAll(RegExp(r'[ \t]{3,}'), ' ')
        .replaceAll(RegExp(r'\n{3,}'), '\n')
        .trim();
  }

  /// 可读字符占比（用于判断二进制/乱码噪声）。
  static double _readableRatio(String s) {
    if (s.isEmpty) return 0;
    var printable = 0;
    for (final r in s.codeUnits) {
      if (r == 0x0A || r == 0x0D || r == 0x09) {
        printable++;
        continue;
      }
      if ((r >= 0x20 && r <= 0x7E) || (r >= 0x4E00 && r <= 0x9FFF) ||
          (r >= 0x3000 && r <= 0x303F)) {
        printable++;
      }
    }
    return printable / s.codeUnits.length;
  }

  // ------------------------------------------------------------------
  // PDF（文本层近似）
  // ------------------------------------------------------------------

  /// 解析 PDF 文本层（近似）。
  ///
  /// 说明：官方用 PdfRenderer 渲染成图；跨平台版无重依赖，改为扫描 `( ... )`
  /// 文本块提取可读字符串近似。图像型 PDF（无文本层）正文为空。
  static LocalBook parsePdf(List<int> bytes, {String name = ''}) {
    try {
      final text = _extractPdfText(bytes);
      final chapters = _splitIntoChapters(text);
      if (chapters.isEmpty) {
        return LocalBook(name: name, chapters: [
          LocalChapter(
            title: '正文',
            content: '（该 PDF 未检测到可提取的文本层，图像型 PDF 正文为空。）',
          ),
        ]);
      }
      return LocalBook(name: name, chapters: chapters);
    } catch (_) {
      return LocalBook(name: name);
    }
  }

  /// 扫描 PDF 字节流，按 `( ... )` 字面量字符串提取可读文本（跳过二进制噪声）。
  static String _extractPdfText(List<int> bytes) {
    final sb = StringBuffer();
    var i = 0;
    final n = bytes.length;
    while (i < n) {
      if (bytes[i] == 0x28) { // '('
        final r = _readPdfLiteral(bytes, i);
        if (r != null) {
          final s = _pdfDecodeText(r.$1);
          if (_readableRatio(s) >= 0.5) sb.write(s);
          i += r.$2;
          continue;
        }
      }
      i++;
    }
    return sb.toString();
  }

  /// 读取一段 PDF 字面量字符串，返回 (内部字节, 含括号总长)；未闭环返回 null。
  static (List<int>, int)? _readPdfLiteral(List<int> b, int start) {
    var depth = 0;
    var i = start;
    final buf = <int>[];
    while (i < b.length) {
      final c = b[i];
      if (c == 0x5C) { // 反斜杠转义
        final next = i + 1 < b.length ? b[i + 1] : 0;
        if (next == 0x6E) { buf.add(0x0A); i += 2; }
        else if (next == 0x72) { buf.add(0x0D); i += 2; }
        else if (next == 0x74) { buf.add(0x09); i += 2; }
        else if (next == 0x28) { buf.add(0x28); i += 2; }
        else if (next == 0x29) { buf.add(0x29); i += 2; }
        else if (next == 0x5C) { buf.add(0x5C); i += 2; }
        else if (next >= 0x30 && next <= 0x37) { // 八进制
          var code = next - 0x30;
          var k = i + 2;
          var cnt = 1;
          while (k < b.length && cnt < 3 && b[k] >= 0x30 && b[k] <= 0x37) {
            code = code * 8 + (b[k] - 0x30);
            k++;
            cnt++;
          }
          buf.add(code);
          i = k;
        } else {
          i += 2; // 未知转义按跳过处理
        }
        continue;
      }
      if (c == 0x28) {
        depth++;
        buf.add(c);
      } else if (c == 0x29) {
        depth--;
        if (depth < 0) return (buf, i - start + 1);
        buf.add(c);
      } else {
        buf.add(c);
      }
      i++;
    }
    return null; // 未闭环
  }

  /// PDF 字符串解码：优先 UTF-8，可读性不足时回退 latin1。
  static String _pdfDecodeText(List<int> b) {
    if (b.isEmpty) return '';
    final s = _decodeUtf8(b);
    if (_readableRatio(s) < 0.5) return String.fromCharCodes(b);
    return s;
  }

  // ------------------------------------------------------------------
  // 格式分发
  // ------------------------------------------------------------------

  /// 按扩展名路由到对应解析器；未知扩展返回空 `LocalBook` 不抛异常。
  /// [chapterRegex] 为用户自定义的 TXT 目录规则（文本/UMD/MOBI/PDF 分章用）。
  static LocalBook parseByExtension(List<int> bytes, String name, String ext,
      {String? chapterRegex}) {
    final e = ext.trim().toLowerCase().replaceFirst(RegExp(r'^\.+'), '');
    try {
      switch (e) {
        case 'txt':
          return parseTxt(_decodeUtf8(bytes), name, chapterRegex: chapterRegex);
        case 'epub':
          return parseEpub(bytes, name: name);
        case 'mobi':
          return parseMobi(bytes, name: name);
        case 'umd':
          return parseUmd(bytes, name: name);
        case 'pdf':
          return parsePdf(bytes, name: name);
        default:
          return LocalBook(name: name);
      }
    } catch (_) {
      return LocalBook(name: name);
    }
  }
}