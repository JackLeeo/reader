// 通用封面组件
import 'package:flutter/material.dart';

class BookCover extends StatelessWidget {
  final String? coverUrl;
  final String title;
  final String author;
  final double width;
  final double height;
  final double radius;

  const BookCover({
    super.key,
    this.coverUrl,
    required this.title,
    this.author = '',
    this.width = 60,
    this.height = 80,
    this.radius = 4,
  });

  @override
  Widget build(BuildContext context) {
    if (coverUrl != null && coverUrl!.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: Image.network(
          coverUrl!,
          width: width,
          height: height,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stack) => _placeholder(context),
          loadingBuilder: (context, child, progress) {
            if (progress == null) return child;
            return _placeholder(context);
          },
        ),
      );
    }
    return _placeholder(context);
  }

  Widget _placeholder(BuildContext context) {
    final color = _hashColor(title);
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            color,
            color.withValues(alpha: 0.7),
          ],
        ),
      ),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Text(
            title.isEmpty ? '无名' : title,
            textAlign: TextAlign.center,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Colors.white,
              fontSize: width * 0.18,
              fontWeight: FontWeight.w600,
              height: 1.2,
            ),
          ),
        ),
      ),
    );
  }

  Color _hashColor(String input) {
    if (input.isEmpty) return Colors.grey;
    final hash = input.codeUnits.fold<int>(0, (a, b) => a + b);
    final hue = (hash * 37) % 360;
    return HSLColor.fromAHSL(1.0, hue.toDouble(), 0.55, 0.55).toColor();
  }
}
