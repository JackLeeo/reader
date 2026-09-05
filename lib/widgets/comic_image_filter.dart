import 'dart:ui';

import 'package:flutter/painting.dart';

import '../core/reading_pref.dart';

/// 依据漫画显示参数构造一个 [ColorFilter] 矩阵。
///
/// 组合顺序（对齐官方 ImageFilter 的调节逻辑）：
/// 1. 饱和度（对亮度通道线性插值）
/// 2. 对比度（围绕 0.5 缩放）
/// 3. 亮度（平移 offset）
/// 4. 色彩滤镜（灰度/暖色/冷色/陈旧）
/// 结果叠加到同一 4x5 色彩矩阵。值均为原样时返回 null，避免多余开销。
ColorFilter? comicColorFilter({
  required double brightness,
  required double contrast,
  required double saturation,
  required ComicFilter filter,
  bool invert = false,
}) {
  // 饱和度矩阵（标准线性插值到灰度）。
  const lumR = 0.213, lumG = 0.715, lumB = 0.072;
  final s = saturation.clamp(0.0, 2.0);

  // 饱和度矩阵。
  final matrix = <double>[
    // R 行
    ((1 - s) * lumR + s), ((1 - s) * lumG), ((1 - s) * lumB), 0, 0,
    // G 行
    ((1 - s) * lumR), ((1 - s) * lumG + s), ((1 - s) * lumB), 0, 0,
    // B 行
    ((1 - s) * lumR), ((1 - s) * lumG), ((1 - s) * lumB + s), 0, 0,
    // A 行
    0, 0, 0, 1, 0,
  ];

  // 乘以对比度并叠加亮度 offset（对 R/G/B 一致）。
  final b = brightness.clamp(0.3, 1.8);
  final c = contrast.clamp(0.5, 2.0);
  // offset = 128*(1 - contrast) + 128*(brightness-1) —— 让亮度不改变整体明暗比例。
  final off = (1 - c) + (b - 1.0);

  // 应用对比度 + 亮度。
  final cMatrix = <double>[
    c, 0, 0, 0, 128 * off,
    0, c, 0, 0, 128 * off,
    0, 0, c, 0, 128 * off,
    0, 0, 0, 1, 0,
  ];
  final m2 = _mul(cMatrix, matrix);

  // 色彩滤镜。
  switch (filter) {
    case ComicFilter.grayscale:
      final g = _mul(grayscaleMatrix(), m2);
      return ColorFilter.matrix(_maybeInvert(g, invert).take(20).toList());
    case ComicFilter.warmth:
      final f = _tint(1.06, 1.0, 0.90);
      return ColorFilter.matrix(_maybeInvert(_mul(f, m2), invert).take(20).toList());
    case ComicFilter.cool:
      final f = _tint(0.92, 1.0, 1.08);
      return ColorFilter.matrix(_maybeInvert(_mul(f, m2), invert).take(20).toList());
    case ComicFilter.sepia:
      final f = _sepia();
      return ColorFilter.matrix(_maybeInvert(_mul(f, m2), invert).take(20).toList());
    case ComicFilter.none:
      return ColorFilter.matrix(_maybeInvert(m2, invert).take(20).toList());
  }
}

/// 若开启深色反色，在矩阵后叠乘反色矩阵（R'=1-R 等）。
List<double> _maybeInvert(List<double> m, bool invert) =>
    invert ? _mul(invertMatrix(), m) : m;

/// 反色矩阵。
List<double> invertMatrix() => [
      -1, 0, 0, 0, 255,
      0, -1, 0, 0, 255,
      0, 0, -1, 0, 255,
      0, 0, 0, 1, 0,
    ];

/// 灰度（饱和度 0）矩阵。
List<double> grayscaleMatrix() {
  const lumR = 0.213, lumG = 0.715, lumB = 0.072;
  return [
    lumR, lumG, lumB, 0, 0,
    lumR, lumG, lumB, 0, 0,
    lumR, lumG, lumB, 0, 0,
    0, 0, 0, 1, 0,
  ];
}

/// 简单三通道增益 tint。
List<double> _tint(double r, double g, double by) => [
      r, 0, 0, 0, 0,
      0, g, 0, 0, 0,
      0, 0, by, 0, 0,
      0, 0, 0, 1, 0,
    ];

/// 陈旧/褐色调：红绿偏暖、蓝压暗。
List<double> _sepia() => [
      0.393, 0.769, 0.189, 0, 0,
      0.349, 0.686, 0.168, 0, 0,
      0.272, 0.534, 0.131, 0, 0,
      0, 0, 0, 1, 0,
    ];

/// 4x5 矩阵乘法（左 × 右），返回 20 行长列表。
List<double> _mul(List<double> a, List<double> b) {
  final out = List<double>.filled(20, 0);
  // C[i][j] = sum over k in 0..3 of a[i][k] * b[k][j]，为保留色用 4 维齐次坐标。
  for (var i = 0; i < 4; i++) {
    for (var j = 0; j < 4; j++) {
      var v = 0.0;
      for (var k = 0; k < 4; k++) {
        v += a[i * 5 + k] * b[k * 5 + j];
      }
      out[i * 5 + j] = v;
    }
    // 平移列：C[i][4] = a[i][4] + sum_k a[i][k]*b[k][4]
    var tr = a[i * 5 + 4];
    for (var k = 0; k < 4; k++) {
      tr += a[i * 5 + k] * b[k * 5 + 4];
    }
    out[i * 5 + 4] = tr;
  }
  return out;
}