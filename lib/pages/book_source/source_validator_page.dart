import 'package:flutter/material.dart';

import '../../book_source/models/book_source.dart';
import '../../book_source/services/book_source_service.dart';
import '../../book_source/services/source_validator.dart';

/// 书源校验页（对应官方「书源管理 → 校验」）。
///
/// 批量跑每个书源：HTTP 可达性 + 搜索规则 + 详情/目录规则，
/// 结果即时上屏（流式），顶部汇总通过/失败数。
class SourceValidatorPage extends StatefulWidget {
  const SourceValidatorPage({super.key});

  @override
  State<SourceValidatorPage> createState() => _SourceValidatorPageState();
}

class _SourceValidatorPageState extends State<SourceValidatorPage> {
  final Map<String, SourceCheckResult> _results = {};
  int _done = 0;
  int _total = 0;
  bool _running = false;

  @override
  void initState() {
    super.initState();
    if (mounted) _start();
  }

  Future<void> _start() async {
    final sources = List<BookSource>.of(BookSourceService.instance.sources);
    setState(() {
      _running = true;
      _done = 0;
      _total = sources.length;
      _results.clear();
    });
    await SourceValidatorBatch().run(
      sources,
      onDone: (_, r) {
        if (!mounted) return;
        setState(() => _results[r.source.bookSourceUrl] = r);
      },
      onProgress: (done, _) {
        if (!mounted) return;
        setState(() => _done = done);
      },
    );
    if (!mounted) return;
    setState(() => _running = false);
  }

  @override
  Widget build(BuildContext context) {
    final results = _results.values.toList();
    final pass = results.where((r) => r.pass).length;
    final fail = results.length - pass;
    return Scaffold(
      appBar: AppBar(
        title: Text(_running ? '校验中 $_done/$_total' : '校验书源'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '重新校验',
            onPressed: _running ? null : _start,
          ),
        ],
      ),
      body: Column(
        children: [
          // 汇总
          Container(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _stat(context, '共 $results.length', ''),
                _stat(context, '通过 $pass', '通过',
                    color: Colors.green),
                _stat(context, '失败 $fail', '失败',
                    color: Colors.red),
              ],
            ),
          ),
          if (_running && results.isEmpty)
            const Expanded(child: Center(child: CircularProgressIndicator())),
          Expanded(
            child: results.isEmpty
                ? const Center(child: Text('暂无校验结果'))
                : ListView.separated(
                    itemCount: results.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final r = results[i];
                      return _ResultTile(result: r);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _stat(BuildContext ctx, String title, String sub,
      {Color? color}) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(title,
            style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 18,
                color: color ?? Theme.of(ctx).colorScheme.onSurface)),
        if (sub.isNotEmpty)
          Text(sub,
              style: TextStyle(
                  fontSize: 12,
                  color: color ?? Theme.of(ctx).colorScheme.onSurface)),
      ],
    );
  }
}

class _ResultTile extends StatelessWidget {
  const _ResultTile({required this.result});
  final SourceCheckResult result;

  @override
  Widget build(BuildContext context) {
    final s = result.source;
    final color = result.pass ? Colors.green : Colors.red;
    return ListTile(
      leading: Icon(
        result.pass ? Icons.check_circle : Icons.cancel,
        color: color,
      ),
      title: Text(s.bookSourceName,
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(_summary(), maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: Text('${result.elapsedMs.toStringAsFixed(0)}ms',
          style: const TextStyle(fontSize: 12)),
    );
  }

  String _summary() {
    final b = StringBuffer();
    b.write(result.httpOk ? 'HTTP ${result.statusCode}' : 'HTTP 失败(${result.httpError})');
    b.write(' · 搜索${result.searchCount}');
    if (result.detailOk) {
      b.write(' · 目录${result.tocCount}');
    } else {
      b.write(' · 详情不可用');
    }
    return b.toString();
  }
}