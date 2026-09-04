import 'package:flutter_test/flutter_test.dart';
import 'package:legado_flutter/book_source/services/tts_service.dart';

void main() {
  group('TtsEngine.buildUrl（HTTP TTS 文本占位与参数合并）', () {
    test('替换 {{speakText}} 并 URL 编码', () {
      final e = TtsEngine(name: 'x', url: 'https://tts.example/say?s={{speakText}}');
      final r = e.buildUrl('你好世界');
      expect(r,
          'https://tts.example/say?s=${Uri.encodeComponent('你好世界')}');
      expect(Uri.parse(r).queryParameters['s'], '你好世界');
    });

    test('替换 {speakText} / {key} 形式', () {
      expect(
        TtsEngine(name: 'x', url: 'https://a/b?q={speakText}').buildUrl('ab'),
        'https://a/b?q=ab',
      );
      expect(
        TtsEngine(name: 'x', url: 'https://a/b?q={key}').buildUrl('ab'),
        'https://a/b?q=ab',
      );
    });

    test('param 并入 query 且不覆盖已存在参数', () {
      final e = TtsEngine(
        name: 'x',
        url: 'https://a/b?t=1',
        param: 'v=2&t=9&w=3',
      );
      final r = e.buildUrl('hi');
      final q = Uri.parse(r).queryParameters;
      expect(q['v'], '2');
      expect(q['w'], '3');
      expect(q['t'], '1'); // 已存在的不覆盖
    });

    test('不含占位且无 param 时原样返回', () {
      final e = TtsEngine(name: 'x', url: 'https://a/b');
      expect(e.buildUrl('hi'), 'https://a/b');
    });
  });
}