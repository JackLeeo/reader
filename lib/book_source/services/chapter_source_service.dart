import '../models/book_source.dart';
import '../models/books.dart';
import 'book_service.dart';
import 'book_source_service.dart';
import 'switch_source_service.dart';

/// 换章节源候选（对齐官方 ChangeChapterSourceResultOptions）。
class ChapterSourceCandidate {
  const ChapterSourceCandidate({
    required this.origin,
    required this.source,
    required this.chapter,
    required this.bookUrl,
  });

  final String origin;
  final BookSource source;
  final BookChapter chapter;
  final String bookUrl;
}

/// 换章节源服务：当前章节在其它启用源中查找同名章节。
///
/// 流程：跨源搜书名 → 取该书源目录 → 按章节标题就近匹配 → 返回候选。
/// 选中后用 [loadContent] 直接用该书源拉该章节正文。
class ChapterSourceService {
  const ChapterSourceService();

  static final BookService _book = BookService();

  /// 在其它启用源中查找与 [chapterTitle] 匹配的章节。
  Future<List<ChapterSourceCandidate>> findCandidates(
    Book book,
    String chapterTitle, {
    String? excludeOrigin,
  }) async {
    if (book.name.trim().isEmpty) return const [];
    final sources = BookSourceService.instance.enabledSources
        .where((s) => s.searchUrl != null && s.searchUrl!.trim().isNotEmpty)
        .where((s) => s.bookSourceName != excludeOrigin)
        .toList();

    final out = <ChapterSourceCandidate>[];
    for (final src in sources) {
      if (src.bookSourceType != 0) continue; // 仅文本源参与章节换源
      try {
        final hits = await const SwitchSourceService()
            .findSameBook(book, excludeOrigin: excludeOrigin);
        for (final h in hits) {
          if (h.origin != src.bookSourceName) continue;
          final tocBook = Book(
            name: book.name,
            author: book.author,
            bookUrl: h.bookUrl,
            tocUrl: h.bookUrl,
            origin: h.origin,
            sourceTag: h.origin,
          );
          final toc = await _book.getToc(tocBook, source: src);
          final matched = _matchChapter(toc, chapterTitle);
          if (matched != null) {
            out.add(ChapterSourceCandidate(
              origin: src.bookSourceName,
              source: src,
              chapter: matched,
              bookUrl: h.bookUrl,
            ));
            break;
          }
        }
      } catch (_) {
        continue;
      }
    }
    return out;
  }

  /// 用候选源加载章节正文。
  Future<BookContent> loadContent(Book book, ChapterSourceCandidate cand) async {
    final b = Book(
      name: book.name,
      author: book.author,
      bookUrl: book.bookUrl,
      tocUrl: book.tocUrl,
      origin: cand.origin,
      sourceTag: cand.source.bookSourceName,
    );
    return _book.getContent(cand.chapter, b, source: cand.source);
  }

  /// 在目录中按标题匹配：先精确（去空白/常见前缀），再包含。
  BookChapter? _matchChapter(List<BookChapter> toc, String title) {
    final t = title.trim();
    if (t.isEmpty) return null;
    // 归一：去空白与「第X章」差异（仅精确比较用）
    String norm(String s) =>
        s.replaceAll(RegExp(r'\s+'), '').replaceAll(RegExp(r'^第?[0-9零一二三四五六七八九十百千]+[章节卷]'), '');
    for (final c in toc) {
      if (c.isHeader) continue;
      if (c.title.trim() == t) return c;
    }
    for (final c in toc) {
      if (c.isHeader) continue;
      final ct = c.title.trim();
      if (norm(ct) == norm(t)) return c;
    }
    for (final c in toc) {
      if (c.isHeader) continue;
      final ct = c.title.trim();
      if ((ct.isNotEmpty && ct.contains(t)) || (ct.isNotEmpty && t.contains(ct))) {
        return c;
      }
    }
    return null;
  }
}