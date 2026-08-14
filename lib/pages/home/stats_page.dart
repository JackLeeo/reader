// 阅读统计页
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/stats_service.dart';
import '../../widgets/empty_state.dart';

class StatsPage extends StatelessWidget {
  const StatsPage({super.key});

  String _fmtDuration(int seconds) {
    if (seconds <= 0) return '0分';
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    if (h > 0) return '${h}时${m}分';
    return '${m}分';
  }

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<StatsService>();
    final today = svc.today;
    final week = svc.thisWeek;
    final total = svc.total;
    final last14 = svc.lastDays(14);
    final maxSec = last14.isEmpty
        ? 1
        : last14.map((d) => d.totalSeconds).reduce((a, b) => a > b ? a : b);

    return Scaffold(
      appBar: AppBar(title: const Text('阅读统计')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              _statCard(context, '今日', _fmtDuration(today.totalSeconds),
                  '${today.totalChars} 字 · ${today.booksRead.length} 本', Colors.blue),
              const SizedBox(width: 12),
              _statCard(context, '本周', _fmtDuration(week.totalSeconds),
                  '${week.totalChars} 字 · ${week.booksRead.length} 本', Colors.green),
            ],
          ),
          const SizedBox(height: 12),
          _statCard(
            context,
            '累计',
            _fmtDuration(total.totalSeconds),
            '${total.totalChars} 字 · ${total.booksRead.length} 本',
            Colors.orange,
            fullWidth: true,
          ),
          const SizedBox(height: 24),
          const Text('最近14天',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: SizedBox(
                height: 140,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: last14.map((d) {
                    final h = maxSec <= 0
                        ? 0.0
                        : (d.totalSeconds / maxSec).clamp(0.0, 1.0);
                    return Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            Text(
                              d.totalSeconds > 0
                                  ? '${d.totalSeconds ~/ 60}'
                                  : '',
                              style: const TextStyle(fontSize: 9),
                            ),
                            const SizedBox(height: 2),
                            Container(
                              height: 100 * h + 2,
                              decoration: BoxDecoration(
                                color: h > 0
                                    ? Colors.blue.shade400
                                    : Colors.grey.shade200,
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '${d.date.month}/${d.date.day}',
                              style: const TextStyle(fontSize: 9),
                            ),
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _statCard(BuildContext context, String title, String duration,
      String detail, Color color,
      {bool fullWidth = false}) {
    return Expanded(
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
              const SizedBox(height: 4),
              Text(duration,
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: color,
                  )),
              const SizedBox(height: 4),
              Text(detail,
                  style: const TextStyle(fontSize: 11, color: Colors.grey)),
            ],
          ),
        ),
      ),
    );
  }
}
