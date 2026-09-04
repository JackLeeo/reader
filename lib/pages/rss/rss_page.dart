import 'package:flutter/material.dart';

import '../../book_source/services/rss_service.dart';
import '../browser/browser_page.dart';
import '../tools/rss_rule_debugger_page.dart';

/// RSS 页。对应官方 fragment_rss。
///
/// 订阅源管理 + 文章列表 + 阅读（内置链接打开由浏览器处理）。基础版先做
/// “添加订阅源 → 抓取展示文章列表”，完整 OPML 导入/收藏阶段6补充。
class RssPage extends StatefulWidget {
  const RssPage({super.key});

  @override
  State<RssPage> createState() => _RssPageState();
}

class _RssPageState extends State<RssPage> {
  final Map<String, RssFeed> _feeds = {};
  bool _loading = false;
  String? _error;
  bool _showFavs = false;

  @override
  void initState() {
    super.initState();
    RssService.instance.init();
    _loadAll();
  }

  Future<void> _loadAll() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      for (final url in RssService.instance.urls) {
        final feed = await RssService.instance.fetch(url);
        _feeds[url] = feed;
      }
    } catch (e) {
      _error = '加载失败：$e';
    }
    if (!mounted) return;
    setState(() => _loading = false);
  }

  Future<void> _addFeed() async {
    final controller = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('添加订阅源'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: 'https://.../rss.xml',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('添加'),
          ),
        ],
      ),
    );
    if (url == null || url.trim().isEmpty || !mounted) return;
    RssService.instance.addFeed(url);
    await _loadAll();
  }

  // 当前视图下某源要展示的条目（收藏模式只显示已收藏）。
  List<RssItem> _visibleItems(RssFeed feed) {
    if (!_showFavs) return feed.items.take(20).toList();
    return feed.items
        .where((it) => RssService.instance.isFavorite(feed.url, it))
        .take(20)
        .toList();
  }

  Future<void> _removeFeed(String url) async {
    RssService.instance.removeFeed(url);
    _feeds.remove(url);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _feeds.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('RSS')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    final all = _feeds.values.toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('RSS'),
        actions: [
          IconButton(
            icon: Icon(_showFavs ? Icons.star : Icons.star_border),
            tooltip: _showFavs ? '显示全部' : '只看收藏',
            onPressed: () => setState(() => _showFavs = !_showFavs),
          ),
          IconButton(
            icon: const Icon(Icons.edit),
            tooltip: '刷新',
            onPressed: _loadAll,
          ),
          IconButton(
            icon: const Icon(Icons.bug_report_outlined),
            tooltip: 'RSS 规则调试器',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                  builder: (_) => const RssRuleDebuggerPage()),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addFeed,
        icon: const Icon(Icons.rss_feed),
        label: const Text('添加订阅'),
      ),
      body: all.isEmpty
          ? _buildEmpty()
          : ListView(
              children: [
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(_error!,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error)),
                  ),
                for (final feed in all) ...[
                  _FeedHeader(feed: feed, onRemove: () => _removeFeed(feed.url)),
                  for (final item in _visibleItems(feed))
                    _RssItemTile(
                      item: item,
                      feed: feed,
                      onToggleFav: () => setState(() =>
                          RssService.instance.toggleFavorite(feed.url, item)),
                    ),
                  if (!_showFavs && feed.items.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                      child: Text('（该源无文章）'),
                    ),
                ],
              ],
            ),
    );
  }

  Widget _buildEmpty() => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.rss_feed, size: 64),
            const SizedBox(height: 12),
            const Text('暂无订阅源\n点击右下角“添加订阅”'),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _addFeed,
              icon: const Icon(Icons.rss_feed),
              label: const Text('添加订阅'),
            ),
          ],
        ),
      );
}

class _FeedHeader extends StatelessWidget {
  const _FeedHeader({required this.feed, required this.onRemove});

  final RssFeed feed;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(
        feed.title.isEmpty ? feed.url : feed.title,
        style: Theme.of(context)
            .textTheme
            .titleSmall
            ?.copyWith(color: Theme.of(context).colorScheme.primary),
      ),
      subtitle: Text('${feed.items.length} 篇文章'),
      trailing: PopupMenuButton<String>(
        onSelected: (_) => onRemove(),
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'del', child: Text('删除订阅')),
        ],
      ),
    );
  }
}

class _RssItemTile extends StatelessWidget {
  const _RssItemTile({
    required this.item,
    required this.feed,
    required this.onToggleFav,
  });

  final RssItem item;
  final RssFeed feed;
  final VoidCallback onToggleFav;

  @override
  Widget build(BuildContext context) {
    final fav = RssService.instance.isFavorite(feed.url, item);
    return ListTile(
      dense: true,
      leading: Icon(fav ? Icons.star : Icons.article_outlined,
          size: 20, color: fav ? Colors.amber : null),
      title: Text(item.title,
          maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        item.description.replaceAll(RegExp(r'<[^>]+>'), ' ').trim(),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: IconButton(
        icon: Icon(fav ? Icons.star : Icons.star_border, size: 20),
        tooltip: fav ? '取消收藏' : '收藏',
        onPressed: onToggleFav,
      ),
      onTap: () => _openItem(context),
    );
  }

  void _openItem(BuildContext context) {
    if (item.link.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('该文章无链接')),
      );
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => BrowserPage(url: item.link, title: item.title),
      ),
    );
  }
}