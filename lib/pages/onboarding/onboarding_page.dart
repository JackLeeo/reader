import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 首次启动引导页（对齐官方“欢迎/首页引导”）。
///
/// 三屏简介：书源、书库、阅读定制。滑到最后“开始使用”，写入首次启动标记，
/// 之后不再展示。
class OnboardingPage extends StatefulWidget {
  const OnboardingPage({super.key});

  static const String kOnboardedKey = 'app.hasOnboarded';

  /// 清空引导标记（便于重新展示）。
  static Future<void> reset() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(kOnboardedKey);
  }

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  final PageController _controller = PageController();
  int _page = 0;

  static const List<(IconData, String, String)> _slides = [
    (
      Icons.collections_bookmark_outlined,
      '多书源聚合',
      '导入书源，一处搜遍全网小说',
    ),
    (
      Icons.library_books_outlined,
      '书架与阅读进度',
      '收藏书籍，自动记住阅读位置',
    ),
    (
      Icons.tune_outlined,
      '高度可定制',
      '字号、主题、高亮、朗读、漫画增强一应俱全',
    ),
  ];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(OnboardingPage.kOnboardedKey, true);
    if (!mounted) return;
    Navigator.of(context).pushReplacementNamed('/home');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: PageView.builder(
                controller: _controller,
                itemCount: _slides.length,
                onPageChanged: (i) => setState(() => _page = i),
                itemBuilder: (_, i) {
                  final (icon, title, desc) = _slides[i];
                  return Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(32),
                          decoration: BoxDecoration(
                            color: scheme.primary.withValues(alpha: 0.12),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(icon, size: 96, color: scheme.primary),
                        ),
                        const SizedBox(height: 40),
                        Text(title, style: Theme.of(context).textTheme.headlineSmall),
                        const SizedBox(height: 12),
                        Text(
                          desc,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < _slides.length; i++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 250),
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    width: _page == i ? 20 : 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: _page == i
                          ? scheme.primary
                          : scheme.outline.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.all(24),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _page == _slides.length - 1
                      ? _finish
                      : () => _controller.nextPage(
                            duration: const Duration(milliseconds: 250),
                            curve: Curves.easeOut,
                          ),
                  child: Text(_page == _slides.length - 1 ? '开始使用' : '下一步'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}