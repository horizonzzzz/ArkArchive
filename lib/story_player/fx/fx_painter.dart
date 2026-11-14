import 'dart:math' as math;
import 'dart:ui';
import 'dart:typed_data';

import 'fx_asset.dart';
import 'fx_simulation.dart';

/// 通用粒子与动画网格绘制；材质动画由离线图集提供，运行时投影三维顶点。
void paintEffects(
  Canvas canvas,
  List<StageEffect> effects,
  Map<Uri, Image> textures,
  String group, {
  bool afterImages = false,
}) {
  final ordered =
      effects
          .where(
            (e) =>
                e.group == group &&
                (group != 'bgeffect' ||
                    e.simulation.asset.drawAfterImages == afterImages),
          )
          .toList()
        ..sort((a, b) => a.layer.compareTo(b.layer));
  for (final effect in ordered) {
    canvas.save();
    canvas.translate(640 + effect.offset.dx, 360 - effect.offset.dy);
    final emitters = effect.simulation.emitters.toList()
      ..sort((a, b) => a.spec.sorting.compareTo(b.spec.sorting));
    for (final emitter in emitters) {
      final spec = emitter.spec;
      final image = textures[effect.simulation.asset.textureUri(spec.texture)];
      if (image == null) continue;
      final paint = Paint()
        ..filterQuality = FilterQuality.low
        ..blendMode = spec.additive ? BlendMode.plus : BlendMode.srcOver;
      if (spec.geometry != null) {
        _paintMesh(canvas, effect, emitter, image, paint);
        continue;
      }
      if (spec.mesh) {
        if (!effect.simulation.asset.loop &&
            effect.simulation.elapsed >= effect.simulation.asset.duration) {
          continue;
        }
        canvas.save();
        canvas.rotate(-effect.rotation);
        canvas.scale(effect.scale.dx, effect.scale.dy);
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
      final animation = spec.animation?.at(effect.simulation.elapsed);
      final basis = animation == null
          ? spec.transform3D
          : [
              animation.sublist(0, 3),
              animation.sublist(3, 6),
              animation.sublist(6, 9),
            ];
      final tiles = spec.uv['tiles'] as List? ?? const [1, 1];
      final columns = (tiles[0] as num).toInt(),
          rows = (tiles[1] as num).toInt();
      final materialFrames = spec.material['frames'] as Map?;
      var materialRect = Rect.fromLTWH(
        0,
        0,
        image.width.toDouble(),
        image.height.toDouble(),
      );
      if (materialFrames != null) {
        final count = fxNumber(materialFrames['count']).toInt();
        final frameColumns = fxNumber(materialFrames['columns']).toInt();
        final frame =
            (effect.simulation.elapsed * fxNumber(materialFrames['fps']))
                .floor()
                .clamp(0, count - 1);
        final width = fxNumber(materialFrames['width']);
        final height = fxNumber(materialFrames['height']);
        materialRect = Rect.fromLTWH(
          (frame % frameColumns) * width,
          (frame ~/ frameColumns) * height,
          width,
          height,
        );
      }
      for (final p in emitter.particles) {
        final progress = p.progress;
        final size = spec.sizeOverLife?.at(progress, p.seed) ?? 1;
        final sizeY = spec.sizeYOverLife?.at(progress, p.seed) ?? size;
        if (size <= 0) continue;
        var color = animation == null
            ? spec.tint
            : fxColor(animation.sublist(9));
        if (spec.startColor != null) {
          color = _multiply(color, spec.startColor!.at(p.seed));
        }
        if (spec.colorOverLife != null) {
          color = _multiply(color, spec.colorOverLife!.at(progress));
        }
        final multiplier = fxNumber(
          spec.material['colorMultiplier'],
          1,
        ).clamp(0, 16);
        paint.colorFilter = multiplier == 1
            ? ColorFilter.mode(
                color.withValues(alpha: color.a * effect.alpha),
                BlendMode.modulate,
              )
            : ColorFilter.matrix([
                color.r * multiplier,
                0,
                0,
                0,
                0,
                0,
                color.g * multiplier,
                0,
                0,
                0,
                0,
                0,
                color.b * multiplier,
                0,
                0,
                0,
                0,
                0,
                color.a * multiplier * effect.alpha,
                0,
              ]);
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
          materialRect.left + (frame % columns) * materialRect.width / columns,
          materialRect.top + (frame ~/ columns) * materialRect.height / rows,
          materialRect.width / columns,
          materialRect.height / rows,
        );
        if (basis != null) {
          Offset project(Offset p) => _project(effect, [
            for (var j = 0; j < 3; j++)
              basis[0][j] + basis[1][j] * p.dx + basis[2][j] * p.dy,
          ]);
          final center = project(p.position);
          final velocity = project(p.position + p.direction) - center;
          final angle = spec.stretch && velocity.distanceSquared > 1e-12
              ? math.atan2(velocity.dx, -velocity.dy)
              : -p.rotation;
          final w = p.size * size,
              h = p.sizeY * sizeY * (spec.stretch ? spec.lengthScale : 1);
          final corners = <Offset>[];
          for (final c in const [
            Offset(-.5, -.5),
            Offset(.5, -.5),
            Offset(.5, .5),
            Offset(-.5, .5),
          ]) {
            final x = (c.dx + spec.pivot.dx) * w,
                y = (c.dy + spec.pivot.dy) * h;
            if (spec.alignment == 2) {
              final cos = math.cos(p.rotation), sin = math.sin(p.rotation);
              corners.add(
                project(
                  p.position + Offset(x * cos - y * sin, x * sin + y * cos),
                ),
              );
            } else {
              final cos = math.cos(angle), sin = math.sin(angle);
              corners.add(
                center + Offset(x * cos - y * sin, x * sin + y * cos),
              );
            }
          }
          final origin = corners[3],
              dx = corners[2] - origin,
              dy = corners[0] - origin;
          canvas.save();
          canvas.transform(
            Float64List.fromList([
              dx.dx,
              dx.dy,
              0,
              0,
              dy.dx,
              dy.dy,
              0,
              0,
              0,
              0,
              1,
              0,
              origin.dx,
              origin.dy,
              0,
              1,
            ]),
          );
          canvas.drawImageRect(
            image,
            src,
            const Rect.fromLTWH(0, 0, 1, 1),
            paint,
          );
          canvas.restore();
          continue;
        }
        canvas.save();
        canvas.rotate(-effect.rotation);
        canvas.scale(effect.scale.dx, effect.scale.dy);
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
            height: p.sizeY * sizeY * (spec.stretch ? 2 : 1),
          ),
          paint,
        );
        canvas.restore();
      }
    }
    canvas.restore();
  }
}

Offset _project(StageEffect effect, List<double> p) {
  final sx = math.sin(effect.rotation3D.dx),
      cx = math.cos(effect.rotation3D.dx);
  final sy = math.sin(effect.rotation3D.dy),
      cy = math.cos(effect.rotation3D.dy);
  final sz = math.sin(effect.rotation), cz = math.cos(effect.rotation);
  // Unity Euler 顺序为 Z、X、Y，旋转后投影到舞台。
  final x = cz * p[0] - sz * p[1], y = sz * p[0] + cz * p[1];
  final z = sx * y + cx * p[2];
  return Offset(cy * x + sy * z, -(cx * y - sx * p[2]));
}

void _paintMesh(
  Canvas canvas,
  StageEffect effect,
  FxEmitterSim emitter,
  Image image,
  Paint paint,
) {
  final asset = effect.simulation.asset;
  if (!asset.loop && effect.simulation.elapsed >= asset.duration) return;
  final mesh = emitter.spec.geometry!;
  final positions = [for (final p in mesh.positions) _project(effect, p)];
  final frames = emitter.spec.material['frames'] as Map?;
  var frameX = 0.0, frameY = 0.0;
  var width = image.width.toDouble(), height = image.height.toDouble();
  if (frames != null) {
    final count = fxNumber(frames['count']).toInt();
    final columns = fxNumber(frames['columns']).toInt();
    final frame = (effect.simulation.elapsed * fxNumber(frames['fps']))
        .floor()
        .clamp(0, count - 1);
    width = fxNumber(frames['width']);
    height = fxNumber(frames['height']);
    frameX = (frame % columns) * width;
    frameY = (frame ~/ columns) * height;
  }
  paint.shader = ImageShader(
    image,
    TileMode.clamp,
    TileMode.clamp,
    Float64List.fromList([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]),
  );
  paint.colorFilter = ColorFilter.mode(
    Color.from(alpha: effect.alpha, red: 1, green: 1, blue: 1),
    BlendMode.modulate,
  );
  final vertices = Vertices(
    VertexMode.triangles,
    positions,
    textureCoordinates: [
      for (final uv in mesh.uv)
        Offset(
          frameX + uv.dx.clamp(0, 1) * (width - 1) + .5,
          frameY + (1 - uv.dy.clamp(0, 1)) * (height - 1) + .5,
        ),
    ],
    colors: mesh.colors,
    indices: mesh.indices,
  );
  canvas.drawVertices(vertices, BlendMode.modulate, paint);
  vertices.dispose();
}

Color _multiply(Color a, Color b) => Color.from(
  alpha: a.a * b.a,
  red: a.r * b.r,
  green: a.g * b.g,
  blue: a.b * b.b,
);
