import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/services/core/source_diagnostic_logger.dart';

void main() {
  late SourceDiagnosticLogger logger;

  setUp(() {
    logger = SourceDiagnosticLogger.instance;
    logger.clear();
    logger.enabled = true;
  });

  group('SourceDiagnosticLogger', () {
    test('log adds entries in order', () {
      logger.log(
        sourceId: 'src-a',
        sourceName: 'Source A',
        op: SourceDiagOp.search,
        level: SourceDiagLevel.info,
        message: 'search("test") → 3 books',
      );
      logger.log(
        sourceId: 'src-a',
        sourceName: 'Source A',
        op: SourceDiagOp.content,
        level: SourceDiagLevel.error,
        message: 'empty content',
        details: 'hops=0 httpOk=true',
      );
      expect(logger.entries.length, 2);
      expect(logger.entries[0].op, SourceDiagOp.search);
      expect(logger.entries[1].level, SourceDiagLevel.error);
      expect(logger.entries[1].details, 'hops=0 httpOk=true');
    });

    test('disabled logger does not collect entries', () {
      logger.enabled = false;
      logger.log(
        sourceId: 'src-a',
        sourceName: 'Source A',
        op: SourceDiagOp.search,
        level: SourceDiagLevel.info,
        message: 'should be dropped',
      );
      expect(logger.entries, isEmpty);
    });

    test('clear empties all entries', () {
      logger.log(
        sourceId: 's1',
        sourceName: 'S1',
        op: SourceDiagOp.chapters,
        level: SourceDiagLevel.warn,
        message: 'warn msg',
      );
      expect(logger.entries.length, 1);
      logger.clear();
      expect(logger.entries, isEmpty);
    });

    test('entriesFor filters by sourceId', () {
      logger.log(
        sourceId: 'src-a',
        sourceName: 'A',
        op: SourceDiagOp.search,
        level: SourceDiagLevel.info,
        message: 'a1',
      );
      logger.log(
        sourceId: 'src-b',
        sourceName: 'B',
        op: SourceDiagOp.search,
        level: SourceDiagLevel.info,
        message: 'b1',
      );
      logger.log(
        sourceId: 'src-a',
        sourceName: 'A',
        op: SourceDiagOp.content,
        level: SourceDiagLevel.error,
        message: 'a2',
      );
      final aEntries = logger.entriesFor('src-a');
      expect(aEntries.length, 2);
      expect(aEntries.every((e) => e.sourceId == 'src-a'), isTrue);
    });

    test('ring buffer caps at maxEntries', () {
      for (var i = 0; i < 550; i++) {
        logger.log(
          sourceId: 's',
          sourceName: 'S',
          op: SourceDiagOp.search,
          level: SourceDiagLevel.info,
          message: 'entry $i',
        );
      }
      expect(logger.entries.length, 500);
      // 最早的条目被丢弃，保留最后的 500 条
      expect(logger.entries.first.message, 'entry 50');
      expect(logger.entries.last.message, 'entry 549');
    });

    test('exportToText produces structured markdown', () {
      logger.log(
        sourceId: 'src-a',
        sourceName: 'Source A',
        op: SourceDiagOp.search,
        level: SourceDiagLevel.info,
        message: 'search("test") → 3 books',
        details: 'searchUrl=http://example.com/search\nruleHits=5',
      );
      logger.log(
        sourceId: 'src-a',
        sourceName: 'Source A',
        op: SourceDiagOp.content,
        level: SourceDiagLevel.error,
        message: 'empty content',
        details: 'hops=2\nhttpOk=true\ncontentRule=@css:div.content',
      );

      final text = logger.exportToText();

      expect(text, contains('# Book Source Diagnostic Report'));
      expect(text, contains('Total entries: 2'));
      expect(text, contains('## Summary'));
      expect(text, contains('Search: 1 entries'));
      expect(text, contains('Content: 1 entries (1 errors)'));
      expect(text, contains('## Entries'));
      expect(text, contains('[INFO] search'));
      expect(text, contains('[ERROR] content'));
      expect(text, contains('search("test")'));
      expect(text, contains('empty content'));
      expect(text, contains('searchUrl=http://example.com/search'));
      expect(text, contains('contentRule=@css:div.content'));
    });

    test('exportToText with sourceId filter', () {
      logger.log(
        sourceId: 'src-a',
        sourceName: 'A',
        op: SourceDiagOp.search,
        level: SourceDiagLevel.info,
        message: 'from A',
      );
      logger.log(
        sourceId: 'src-b',
        sourceName: 'B',
        op: SourceDiagOp.search,
        level: SourceDiagLevel.info,
        message: 'from B',
      );

      final allText = logger.exportToText();
      expect(allText, contains('from A'));
      expect(allText, contains('from B'));

      final aText = logger.exportToText(sourceId: 'src-a');
      expect(aText, contains('from A'));
      expect(aText, isNot(contains('from B')));
    });

    test('exportToText on empty logger', () {
      final text = logger.exportToText();
      expect(text, contains('No diagnostic entries recorded.'));
    });

    test('toOneLiner produces concise format', () {
      logger.log(
        sourceId: 'src-a',
        sourceName: 'TestSource',
        op: SourceDiagOp.chapters,
        level: SourceDiagLevel.warn,
        message: 'fallback triggered',
      );
      final line = logger.entries.first.toOneLiner();
      expect(line, contains('[WARN]'));
      expect(line, contains('[chapters]'));
      expect(line, contains('TestSource'));
      expect(line, contains('fallback triggered'));
    });

    test('entries are unmodifiable', () {
      logger.log(
        sourceId: 's',
        sourceName: 'S',
        op: SourceDiagOp.search,
        level: SourceDiagLevel.info,
        message: 'test',
      );
      expect(() => logger.entries.clear(), throwsUnsupportedError);
    });

    test('all operation types can be logged', () {
      for (final op in SourceDiagOp.values) {
        logger.log(
          sourceId: 's',
          sourceName: 'S',
          op: op,
          level: SourceDiagLevel.info,
          message: 'op test',
        );
      }
      expect(logger.entries.length, SourceDiagOp.values.length);
    });
  });
}
