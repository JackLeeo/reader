// 换源服务 - 同名书跨书源搜索
import 'package:flutter/foundation.dart';

import '../models/book.dart';
import '../utils/log.dart';
import 'book_source_service.dart';
import 'reader_service.dart';

class SourceSwitchService extends ChangeNotifier {
  final ReaderService reader = ReaderService();
  final BookSourceService _bookSourceService;

  SourceSwitchService(this._bookSourceService);

  /// 在所有启用书源里搜同一本书名
  /// 返回去重后的候选书列表（不同源可能有同一本）
  Future<List<Book>> searchAcrossSources(String bookName,
      {int perSourcePageSize = 1}) async {
    if (bookName.trim().isEmpty) return [];
    final sources = _bookSourceService.enabledSources;
    if (sources.isEmpty) return [];

    Log.i('换源搜索: "$bookName" 启用源 ${sources.length} 个');
    final futures = sources
        .where((s) => s.searchUrl.isNotEmpty)
        .map((s) => reader.search(s, bookName, page: 1));
    final results = await Future.wait(futures, eagerError: false);

    final all = <Book>[];
    for (final r in results) {
      all.addAll(r.books);
    }
    return _dedupe(all);
  }

  /// 简单去重：相同 (name, author) 视为同一本
  List<Book> _dedupe(List<Book> books) {
    final seen = <String>{};
    final out = <Book>[];
    for (final b in books) {
      final key = '${b.name.trim()}|${b.author.trim()}';
      if (seen.add(key)) {
        out.add(b);
      }
    }
    return out;
  }
}
