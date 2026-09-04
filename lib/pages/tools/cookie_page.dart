import 'package:flutter/material.dart';

import '../../book_source/services/cookie_service.dart';

/// 登录 Cookie 管理（对应官方「Cookie」）。
///
/// 按域名查看/删除已保存的登录 Cookie；配合书源的登录地址使用。
class CookiePage extends StatefulWidget {
  const CookiePage({super.key});

  @override
  State<CookiePage> createState() => _CookiePageState();
}

class _CookiePageState extends State<CookiePage> {
  @override
  Widget build(BuildContext context) {
    final domains = CookieService.instance.domains;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Cookie 管理'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep_outlined),
            tooltip: '清空全部',
            onPressed: domains.isEmpty
                ? null
                : () async {
                    await CookieService.instance.clearAll();
                    setState(() {});
                  },
          ),
        ],
      ),
      body: domains.isEmpty
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.cookie_outlined, size: 64),
                  SizedBox(height: 12),
                  Text('暂无已保存的 Cookie\n书源登录后可自动保存'),
                ],
              ),
            )
          : ListView(
              children: [
                for (final d in domains) _domainTile(context, d),
              ],
            ),
    );
  }

  Widget _domainTile(BuildContext context, String domain) {
    final cookies = CookieService.instance.cookiesFor(domain);
    return ExpansionTile(
      leading: const Icon(Icons.dns_outlined),
      title: Text(domain),
      subtitle: Text('${cookies.length} 个 Cookie'),
      children: [
        for (final e in cookies.entries)
          ListTile(
            dense: true,
            contentPadding: const EdgeInsets.only(left: 32, right: 16),
            leading: const Icon(Icons.key_outlined, size: 18),
            title: Text(e.key),
            subtitle: Text(e.value,
                maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline, size: 18),
              tooltip: '删除',
              onPressed: () async {
                await CookieService.instance.deleteCookie(domain, e.key);
                if (!mounted) return;
                setState(() {});
              },
            ),
          ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: () async {
              await CookieService.instance.clearDomain(domain);
              if (!mounted) return;
              setState(() {});
            },
            child: const Text('清空该域名'),
          ),
        ),
      ],
    );
  }
}
