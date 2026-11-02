import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../data/media_catalog.dart';
import '../stage_state.dart';

class StagePainter extends CustomPainter {
  StagePainter(this.state, this.catalog, this.textures, this.slideMaskShader);
  final StageState state;
  final MediaCatalog catalog;
  final Map<Uri, ui.Image> textures;
  final ui.FragmentShader? slideMaskShader;
  static const bounds = Rect.fromLTWH(0, 0, 1280, 720);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(bounds);
    canvas.drawColor(Colors.black, BlendMode.src);
    canvas.translate(state.shake.dx, state.shake.dy);
    _layer(canvas, 'bg', () { for (final image in state.backgrounds) { _image(canvas, image); } });
    _layer(canvas, 'char', () { for (final character in state.characters) { _character(canvas, character); } });
    _layer(canvas, 'cg', () { for (final image in state.images) { _image(canvas, image); } });
    for (final frame in state.interludes.values) {
      if (!frame.visible || frame.avatar.isEmpty || frame.scale.dx <= 0 || frame.scale.dy <= 0) continue;
      final rect = Rect.fromCenter(center: Offset(640 + frame.offset.dx, 360 - frame.offset.dy), width: frame.size.width * frame.scale.dx, height: frame.size.height * frame.scale.dy);
      canvas.save();
      canvas.clipRect(rect);
      _character(canvas, StageCharacter('m', frame.avatar)..x = frame.offset.dx);
      canvas.restore();
    }
    for (final entry in state.curtains.entries) {
      final fill = entry.value.clamp(0.0, 1.0);
      final rect = switch (entry.key) {
        0 => Rect.fromLTWH(0, 0, 1280, 720 * fill),
        4 => Rect.fromLTWH(0, 720 * (1 - fill), 1280, 720 * fill),
        2 => Rect.fromLTWH(1280 * (1 - fill), 0, 1280 * fill, 720),
        6 => Rect.fromLTWH(0, 0, 1280 * fill, 720),
        _ => Rect.zero,
      };
      canvas.drawRect(rect, Paint()..color = Colors.black);
    }
    canvas.restore();
    _blocker(canvas);
  }
  void _layer(Canvas canvas, String type, void Function() draw) {
    final amount = (state.focus[type] ?? 0).clamp(0.0, 1.0);
    if (amount > 0) canvas.saveLayer(bounds, Paint()..imageFilter = ui.ImageFilter.blur(sigmaX: amount * 8, sigmaY: amount * 8));
    draw();
    if (amount > 0) canvas.restore();
  }

  void _image(Canvas canvas, StageImage layer) {
    final image = textures[catalog.image(layer.key, cg: layer.cg)];
    if (image == null || layer.alpha <= 0) return;
    final ppu = (catalog.backgroundPpu[layer.key.toLowerCase()] as num?)?.toDouble() ?? 100;
    var w = image.width / ppu * 100, h = image.height / ppu * 100;
    final fit = layer.fit.toLowerCase();
    if (fit == 'fill') { w = 1280; h = 720; }
    else if (['coverall', 'showall', 'width', 'height'].contains(fit)) {
      final scale = fit == 'width' ? 1280 / w : fit == 'height' ? 720 / h : fit == 'showall' ? math.min(1280 / w, 720 / h) : math.max(1280 / w, 720 / h);
      w *= scale; h *= scale;
    }
    canvas.save();
    canvas.translate(640 + layer.x, 360 - layer.y);
    canvas.scale(layer.scaleX, layer.scaleY);
    canvas.drawImageRect(image, Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()), Rect.fromCenter(center: Offset.zero, width: w, height: h), Paint()..color = Colors.white.withValues(alpha: layer.alpha.clamp(0, 1))..filterQuality = FilterQuality.medium);
    canvas.restore();
  }

  void _character(Canvas canvas, StageCharacter node) {
    final art = catalog.character(node.name);
    if (art == null) return;
    final body = textures[art.body];
    if (body == null || node.alpha <= 0) return;
    final w = art.size.width > 0 ? art.size.width : body.width.toDouble();
    final h = art.size.height > 0 ? art.size.height : body.height.toDouble();
    final x = switch (node.slot) { 'l' => 440.0, 'r' => 840.0, _ => 640.0 };
    final b = node.brightness;
    final paint = Paint()..color = Colors.white.withValues(alpha: node.alpha.clamp(0, 1))..filterQuality = FilterQuality.medium
      ..colorFilter = ColorFilter.matrix([b,0,0,0,0, 0,b,0,0,0, 0,0,b,0,0, 0,0,0,1,0]);
    canvas.save();
    canvas.translate(x - w / 2 + art.position.dx + node.x, 720 - h / 2 - art.position.dy - node.y);
    canvas.scale(node.scaleX, node.scaleY);
    canvas.translate(w / 2, h / 2);
    canvas.rotate(node.angle);
    canvas.translate(-w / 2, -h / 2);
    canvas.scale(w / body.width, h / body.height);
    final rect = Rect.fromLTWH(0, 0, body.width.toDouble(), body.height.toDouble());
    // 身体和表情先合成再调透明度，避免半透明差分出现双重轮廓。
    canvas.saveLayer(rect, paint);
    canvas.drawImage(body, Offset.zero, Paint());
    final face = art.face == null ? null : textures[art.face];
    if (face != null && art.faceRect != null) canvas.drawImageRect(face, Rect.fromLTWH(0, 0, face.width.toDouble(), face.height.toDouble()), art.faceRect!, Paint());
    canvas.restore();
    canvas.restore();
  }

  void _blocker(Canvas canvas) {
    final alpha = state.blockerAlpha.clamp(0.0, 1.0);
    if (alpha <= 0) return;
    if (['slider', 'verticalslider'].contains(state.blockerStyle)) {
      final mask = textures[MediaCatalog.slideMaskUri];
      final shader = slideMaskShader;
      if (mask != null && shader != null) {
        final vertical = state.blockerStyle == 'verticalslider';
        shader
          ..setFloat(0, bounds.width)
          ..setFloat(1, bounds.height)
          ..setFloat(2, alpha)
          ..setFloat(3, .601)
          ..setFloat(4, .641)
          ..setFloat(5, vertical ? 1 : .787)
          ..setFloat(6, vertical ? 1 : 0)
          ..setFloat(7, !vertical && state.blockerInverse ? 1 : 0)
          ..setFloat(8, vertical && state.blockerInverse ? 1 : 0)
          ..setFloat(9, state.blockerColor.r)
          ..setFloat(10, state.blockerColor.g)
          ..setFloat(11, state.blockerColor.b)
          ..setFloat(12, state.blockerColor.a)
          ..setImageSampler(0, mask);
        canvas.drawRect(bounds, Paint()..shader = shader);
      } else {
        final vertical = state.blockerStyle == 'verticalslider';
        final extent = (vertical ? 720 : 1280) * alpha;
        final rect = vertical ? Rect.fromLTWH(0, state.blockerInverse ? 720 - extent : 0, 1280, extent) : Rect.fromLTWH(state.blockerInverse ? 1280 - extent : 0, 0, extent, 720);
        canvas.drawRect(rect, Paint()..color = state.blockerColor);
      }
    } else {
      canvas.drawRect(bounds, Paint()..color = state.blockerColor.withValues(alpha: alpha));
    }
  }

  @override
  bool shouldRepaint(StagePainter oldDelegate) => true;
}
