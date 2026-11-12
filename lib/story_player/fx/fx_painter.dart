import 'dart:math' as math;
import 'dart:ui';

import 'fx_asset.dart';
import 'fx_simulation.dart';

/// 原始主贴图与粒子参数的二维绘制；自定义 shader 的溶解/扭曲尚未复现。
void paintEffects(
  Canvas canvas,
  List<StageEffect> effects,
  Map<Uri, Image> textures,
  String group,
) {
  final ordered = effects.where((e) => e.group == group).toList()
    ..sort((a, b) => a.layer.compareTo(b.layer));
  for (final effect in ordered) {
    canvas.save();
    canvas.translate(640 + effect.offset.dx, 360 - effect.offset.dy);
    canvas.rotate(-effect.rotation);
    canvas.scale(effect.scale.dx, effect.scale.dy);
    for (final emitter in effect.simulation.emitters) {
      final spec = emitter.spec;
      final image = textures[effect.simulation.asset.textureUri(spec.texture)];
      if (image == null) continue;
      final paint = Paint()
        ..filterQuality = FilterQuality.low
        ..blendMode = spec.additive ? BlendMode.plus : BlendMode.srcOver;
      if (spec.mesh) {
        if (!effect.simulation.asset.loop &&
            effect.simulation.elapsed >= effect.simulation.asset.duration) {
          continue;
        }
        canvas.save();
        canvas.translate(spec.position.dx, -spec.position.dy);
        canvas.rotate(-spec.rotation);
        final rect = Rect.fromCenter(
          center: Offset.zero,
          width: spec.scale.dx.abs(),
          height: spec.scale.dy.abs(),
        );
        paint.colorFilter = ColorFilter.mode(
          _multiply(
            spec.tint,
            spec.mainColor,
          ).withValues(alpha: spec.tint.a * spec.mainColor.a * effect.alpha),
          BlendMode.modulate,
        );
        canvas.clipRect(rect);
        final scroll = fxOffset(spec.material['uvScroll']);
        final x = (scroll.dx * emitter.age) % 1;
        final y = (scroll.dy * emitter.age) % 1;
        for (var i = -1; i <= 0; i++) {
          for (var j = -1; j <= 0; j++) {
            canvas.drawImageRect(
              image,
              Rect.fromLTWH(
                0,
                0,
                image.width.toDouble(),
                image.height.toDouble(),
              ),
              rect.shift(Offset((x + i) * rect.width, (y + j) * rect.height)),
              paint,
            );
          }
        }
        canvas.restore();
        continue;
      }
      final tiles = spec.uv['tiles'] as List? ?? const [1, 1];
      final columns = (tiles[0] as num).toInt(),
          rows = (tiles[1] as num).toInt();
      for (final p in emitter.particles) {
        final progress = p.progress;
        final size = spec.sizeOverLife?.at(progress, p.seed) ?? 1;
        if (size <= 0) continue;
        var color = spec.tint;
        if (spec.startColor != null) {
          color = _multiply(color, spec.startColor!.at(p.seed));
        }
        if (spec.colorOverLife != null) {
          color = _multiply(color, spec.colorOverLife!.at(progress));
        }
        paint.colorFilter = ColorFilter.mode(
          color.withValues(alpha: color.a * effect.alpha),
          BlendMode.modulate,
        );
        var frame = 0;
        if (spec.uv['enabled'] == true) {
          final phase = fxNumber(spec.uv['timeMode']) == 1
              ? p.age * fxNumber(spec.uv['fps'], 30) / (columns * rows)
              : FxRange.parse(spec.uv['frame']).at(progress, p.seed) *
                    fxNumber(spec.uv['cycles'], 1);
          final start = FxRange.parse(spec.uv['start']).at(0, p.seed);
          frame = ((phase + start) * columns * rows).floor() % (columns * rows);
        }
        final src = Rect.fromLTWH(
          (frame % columns) * image.width / columns,
          (frame ~/ columns) * image.height / rows,
          image.width / columns,
          image.height / rows,
        );
        canvas.save();
        canvas.translate(p.position.dx, -p.position.dy);
        final rotation = spec.stretch && p.direction.distanceSquared > 0
            ? math.atan2(p.direction.dx, p.direction.dy)
            : -p.rotation;
        canvas.rotate(rotation);
        canvas.drawImageRect(
          image,
          src,
          Rect.fromCenter(
            center: Offset.zero,
            width: p.size * size,
            height: p.sizeY * size * (spec.stretch ? 2 : 1),
          ),
          paint,
        );
        canvas.restore();
      }
    }
    canvas.restore();
  }
}

Color _multiply(Color a, Color b) => Color.from(
  alpha: a.a * b.a,
  red: a.r * b.r,
  green: a.g * b.g,
  blue: a.b * b.b,
);
