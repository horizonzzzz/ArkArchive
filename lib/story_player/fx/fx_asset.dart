import 'dart:math' as math;
import 'dart:ui';

/// `tool/avg_fx_extract.py` 生成的版本 1 描述；贴图相对资源目录 URI 加载。
class FxAsset {
  FxAsset(
    this.name,
    this.base,
    this.duration,
    this.loop,
    this.emitters, {
    this.drawAfterImages = false,
  });

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
      drawAfterImages: json['drawAfterImages'] == true,
    );
  }

  final String name;
  final Uri base;
  final double duration;
  final bool loop;
  final bool drawAfterImages;
  final List<FxEmitterSpec> emitters;
  Set<String> get textures => {for (final e in emitters) e.texture};
  Uri textureUri(String file) => base.resolve(file);
}

class FxEmitterSpec {
  FxEmitterSpec(Map<String, dynamic> j)
    : name = j['name'] as String,
      mesh = j['kind'] == 'mesh',
      geometry = j['geometry'] == null ? null : FxMesh(j['geometry'] as Map),
      transform3D = (j['transform3D'] as List?)
          ?.map((p) => [for (final v in p as List) (v as num).toDouble()])
          .toList(),
      animation = j['animation'] == null
          ? null
          : FxEmitterAnimation(j['animation'] as Map),
      alignment = fxNumber(j['alignment']).toInt(),
      pivot = fxOffset(j['pivot']),
      lengthScale = fxNumber(j['lengthScale'], 2),
      bursts = [
        for (final b in j['bursts'] as List? ?? const []) FxBurst(b as Map),
      ],
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
      sizeYOverLife = j['sizeYOverLife'] == null
          ? null
          : FxRange.parse(j['sizeYOverLife']),
      colorOverLife = FxGradient.parse(j['colorOverLife']),
      rotationOverLife = FxRange.parse(j['rotationOverLife']),
      shape = (j['shape'] as Map? ?? const {}).cast<String, dynamic>(),
      uv = (j['uv'] as Map? ?? const {}).cast<String, dynamic>(),
      velocity = (j['velocity'] as Map? ?? const {}).cast<String, dynamic>(),
      noise = FxRange.parse(j['noise']),
      stretch = j['stretch'] == true {
    if (transform3D != null &&
        (transform3D!.length != 3 ||
            transform3D!.any(
              (p) => p.length != 3 || p.any((v) => !v.isFinite),
            ))) {
      throw const FormatException('特效三维变换无效');
    }
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
    final frames = material['frames'] as Map?;
    if (frames != null &&
        (fxNumber(frames['count']) < 1 ||
            fxNumber(frames['count']) > 512 ||
            fxNumber(frames['columns']) < 1 ||
            fxNumber(frames['columns']) > 16 ||
            fxNumber(frames['fps']) <= 0 ||
            fxNumber(frames['fps']) > 120 ||
            fxNumber(frames['width']) < 1 ||
            fxNumber(frames['height']) < 1 ||
            ['count', 'columns', 'width', 'height'].any(
              (key) =>
                  frames[key] is! num ||
                  !(frames[key] as num).isFinite ||
                  (frames[key] as num) % 1 != 0,
            ) ||
            fxNumber(frames['width']) * fxNumber(frames['columns']) > 8192 ||
            fxNumber(frames['height']) *
                    (fxNumber(frames['count']) / fxNumber(frames['columns']))
                        .ceil() >
                8192)) {
      throw const FormatException('特效材质图集无效');
    }
  }

  final List<List<double>>? transform3D;
  final FxEmitterAnimation? animation;
  final int alignment;
  final Offset pivot;
  final double lengthScale;
  final FxMesh? geometry;
  final List<FxBurst> bursts;
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
  final FxRange? sizeOverLife, sizeYOverLife;
  final FxGradient? startColor, colorOverLife;
  String get texture => material['main'] as String;
  Color get tint => fxColor(material['tint']);
  Color get mainColor => fxColor(material['mainColor']);
  bool get additive =>
      const [1.0, 5.0].contains(fxNumber(material['srcBlend'], 5)) &&
      fxNumber(material['dstBlend'], 10) == 1;
}

class FxEmitterAnimation {
  FxEmitterAnimation(Map json)
    : fps = fxNumber(json['fps']),
      frames = [
        for (final frame in json['frames'] as List)
          [for (final value in frame as List) (value as num).toDouble()],
      ] {
    if (!fps.isFinite ||
        fps <= 0 ||
        fps > 120 ||
        frames.isEmpty ||
        frames.length > 1024 ||
        frames.any(
          (frame) =>
              frame.length != 13 || frame.any((value) => !value.isFinite),
        )) {
      throw const FormatException('特效动画帧无效');
    }
  }

  final double fps;
  final List<List<double>> frames;

  List<double> at(double elapsed) {
    final frame = (elapsed * fps).clamp(0, frames.length - 1).toDouble();
    final first = frame.floor();
    final second = math.min(first + 1, frames.length - 1);
    final fraction = frame - first;
    return [
      for (var i = 0; i < 13; i++)
        frames[first][i] + (frames[second][i] - frames[first][i]) * fraction,
    ];
  }
}

class FxMesh {
  FxMesh(Map j)
    : positions = [
        for (final p in j['positions'] as List)
          [for (final v in p as List) (v as num).toDouble()],
      ],
      uv = [for (final p in j['uv'] as List) fxOffset(p)],
      colors = [
        for (final c in j['colors'] as List)
          Color.fromARGB(
            (c[3] as num).toInt(),
            (c[0] as num).toInt(),
            (c[1] as num).toInt(),
            (c[2] as num).toInt(),
          ),
      ],
      indices = [for (final i in j['indices'] as List) (i as num).toInt()] {
    bool finiteNumber(dynamic v) => v is num && v.isFinite;
    if ((j['uv'] as List).any(
          (p) => p is! List || p.length != 2 || p.any((v) => !finiteNumber(v)),
        ) ||
        (j['colors'] as List).any(
          (c) =>
              c is! List ||
              c.length != 4 ||
              c.any((v) => !finiteNumber(v) || v < 0 || v > 255 || v % 1 != 0),
        ) ||
        (j['indices'] as List).any((v) => !finiteNumber(v) || v % 1 != 0)) {
      throw const FormatException('特效网格属性无效');
    }
    if (positions.isEmpty ||
        positions.length > 4096 ||
        uv.length != positions.length ||
        colors.length != positions.length ||
        positions.any((p) => p.length != 3 || p.any((v) => !v.isFinite)) ||
        indices.isEmpty ||
        indices.length > 24576 ||
        indices.length % 3 != 0 ||
        indices.any((i) => i < 0 || i >= positions.length)) {
      throw const FormatException('特效网格无效');
    }
  }
  final List<List<double>> positions;
  final List<Offset> uv;
  final List<Color> colors;
  final List<int> indices;
}

class FxBurst {
  FxBurst(Map j)
    : time = fxNumber(j['time']),
      count = FxRange.parse(j['count']),
      cycles = fxNumber(j['cycles'], 1).toInt(),
      interval = fxNumber(j['interval']),
      probability = fxNumber(j['probability'], 1) {
    if (time < 0 ||
        cycles < 1 ||
        cycles > 100 ||
        interval < 0 ||
        probability < 0 ||
        probability > 1) {
      throw const FormatException('特效瞬时发射无效');
    }
  }
  final double time, interval, probability;
  final int cycles;
  final FxRange count;
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
