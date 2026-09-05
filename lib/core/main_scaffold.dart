import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../pages/bookshelf/bookshelf_page.dart';
import '../pages/explore/explore_page.dart';
import '../pages/me/me_page.dart';
import '../pages/rss/rss_page.dart';

/// 官方底部导航信息架构：书库 / 发现 / 我的 / RSS
/// （对应用户端 main_bnv.xml）。
final class MainDestination {
  const MainDestination(this.label, this.icon, this.selectedIcon, this.builder);

  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final WidgetBuilder builder;
}

final List<MainDestination> kMainDestinations = [
  MainDestination(
    '书库',
    Icons.collections_bookmark_outlined,
    Icons.collections_bookmark,
    (context) => const BookshelfPage(),
  ),
  MainDestination(
    '发现',
    Icons.travel_explore_outlined,
    Icons.travel_explore,
    (context) => const ExplorePage(),
  ),
  MainDestination(
    '我的',
    Icons.person_outline,
    Icons.person,
    (context) => const MePage(),
  ),
  MainDestination(
    'RSS',
    Icons.rss_feed_outlined,
    Icons.rss_feed,
    (context) => const RssPage(),
  ),
];

/// 官方 DayNight UI 主框架：底部导航 + 四个页签，保留各页状态。
class MainScaffold extends StatefulWidget {
  const MainScaffold({super.key});

  @override
  State<MainScaffold> createState() => _MainScaffoldState();
}

class _MainScaffoldState extends State<MainScaffold> {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _loadDefaultHome();
  }

  /// 恢复「默认首页」设置（0 书库 / 1 发现 / 2 我的 / 3 RSS）。
  Future<void> _loadDefaultHome() async {
    final p = await SharedPreferences.getInstance();
    final i = p.getInt('defaultHome') ?? 0;
    if (mounted && i >= 0 && i < kMainDestinations.length) {
      setState(() => _index = i);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [
          for (final d in kMainDestinations) d.builder(context),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: [
          for (final d in kMainDestinations)
            NavigationDestination(
              icon: Icon(d.icon),
              selectedIcon: Icon(d.selectedIcon),
              label: d.label,
            ),
        ],
      ),
    );
  }
}