// 输出受影响源的 tocUrl / chapterUrl / content 规则样例。
// dart run tool/scan_url_syntax.dart samples
import 'dart:convert';
import 'dart:io';

void main(List<String> args) {
  final raw = File('assets/book_sources/perfect_sources.json')
      .readAsStringSync()
      .replaceFirst('\uFEFF', '');
  final sources = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
  final onlyAffected = args.contains('samples');
  var shown = 0;
  for (final s in sources) {
    final name = '${s['bookSourceName']}';
    final rb = s['ruleBookInfo'];
    final rt = s['ruleToc'];
    final rc = s['ruleContent'];
    final tocUrl = rb is Map && rb['tocUrl'] is String ? rb['tocUrl'] as String : '';
    final chapterUrl = rt is Map && rt['chapterUrl'] is String ? rt['chapterUrl'] as String : '';
    final content = rc is Map && rc['content'] is String ? rc['content'] as String : '';
    final interesting = tocUrl.contains('@get:') ||
        tocUrl.contains('{{') ||
        chapterUrl.contains('@get:') ||
        chapterUrl.contains('{{') ||
        jsonEncode(s).contains('@put:');
    if (!interesting) continue;
    if (!onlyAffected || shown < 15) {
      print('=== $name');
      if (tocUrl.isNotEmpty) print('  tocUrl: $tocUrl');
      if (chapterUrl.isNotEmpty) print('  chapterUrl: $chapterUrl');
      if (content.length < 300) print('  content: $content');
      shown++;
    }
  }
}
