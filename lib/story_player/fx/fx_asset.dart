import 'dart:math' as math;
import 'dart:ui';

/// `tool/avg_fx_extract.py` 生成的版本 1 描述；贴图相对资源目录 URI 加载。
class FxAsset {
  FxAsset(this.name, this.base, this.duration, this.loop, this.emitters);

  factory FxAsset.parse(Map<String, dynamic> json, {Uri? base}) {
    if (json['version'] != 1) throw const FormatException('不支持的特效版本');
    final name = json['name'] as String;
    final emitters = (json['emitters'] as List)
        .map((e) => FxEmitterSpec(e as Map<String, dynamic>))
        .toList();
    if (emitters.isEmpty || emitters.length > 64) {
      throw const FormatException('特效发射器数量无效');
    }
    return FxAsset(
      name,
      base ?? Uri(),
      fxNumber(json['duration'], 5).clamp(.01, 120),
      json['isLoop'] == true,
      emitters,
    );
  }

  final String name;
  final Uri base;
  final double duration;
  final bool loop;
  final List<FxEmitterSpec> emitters;
  Set<String> get textures => {for (final e in emitters) e.texture};
  Uri textureUri(String file) => base.resolve(file);
}

class FxEmitterSpec {
  FxEmitterSpec(Map<String, dynamic> j)
    : name = j['name'] as String,
      mesh = j['kind'] == 'mesh',
      sorting = fxNumber(j['sorting']).toInt(),
      position = fxOffset(j['position']),
      scale = fxOffset(j['scale'], const Offset(1, 1)),
      rotation = fxNumber(j['rotation']),
      material = (j['material'] as Map).cast<String, dynamic>(),
      loop = j['loop'] != false,
      prewarm = j['prewarm'] == true,
      duration = fxNumber(j['duration'], 5).clamp(.01, 120),
      maxParticles = fxNumber(j['maxParticles'], 100).toInt().clamp(0, 2000),
      rate = FxRange.parse(j['rate']),
      lifetime = FxRange.parse(j['lifetime']),
      speed = FxRange.parse(j['speed']),
      size = FxRange.parse(j['size']),
      sizeY = FxRange.parse(j['sizeY']),
      startRotation = FxRange.parse(j['startRotation']),
      gravity = FxRange.parse(j['gravity']),
      startColor = FxGradient.parse(j['startColor']),
      sizeOverLife = j['sizeOverLife'] == null
          ? null
          : FxRange.parse(j['sizeOverLife']),
      colorOverLife = FxGradient.parse(j['colorOverLife']),
      rotationOverLife = FxRange.parse(j['rotationOverLife']),
      shape = (j['shape'] as Map? ?? const {}).cast<String, dynamic>(),
      uv = (j['uv'] as Map? ?? const {}).cast<String, dynamic>(),
      velocity = (j['velocity'] as Map? ?? const {}).cast<String, dynamic>(),
      noise = FxRange.parse(j['noise']),
      stretch = j['stretch'] == true {
    if (!RegExp(r'^[a-zA-Z0-9_-]+\.png$').hasMatch(texture)) {
      throw const FormatException('特效贴图文件名无效');
    }
    if (!const [1, 5].contains(fxNumber(material['srcBlend'], 5).toInt()) ||
        !const [
          0,
          1,
          10,
        ].contains(fxNumber(material['dstBlend'], 10).toInt())) {
      throw const FormatException('不支持的特效材质混合方式');
    }
    final tiles = uv['tiles'] as List? ?? const [1, 1];
    if (tiles.length != 2 ||
        tiles.any((v) => fxNumber(v) < 1 || fxNumber(v) > 16)) {
      throw const FormatException('特效贴图网格无效');
    }
  }

  final String name;
  final bool mesh, loop, prewarm, stretch;
  final Offset position, scale;
  final double rotation, duration;
  final int sorting;
  final int maxParticles;
  final Map<String, dynamic> material, shape, uv, velocity;
  final FxRange rate,
      lifetime,
      speed,
      size,
      sizeY,
      startRotation,
      gravity,
      rotationOverLife,
      noise;
  final FxRange? sizeOverLife;
  final FxGradient? startColor, colorOverLife;
  String get texture => material['main'] as String;
  Color get tint => fxColor(material['tint']);
  Color get mainColor => fxColor(material['mainColor']);
  bool get additive =>
      fxNumber(material['srcBlend'], 5) == 1 &&
      fxNumber(material['dstBlend'], 10) == 1;
}

/// Unity MinMaxCurve：0 常量、1 曲线、2 双曲线、3 双常量。
/// u 在粒子出生时取样并保留，生命周期内不会重新随机。
class FxRange {
  const FxRange(this.state, this.scalar, this.min, this.curve, this.curveMin);
  factory FxRange.parse(dynamic value) {
    final j = value as Map? ?? const {};
    List<List<double>> points(dynamic raw) => [
      for (final p in raw as List? ?? const [])
        [for (final v in p as List) fxNumber(v)],
    ];
    return FxRange(
      fxNumber(j['state']).toInt(),
      fxNumber(j['scalar']),
      fxNumber(j['min']),
      points(j['curve']),
      points(j['curveMin']),
    );
  }
  final int state;
  final double scalar, min;
  final List<List<double>> curve, curveMin;
  double at(double t, [double u = .5]) => switch (state) {
    1 => _eval(curve, t) * scalar,
    2 => (_eval(curveMin, t) * (1 - u) + _eval(curve, t) * u) * scalar,
    3 => min + (scalar - min) * u,
    _ => scalar,
  };
  double sample(math.Random random, [double t = 0]) =>
      at(t, random.nextDouble());

  static double _eval(List<List<double>> points, double t) {
    if (points.isEmpty) return 1;
    if (t <= points.first[0]) return points.first[1];
    for (var i = 1; i < points.length; i++) {
      final a = points[i - 1], b = points[i];
      if (t > b[0]) continue;
      final span = b[0] - a[0];
      if (span <= 0) return b[1];
      final k = (t - a[0]) / span;
      if (a.length < 4 || b.length < 4) return a[1] + (b[1] - a[1]) * k;
      final k2 = k * k, k3 = k2 * k;
      return (2 * k3 - 3 * k2 + 1) * a[1] +
          (k3 - 2 * k2 + k) * span * a[3] +
          (-2 * k3 + 3 * k2) * b[1] +
          (k3 - k2) * span * b[2];
    }
    return points.last[1];
  }
}

class FxGradient {
  FxGradient(this.stops);
  static FxGradient? parse(dynamic raw) => raw is! List || raw.isEmpty
      ? null
      : FxGradient([
          for (final p in raw) [for (final v in p as List) fxNumber(v)],
        ]);
  final List<List<double>> stops;
  Color at(double t) {
    if (t <= stops.first[0]) return fxColor(stops.first.sublist(1));
    for (var i = 1; i < stops.length; i++) {
      final a = stops[i - 1], b = stops[i];
      if (t > b[0]) continue;
      final k = b[0] <= a[0] ? 1.0 : (t - a[0]) / (b[0] - a[0]);
      return fxColor([for (var c = 1; c <= 4; c++) a[c] + (b[c] - a[c]) * k]);
    }
    return fxColor(stops.last.sublist(1));
  }
}

double fxNumber(dynamic v, [double fallback = 0]) =>
    v is num && v.isFinite ? v.toDouble() : fallback;
Offset fxOffset(dynamic v, [Offset fallback = Offset.zero]) =>
    v is List && v.length >= 2
    ? Offset(fxNumber(v[0]), fxNumber(v[1]))
    : fallback;
Color fxColor(dynamic v) => v is List && v.length >= 4
    ? Color.from(
        red: fxNumber(v[0], 1).clamp(0, 1),
        green: fxNumber(v[1], 1).clamp(0, 1),
        blue: fxNumber(v[2], 1).clamp(0, 1),
        alpha: fxNumber(v[3], 1).clamp(0, 1),
      )
    : const Color(0xffffffff);
