/// 一次正文内搜索命中。
class ContentHit {
  ContentHit({
    required this.chapterIndex,
    required this.chapterTitle,
    required this.position,
    required this.snippet,
  });

  final int chapterIndex;
  final String chapterTitle;
  final int position;
  final String snippet;
}

/// 正文内搜索服务（对齐官方「正文内搜索 / 段评搜索」）。
///
/// 在书中各章节全文里搜索关键字，返回命中的「章节 + 位置 + 上下文片段」。
/// 大小写不敏感；命中片段默认取关键字的上下文。空关键字 / 无命中返回空列表，不抛异常。
class ContentSearchService {
  ContentSearchService._();

  static final ContentSearchService instance = ContentSearchService._();

  /// 命中片段在关键字前后各保留的字数。
  static const int defaultContext = 20;

  /// 在 [chapters]（每项含 title、content）全文里搜索 [keyword]。
  ///
  /// 返回按「章节序号 + 位置」排序的命中列表。snippet 为命中词及前后各
  /// [context] 个字（默认 20）。
  List<ContentHit> search({
    required List<({String title, String content})> chapters,
    required String keyword,
    int context = defaultContext,
  }) {
    final kw = keyword.trim();
    if (kw.isEmpty || chapters.isEmpty) return const [];

    final hits = <ContentHit>[];
    // 大小写不敏感匹配。
    final re = RegExp(RegExp.escape(kw), caseSensitive: false);
    for (var i = 0; i < chapters.length; i++) {
      final ch = chapters[i];
      final content = ch.content;
      if (content.isEmpty) continue;
      for (final m in re.allMatches(content)) {
        final start = m.start;
        final snippetStart = start - context < 0 ? 0 : start - context;
        final snippetEnd = m.end + context > content.length ? content.length : m.end + context;
        hits.add(ContentHit(
          chapterIndex: i,
          chapterTitle: ch.title,
          position: start,
          snippet: content.substring(snippetStart, snippetEnd),
        ));
      }
    }
    hits.sort((a, b) {
      if (a.chapterIndex != b.chapterIndex) return a.chapterIndex.compareTo(b.chapterIndex);
      return a.position.compareTo(b.position);
    });
    return hits;
  }
}