// 文件说明：阅读页手动换源面板。按当前书名在所有启用书源中搜索同书，
// 列出可切换的书源（书名+作者一致优先），选中后回调目标源与书。
// 技术要点：并发书源搜索、跨源同书匹配、稳定排序。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/services/book_source_client.dart';
import 'package:xxread/book_sources/services/book_source_registry.dart';
import 'package:xxread/book_sources/services/source_concurrency.dart';
import 'package:xxread/utils/localization_extension.dart';

import 'widgets/sourced_book_widgets.dart';

/// 换源面板：返回用户选中的 (source, book)。
Future<SourcedBook?> showSourceSwitchSheet(
  BuildContext context, {
  required RegisteredBookSource currentSource,
  required String title,
  required String author,
  required BookSourceClient client,
}) {
  return showModalBottomSheet<SourcedBook>(
    context: context,
    isScrollControlled: true,
    builder: (_) => SourceSwitchSheet(
      currentSource: currentSource,
      title: title,
      author: author,
      client: client,
    ),
  );
}

class SourceSwitchSheet extends StatefulWidget {
  const SourceSwitchSheet({
    super.key,
    required this.currentSource,
    required this.title,
    required this.author,
    required this.client,
  });

  final RegisteredBookSource currentSource;
  final String title;
  final String author;
  final BookSourceClient client;

  @override
  State<SourceSwitchSheet> createState() => _SourceSwitchSheetState();
}

class _SourceSwitchSheetState extends State<SourceSwitchSheet> {
  static const int _searchConcurrency = 16;

  bool _searching = false;
  bool _loaded = false;
  List<SourcedBook> _candidates = const [];
  int _completed = 0;
  int _total = 0;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_search());
  }

  static String _normalize(String text) =>
      text.toLowerCase().replaceAll(RegExp(r'[\s\u3000]+'), '').trim();

  Future<void> _search() async {
    final generation = ++_generation;
    final registry = BookSourceRegistry();
    final sources = (await registry.loadRunnable())
        .where(
          (source) => source.enabled && source.id != widget.currentSource.id,
        )
        .toList(growable: false);
    if (!mounted || generation != _generation) return;
    setState(() {
      _searching = true;
      _loaded = false;
      _candidates = const [];
      _completed = 0;
      _total = sources.length;
    });

    final normalizedTitle = _normalize(widget.title);
    final normalizedAuthor = _normalize(widget.author);
    final matches = <SourcedBook>[];
    final limiter = BookSourceConcurrencyLimiter(_searchConcurrency);
    await Future.wait(
      sources.map((source) {
        return limiter.run(() async {
          SourcedBook? match;
          try {
            final page = await widget.client
                .search(source, widget.title)
                .timeout(const Duration(seconds: 20));
            for (final book in page.items) {
              if (_normalize(book.title) != normalizedTitle) continue;
              match = SourcedBook(source: source, book: book);
              break;
            }
          } catch (_) {
            // 单源失败不影响其它源的候选收集。
          }
          if (match != null) matches.add(match);
          if (!mounted || generation != _generation) return;
          setState(() => _completed++);
        });
      }),
    );
    if (!mounted || generation != _generation) return;
    // 书名+作者一致的源排前面；同组按源名稳定排序。
    matches.sort((a, b) {
      final authorMatch =
          (_normalize(a.book.author) == normalizedAuthor ? 0 : 1).compareTo(
            _normalize(b.book.author) == normalizedAuthor ? 0 : 1,
          );
      if (authorMatch != 0) return authorMatch;
      return a.source.name.compareTo(b.source.name);
    });
    setState(() {
      _candidates = matches;
      _searching = false;
      _loaded = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.72,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.readerSwitchSource,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${widget.title}'
                          '${widget.author.isEmpty ? '' : ' · ${widget.author}'}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: scheme.onSurfaceVariant,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_loaded)
                    IconButton(
                      tooltip: context.l10n.retry,
                      onPressed: _searching ? null : () => unawaited(_search()),
                      icon: const Icon(Icons.refresh_rounded),
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(child: _buildBody(context)),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (_searching && _candidates.isEmpty) {
      final progress = _total > 0 ? _completed / _total : null;
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(value: progress),
            const SizedBox(height: 16),
            Text(
              '${context.l10n.switchSourceSearching} $_completed/$_total',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      );
    }
    if (_candidates.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.search_off_rounded,
                size: 36,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.55),
              ),
              const SizedBox(height: 10),
              Text(
                context.l10n.switchSourceNoResults,
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      itemCount: _candidates.length + (_searching ? 1 : 0),
      separatorBuilder: (_, _) => const SizedBox(height: 6),
      itemBuilder: (context, index) {
        if (index == _candidates.length) {
          return const Padding(
            padding: EdgeInsets.all(12),
            child: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }
        final candidate = _candidates[index];
        final authorMatch =
            _normalize(candidate.book.author) == _normalize(widget.author);
        return ListTile(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          leading: Icon(
            authorMatch
                ? Icons.check_circle_outline_rounded
                : Icons.book_outlined,
            color: authorMatch ? scheme.primary : scheme.onSurfaceVariant,
          ),
          title: Text(
            candidate.source.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            candidate.book.author.isEmpty
                ? candidate.book.title
                : candidate.book.author,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () => Navigator.of(context).pop(candidate),
        );
      },
    );
  }
}
