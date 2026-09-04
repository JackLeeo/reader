import '../models/books.dart';
import '../models/book_source.dart';
import 'book_service.dart';
import 'http_service.dart';
import 'search_service.dart';

/// 单个书源的（批量/单次）可用性校验结果。
class SourceCheckResult {
  const SourceCheckResult({
    required this.source,
    required this.httpOk,
    required this.statusCode,
    required this.httpError,
    required this.searchOk,
    required this.searchCount,
    required this.detailOk,
    required this.tocCount,
    required this.elapsedMs,
  });

  final BookSource source;

  /// 站点可访问（HTTP 2xx/3xx 或拉取成功）。
  final bool httpOk;

  /// HTTP 状态码；-1 表示未走到 HTTP（如缺搜索地址且超时）。
  final int statusCode;

  /// HTTP 层错误描述（空 = 无错误）。
  final String httpError;

  /// 搜索规则是否解析出结果。
  final bool searchOk;

  /// 搜索解析出的书籍数量。
  final int searchCount;

  /// 最新章节详情（ruleBookInfo + 目录）是否可用。
  final bool detailOk;

  /// 目录章节数量。
  final int tocCount;

  /// 耗时（毫秒）。
  final double elapsedMs;

  /// 综合判定：站点可访问且至少一条规则链路通过。
  bool get pass => httpOk && (searchOk || detailOk);
}

/// 书源校验器（对应官方「书源管理 → 校验」）。
///
/// 每条链路上限默认 15s 超时以防卡死，可设置 [timeout] 覆盖。
/// 校验流程：
/// 1. HTTP 可达性：用测试关键词请求 searchUrl（无则请求 bookSourceUrl）
/// 2. 若配置了搜索规则，执行一次搜索并统计解析出的书籍数
/// 3. 取第一篇结果做详情解析 + 目录拉取，验证 ruleBookInfo / ruleToc
class SourceValidator {
  const SourceValidator({this.timeout = const Duration(seconds: 15)});

  final Duration timeout;

  /// 测试关键词。
  static const String kTestKeyword = '校';

  /// 校验单个书源。
  Future<SourceCheckResult> check(BookSource source) async {
    final sw = Stopwatch()..start();

    // 1) HTTP 可达性
    final http = await _probeHttp(source);
    final httpOk = http.$1;
    final statusCode = http.$2;
    final httpError = http.$3;

    // 2) 搜索规则可用性
    var searchOk = false;
    var searchCount = 0;
    List<SearchBook>? hits;
    if ((source.ruleSearch?.bookList ?? '').trim().isNotEmpty &&
        (source.searchUrl ?? '').trim().isNotEmpty) {
      try {
        hits = await SearchService.instance
            .searchSource(source, kTestKeyword)
            .timeout(timeout);
        searchCount = hits.length;
        searchOk = searchCount > 0;
      } catch (_) {
        searchOk = false;
      }
    }

    // 3) 详情 + 目录
    var detailOk = false;
    var tocCount = 0;
    if (searchOk && hits!.isNotEmpty) {
      final target = hits.first;
      try {
        final book = await BookService().getBook(target).timeout(timeout);
        if (book != null && (book.bookUrl.trim().isNotEmpty)) {
          // 目录规则存在才拉目录，避免无目录源被误判。
          if ((source.ruleToc?.chapterList ?? '').trim().isNotEmpty) {
            final toc = await BookService().getToc(book).timeout(timeout);
            tocCount = toc.length;
            detailOk = tocCount > 0;
          } else {
            detailOk = true;
          }
        }
      } catch (_) {
        detailOk = false;
      }
    }

    return SourceCheckResult(
      source: source,
      httpOk: httpOk,
      statusCode: statusCode,
      httpError: httpError,
      searchOk: searchOk,
      searchCount: searchCount,
      detailOk: detailOk,
      tocCount: tocCount,
      elapsedMs: sw.elapsedMilliseconds.toDouble(),
    );
  }

  /// 返回 (ok, statusCode, error)。
  Future<(bool, int, String)> _probeHttp(BookSource source) async {
    final searchUrl = (source.searchUrl ?? '').trim();
    final baseUrl = source.bookSourceUrl.trim();
    final target = searchUrl.isNotEmpty
        ? SearchService.replaceKey(searchUrl, kTestKeyword)
        : baseUrl;
    if (target.isEmpty) return (false, -1, '无请求地址');
    try {
      final resp = await HttpService.instance
        .get(target, source: source)
        .timeout(timeout);
      return (resp.ok, resp.statusCode, resp.ok ? '' : 'HTTP ${resp.statusCode}');
    } catch (_) {
      return (false, -1, '请求超时或失败');
    }
  }
}

/// 批量校验书源，逐条回调进度。
class SourceValidatorBatch {
  final SourceValidator validator;
  SourceValidatorBatch({this.validator = const SourceValidator()});

  Future<void> run(
    List<BookSource> sources, {
    void Function(BookSource, SourceCheckResult)? onDone,
    void Function(int done, int total)? onProgress,
  }) async {
    final total = sources.length;
    for (var i = 0; i < total; i++) {
      final r = await validator.check(sources[i]);
      onDone?.call(sources[i], r);
      onProgress?.call(i + 1, total);
    }
  }
}