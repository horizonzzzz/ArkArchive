import 'dart:math' as math;
import 'dart:ui';

import 'fx_asset.dart';

class FxParticle {
  FxParticle(
    this.position,
    this.direction,
    this.life,
    this.size,
    this.sizeY,
    this.rotation,
    this.speed,
    this.gravity,
    this.seed,
  );
  Offset position;
  final Offset direction;
  final double life, size, sizeY, speed, gravity, seed;
  double age = 0, rotation;
  double get progress => (age / life).clamp(0, 1);
}

/// 使用像素坐标、y 向上。Unity 粒子尺寸和速度以 100 像素/单位投影；
/// 这是 AVG 平面投影近似，不能替代 Unity 的三维 Shape 和自定义 shader。
class FxEmitterSim {
  FxEmitterSim(this.spec, int seed) : random = math.Random(seed);
  static const pixelsPerUnit = 100.0;
  final FxEmitterSpec spec;
  final math.Random random;
  final List<FxParticle> particles = [];
  double age = 0, _debt = 0;

  Offset _rotate(Offset p) => Offset(
    p.dx * math.cos(spec.rotation) - p.dy * math.sin(spec.rotation),
    p.dx * math.sin(spec.rotation) + p.dy * math.cos(spec.rotation),
  );
  Offset _scale(Offset p) => Offset(p.dx * spec.scale.dx, p.dy * spec.scale.dy);

  void advance(double dt, {bool emit = true}) {
    final before = age;
    age += dt;
    if (spec.mesh) return;
    final phase = (before % spec.duration) / spec.duration;
    final emitDt = !emit
        ? 0.0
        : spec.loop
        ? dt
        : math.min(dt, math.max(0.0, spec.duration - before));
    _debt += spec.rate.at(phase).clamp(0, 2000) * emitDt;
    // 先推进已有粒子，再分配本帧内的出生时间，避免低帧率下一次出现整团粒子。
    for (final p in particles) {
      _advanceParticle(p, dt);
    }
    particles.removeWhere((p) => p.age >= p.life);
    final count = _debt.floor();
    _debt -= count;
    for (var i = 0; i < count && particles.length < spec.maxParticles; i++) {
      final p = _spawn(phase);
      _advanceParticle(p, dt * (1 - (i + 1) / math.max(1, count)));
      if (p.age < p.life) particles.add(p);
    }
  }

  void _advanceParticle(FxParticle p, double dt) {
    final progress = p.progress;
    var velocity = p.direction * p.speed;
    if (spec.velocity['enabled'] == true) {
      velocity +=
          _rotate(
            _scale(
              Offset(
                FxRange.parse(spec.velocity['x']).at(progress, p.seed),
                FxRange.parse(spec.velocity['y']).at(progress, p.seed),
              ),
            ),
          ) *
          pixelsPerUnit;
    }
    final noise = spec.noise.at(progress, p.seed) * pixelsPerUnit;
    // shortcut: 用连续正弦扰动近似 Unity Noise；获得 shader/三维参考后再校准。
    velocity +=
        Offset(
          math.sin(p.seed * 30 + p.age * 2),
          math.cos(p.seed * 40 + p.age),
        ) *
        noise;
    p.position +=
        velocity * dt +
        Offset(
          0,
          -9.81 * pixelsPerUnit * p.gravity * (p.age * dt + dt * dt / 2),
        );
    p.rotation += spec.rotationOverLife.at(progress, p.seed) * dt;
    p.age += dt;
  }

  FxParticle _spawn(double phase) {
    final seed = random.nextDouble();
    final shape = spec.shape;
    var origin = Offset.zero;
    var direction = const Offset(0, 1);
    if (shape['enabled'] == true) {
      final radius = fxNumber(shape['radius']);
      final shapeScale = fxOffset(shape['scale'], const Offset(1, 1));
      final type = fxNumber(shape['type']).toInt();
      if (type == 5) {
        origin = Offset(
          (random.nextDouble() - .5) * shapeScale.dx,
          (random.nextDouble() - .5) * shapeScale.dy,
        );
      } else {
        final angle = random.nextDouble() * math.pi * 2;
        final thickness = fxNumber(shape['thickness'], 1).clamp(0, 1);
        final inner = 1 - thickness;
        final r =
            radius *
            math.sqrt(
              inner * inner + (1 - inner * inner) * random.nextDouble(),
            );
        origin = Offset(
          math.cos(angle) * r * shapeScale.dx,
          math.sin(angle) * r * shapeScale.dy,
        );
        if (type == 8) direction = Offset(math.cos(angle), math.sin(angle));
        if (type == 4) {
          final spread =
              (random.nextDouble() - .5) *
              fxNumber(shape['angle']) *
              math.pi /
              180;
          direction = Offset(math.sin(spread), math.cos(spread));
        }
      }
    }
    return FxParticle(
      spec.position + _rotate(_scale(origin)) * pixelsPerUnit,
      _rotate(_scale(direction)),
      spec.lifetime.at(phase, seed).clamp(.01, 120),
      spec.size.at(phase, seed).abs() * pixelsPerUnit * spec.scale.dx.abs(),
      spec.sizeY.at(phase, seed).abs() * pixelsPerUnit * spec.scale.dy.abs(),
      spec.startRotation.at(phase, seed) + spec.rotation,
      spec.speed.at(phase, seed) * pixelsPerUnit,
      spec.gravity.at(phase, seed),
      seed,
    );
  }
}

class FxSimulation {
  FxSimulation(FxAsset asset, {int seed = 0, bool? loop})
      : asset = asset,
        _loop = loop ?? asset.loop {
    for (final spec in asset.emitters) {
      final emitter = FxEmitterSim(spec, seed + emitters.length * 7919);
      emitters.add(emitter);
      if (spec.prewarm && _loop) {
        for (var t = 0.0; t < math.min(spec.duration, 10); t += 1 / 60) {
          emitter.advance(1 / 60);
        }
      }
    }
  }
  final FxAsset asset;
  final bool _loop;
  final List<FxEmitterSim> emitters = [];
  double elapsed = 0;
  bool get active =>
      _loop ||
      elapsed < asset.duration ||
      emitters.any((e) => e.particles.isNotEmpty);

  void advance(double dt) {
    if (!dt.isFinite || dt <= 0) return;
    // 恢复前台后的长帧最多追赶 250ms，固定步长稳定发射数量与粒子寿命。
    var remaining = math.min(dt, .25);
    while (remaining > 1e-8) {
      final step = math.min(remaining, 1 / 60);
      for (final e in emitters) {
        e.advance(step, emit: _loop || elapsed < asset.duration);
      }
      elapsed += step;
      remaining -= step;
    }
  }
}

class StageEffect {
  StageEffect(
    this.simulation, {
    required this.group,
    required this.layer,
    this.offset = Offset.zero,
    this.rotation = 0,
    this.scale = const Offset(1, 1),
  });
  final FxSimulation simulation;
  final String group;
  final int layer;
  final Offset offset, scale;
  final double rotation;
  double alpha = 1;
}
