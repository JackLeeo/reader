import 'dart:io';

import 'package:flutter/material.dart';

import '../book_source/services/cover_service.dart';

/// 统一封面组件：优先本地/网络覆盖封面，其次书源网络封面，最后占位图标。
///
/// [overrideUri] 为 [CoverService] 返回的用户自定义封面（`file://` 或 `http(s)`）。
/// [fallbackUrl] 为书源自带 [coverUrl]。
/// [bookKey] 非空时，每次构建自动解析覆盖封面并回填到 [overrideUri]。
class CoverImage extends StatefulWidget {
  const CoverImage({
    super.key,
    this.bookKey,
    this.overrideUri,
    this.fallbackUrl,
    this.width = 80,
    this.height = 110,
  });

  final String? bookKey;
  final String? overrideUri;
  final String? fallbackUrl;
  final double width;
  final double height;

  @override
  State<CoverImage> createState() => _CoverImageState();
}

class _CoverImageState extends State<CoverImage> {
  String? _override;

  @override
  void initState() {
    super.initState();
    _override = widget.overrideUri;
    _resolve();
  }

  @override
  void didUpdateWidget(covariant CoverImage old) {
    super.didUpdateWidget(old);
    if (old.overrideUri != widget.overrideUri ||
        old.bookKey != widget.bookKey) {
      _override = widget.overrideUri;
      _resolve();
    }
  }

  Future<void> _resolve() async {
    final key = widget.bookKey;
    if (key == null || key.isEmpty) return;
    final o = await CoverService.instance.coverFor(key);
    if (!mounted || o == _override) return;
    setState(() => _override = o);
  }

  String? get _effective => _override?.isNotEmpty == true ? _override : widget.fallbackUrl;

  @override
  Widget build(BuildContext context) {
    final placeholder = Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      alignment: Alignment.center,
      child: const Icon(Icons.menu_book_outlined, size: 40),
    );

    Widget child;
    final effective = _effective;
    if (effective == null || effective.isEmpty) {
      child = placeholder;
    } else if (effective.startsWith('http://') ||
        effective.startsWith('https://')) {
      child = Image.network(
        effective,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => placeholder,
        loadingBuilder: (_, child2, progress) {
          if (progress == null) return child2;
          return placeholder;
        },
      );
    } else {
      // file://（本地选择）
      final path = _filePath(effective);
      if (path == null || !File(path).existsSync()) {
        child = placeholder;
      } else {
        child = Image.file(
          File(path),
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => placeholder,
        );
      }
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(width: widget.width, height: widget.height, child: child),
    );
  }

  static String? _filePath(String uri) {
    if (uri.startsWith('file://')) {
      final r = uri.substring(7);
      // file:///C:/... → C:/...
      return r.startsWith('/') ? r.substring(1) : r;
    }
    // 未带协议视为本地路径
    return uri;
  }
}