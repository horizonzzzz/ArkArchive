import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../data/media_catalog.dart';
import '../stage_state.dart';
import '../fx/fx_painter.dart';

/// 1280×720 逻辑舞台的分层绘制；层级顺序与参考端 ir.attach 一致。
class StagePainter extends CustomPainter {
  StagePainter(
    this.state,
    this.catalog,
    this.textures,
    this.slideMask,
    this.slideMaskShader,
    this.sprites, {
    this.fontFamily = 'StoryNotoSans',
  });
  final StageState state;
  final MediaCatalog catalog;
  final Map<Uri, ui.Image> textures;
  final ui.Image? slideMask;
  final ui.FragmentShader? slideMaskShader;
  final Map<String, ui.Image> sprites;
  final String fontFamily;
  static const bounds = Rect.fromLTWH(0, 0, 1280, 720);

  static const _curtainAngles = {
    0: 180.0,
    1: 225.0,
    2: 270.0,
    3: 315.0,
    4: 0.0,
    5: 45.0,
    6: 90.0,
    7: 135.0,
  };
  static const _curtainAnchors = {
    1: (1204.69, -240.69),
    3: (1201.49, 938.18),
    5: (70.11, 938.18),
    7: (73.31, -240.69),
  };

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(bounds);
    canvas.drawColor(Colors.black, BlendMode.src);
    // 镜头震动与灰度/反色只作用于场景层，不作用于 CG 道具、幕布与遮罩。
    final cameraFilter = _cameraFilter();
    canvas.save();
    if (cameraFilter != null) {
      canvas.saveLayer(bounds, Paint()..colorFilter = cameraFilter);
    }
    canvas.translate(state.shake.dx, state.shake.dy);
    _withFocus(canvas, 'bg', (c) {
      for (final image in state.backgrounds) {
        _image(c, image);
      }
    });
    _withFocus(canvas, 'lbg', (c) {
      for (final scene in state.largeScenes) {
        _largeScene(c, scene);
      }
    });
    _withFocus(canvas, 'bg', (c) => _avgDisplays(c, 'bgover'));
    _withFocus(
      canvas,
      'bg',
      (c) => paintEffects(c, state.effects, textures, 'bgeffect'),
    );
    canvas.save();
    canvas.translate(640, 360);
    canvas.rotate(state.imageRotation * math.pi / 180);
    canvas.translate(-640, -360);
    _withFocus(canvas, 'cg', (c) {
      for (final image in state.images) {
        _image(c, image);
      }
      for (final scene in state.largeImages) {
        _largeScene(c, scene, extraScale: 1.2);
      }
    });
    canvas.restore();
    _withFocus(
      canvas,
      'bg',
      (c) => paintEffects(
        c,
        state.effects,
        textures,
        'bgeffect',
        afterImages: true,
      ),
    );
    _withFocus(canvas, 'cg', (c) => _avgDisplays(c, 'cgover'));
    for (final window in state.cutins.values) {
      _cutinWindow(c: canvas, window: window);
    }
    for (final frame in state.interludes.values) {
      if (frame.visible) _interlude(canvas, frame);
    }
    for (final item in state.showItems) {
      _showItem(canvas, item);
    }
    _withFocus(canvas, 'char', (c) {
      for (final character in state.characters) {
        _character(c, character);
      }
    });
    _withFocus(canvas, 'char', (c) => _avgDisplays(c, 'charover'));
    paintEffects(canvas, state.effects, textures, 'effect');
    if (cameraFilter != null) {
      canvas.restore();
    }
    canvas.restore();
    for (final item in state.cgItems.values) {
      _cgItem(canvas, item);
    }
    for (final entry in state.curtains.entries) {
      _curtain(canvas, entry.key, entry.value);
    }
    canvas.restore();
    _blocker(canvas);
    for (final stamp in state.stamps) {
      _stamp(canvas, stamp);
    }
  }

  ColorFilter? _cameraFilter() {
    if (state.grayscale <= 0 && state.inverse <= 0) return null;
    return ColorFilter.matrix(_grayMatrix(state.grayscale, state.inverse));
  }

  /// 参考端 Ln：灰度与反色合并的 4×5 颜色矩阵。
  List<double> _grayMatrix(double amount, double inverse) {
    final n = 1 - 2 * inverse;
    const r = .299, g = .587, b = .114;
    final rr = r * amount, gg = g * amount, bb = b * amount, w = 1 - amount;
    return [
      (rr + w) * n,
      gg * n,
      bb * n,
      0,
      255 * inverse,
      rr * n,
      (gg + w) * n,
      bb * n,
      0,
      255 * inverse,
      rr * n,
      gg * n,
      (bb + w) * n,
      0,
      255 * inverse,
      0,
      0,
      0,
      1,
      0,
    ];
  }

  /// 聚焦层：blur 与 Grayscale/Colorinverse 同时生效。
  void _withFocus(Canvas canvas, String type, void Function(Canvas) draw) {
    final amount = (state.focus[type] ?? 0).clamp(0.0, 1.0);
    if (amount <= 0) {
      draw(canvas);
      return;
    }
    final paint = Paint();
    if (state.focusBlur) {
      paint.imageFilter = ui.ImageFilter.blur(
        sigmaX: amount * 8,
        sigmaY: amount * 8,
      );
    }
    if (state.focusColor != 'None') {
      paint.colorFilter = ColorFilter.matrix(
        state.focusColor == 'Grayscale'
            ? _grayMatrix(amount, 0)
            : _grayMatrix(0, amount),
      );
    }
    canvas.saveLayer(bounds, paint);
    draw(canvas);
    canvas.restore();
  }

  void _image(Canvas canvas, StageImage layer) {
    final image = textures[catalog.image(layer.key, cg: layer.cg)];
    if (image == null || layer.alpha <= 0) return;
    final ppu = (catalog.backgroundPpu[layer.key.toLowerCase()] as num?)
        ?.toDouble();
    var w = image.width.toDouble(), h = image.height.toDouble();
    if (!layer.cg) {
      // 背景按 PPU 或长宽比换算原生尺寸；缺省 screenadapt 不缩放。
      if (ppu != null && ppu > 0) {
        w = image.width / ppu * 100;
        h = image.height / ppu * 100;
      } else if ((w / h - 1280 / 720).abs() < .01) {
        w = 1280;
        h = 720;
      }
    }
    w *= layer.widthScale;
    h *= layer.heightScale;
    final fit = layer.fit.toLowerCase();
    if (fit == 'fill') {
      w = 1280;
      h = 720;
    } else if (fit == 'width' ||
        (fit == 'showall' && w / h > 1280 / 720) ||
        (fit == 'coverall' && w / h < 1280 / 720)) {
      h = h * 1280 / w;
      w = 1280;
    } else if (fit == 'height' || fit == 'showall' || fit == 'coverall') {
      w = w * 720 / h;
      h = 720;
    }
    canvas.save();
    canvas.translate(640 + layer.x, 360 - layer.y);
    canvas.scale(layer.scaleX, layer.scaleY);
    if (layer.tiled) {
      // 平铺：以原生像素密度重复铺满布局区域。
      final tileW = image.width.toDouble(), tileH = image.height.toDouble();
      final columns = (w / tileW).ceil().clamp(1, 64),
          rows = (h / tileH).ceil().clamp(1, 64);
      canvas.save();
      canvas.clipRect(
        Rect.fromCenter(center: Offset.zero, width: w, height: h),
      );
      for (var row = 0; row < rows; row++) {
        for (var column = 0; column < columns; column++) {
          canvas.drawImage(
            image,
            Offset(-w / 2 + column * tileW, h / 2 - (row + 1) * tileH),
            Paint()
              ..color = Colors.white.withValues(alpha: layer.alpha.clamp(0, 1))
              ..filterQuality = FilterQuality.medium,
          );
        }
      }
      canvas.restore();
    } else {
      canvas.drawImageRect(
        image,
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        Rect.fromCenter(center: Offset.zero, width: w, height: h),
        Paint()
          ..color = Colors.white.withValues(alpha: layer.alpha.clamp(0, 1))
          ..filterQuality = FilterQuality.medium,
      );
    }
    canvas.restore();
  }

  /// gridbg / verticalbg / largebg / largeimg 的多图拼接。
  void _largeScene(Canvas canvas, LargeScene scene, {double extraScale = 1}) {
    if (scene.alpha <= 0 || scene.tiles.isEmpty) return;
    final init = _initPosition(scene);
    canvas.save();
    canvas.translate(640 + init.dx + scene.x, 360 - init.dy - scene.y);
    canvas.scale(scene.scaleX * extraScale, scene.scaleY * extraScale);
    final total = _sceneBounds(scene);
    canvas.translate(-total.width / 2, -total.height / 2);
    var offsetX = 0.0, offsetY = 0.0;
    for (var i = 0; i < scene.tiles.length; i++) {
      double w, h, x, y;
      if (scene.layout == 'vertical') {
        w = scene.solidWidths.first;
        h = scene.solidHeights[i];
        x = 0;
        y = offsetY;
        offsetY += h;
      } else if (scene.layout == 'large') {
        w = scene.solidWidths[i];
        h = scene.solidHeights.first;
        x = offsetX;
        y = 0;
        offsetX += w;
      } else {
        w = scene.solidWidths[i % 2];
        h = scene.solidHeights[i ~/ 2];
        x = i % 2 == 0 ? 0 : scene.solidWidths[0];
        y = scene.solidHeights[0] * (i ~/ 2);
      }
      final image =
          textures[catalog.image(scene.tiles[i].key, cg: scene.tiles[i].cg)];
      if (image != null) {
        canvas.drawImageRect(
          image,
          Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
          Rect.fromLTWH(x, y, w, h),
          Paint()
            ..color = Colors.white.withValues(alpha: scene.alpha.clamp(0, 1))
            ..filterQuality = FilterQuality.medium,
        );
      }
    }
    canvas.restore();
  }

  Size _sceneBounds(LargeScene scene) {
    if (scene.layout == 'vertical') {
      return Size(
        scene.solidWidths.first,
        scene.solidHeights.fold(0, (a, b) => a + b),
      );
    }
    if (scene.layout == 'large') {
      return Size(
        scene.solidWidths.fold(0, (a, b) => a + b),
        scene.solidHeights.first,
      );
    }
    return Size(
      scene.solidWidths.fold(0, (a, b) => a + b),
      scene.solidHeights.fold(0, (a, b) => a + b),
    );
  }

  Offset _initPosition(LargeScene scene) {
    final mode = scene.initPositionMode;
    if (mode.isEmpty || mode == 'default') {
      if (scene.layout == 'vertical') {
        return Offset(0, -scene.solidHeights.last / 2);
      }
      if (scene.layout == 'large') {
        return Offset(scene.solidWidths.last / 2, 0);
      }
      return Offset(scene.solidWidths.last / 2, -scene.solidHeights.last / 2);
    }
    if (mode == 'center') return Offset.zero;
    final total = _sceneBounds(scene);
    if (mode == 'upperleft') {
      return Offset((total.width - 1280) / 2, (720 - total.height) / 2);
    }
    if (mode == 'lowercenter') {
      return Offset(0, (total.height - 720) / 2);
    }
    return Offset.zero;
  }

  void _avgDisplays(Canvas canvas, String slot) {
    for (final item in state.avgDisplays.values.where((i) => i.slot == slot)) {
      final image = textures[catalog.image(item.name)];
      if (image == null || item.alpha <= 0) continue;
      canvas.drawImageRect(
        image,
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        Rect.fromCenter(
          center: const Offset(640, 360),
          width: 1280,
          height: 720,
        ),
        Paint()
          ..color = Colors.white.withValues(alpha: item.alpha.clamp(0, 1))
          ..filterQuality = FilterQuality.medium,
      );
    }
  }

  void _cgItem(Canvas canvas, CgItem item) {
    final image = textures[catalog.image(item.image, kind: 'images')];
    if (image == null || item.alpha <= 0) return;
    final focusAmount = (state.focus['cgitem:${item.key}'] ?? 0).clamp(
      0.0,
      1.0,
    );
    if (focusAmount > 0) {
      final paint = Paint();
      if (state.focusBlur) {
        paint.imageFilter = ui.ImageFilter.blur(
          sigmaX: focusAmount * 8,
          sigmaY: focusAmount * 8,
        );
      }
      if (state.focusColor != 'None') {
        paint.colorFilter = ColorFilter.matrix(
          state.focusColor == 'Grayscale'
              ? _grayMatrix(focusAmount, 0)
              : _grayMatrix(0, focusAmount),
        );
      }
      canvas.saveLayer(bounds, paint);
      _drawCgItem(canvas, item, image);
      canvas.restore();
      return;
    }
    _drawCgItem(canvas, item, image);
  }

  void _drawCgItem(Canvas canvas, CgItem item, ui.Image image) {
    var w = item.width > 0 ? item.width : image.width.toDouble();
    var h = item.height > 0 ? item.height : image.height.toDouble();
    w *= item.scale;
    h *= item.scale;
    canvas.save();
    canvas.translate(640 + item.x, 360 + item.y);
    canvas.rotate(item.rotation * math.pi / 180);
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: item.alpha.clamp(0, 1))
      ..filterQuality = FilterQuality.medium;
    if (item.tint != null) {
      paint.colorFilter = ColorFilter.mode(
        item.tint!.withValues(alpha: 1),
        BlendMode.modulate,
      );
    }
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromCenter(center: Offset.zero, width: w, height: h),
      paint,
    );
    canvas.restore();
  }

  void _showItem(Canvas canvas, ShowItem item) {
    if (item.alpha <= 0) return;
    final image = item.image.isEmpty
        ? null
        : textures[catalog.image(item.image, kind: 'images')];
    final centerX = 640 + item.offsetX, centerY = 360 - item.offsetY;
    if (item.style == 'cutin') {
      // 参考端窗口宽度缺省 = 图片宽度（无图回退 100）。
      final targetW = item.width.isNaN
          ? (image?.width.toDouble() ?? 100)
          : item.width;
      var x0 = -item.maskW / 2;
      if (item.fadeStyle == 'horiz_expand_left2right') x0 = -targetW / 2;
      if (item.fadeStyle == 'horiz_expand_right2left') {
        x0 = targetW / 2 - item.maskW;
      }
      var y0 = -item.maskH / 2;
      if (item.fadeStyle == 'vert_expand_top2bottom') y0 = -360;
      if (item.fadeStyle == 'vert_expand_bottom2top') y0 = 360 - item.maskH;
      final rect = Rect.fromLTWH(
        centerX + x0,
        centerY + y0,
        item.maskW,
        item.maskH,
      );
      // 全屏压暗板在窗口裁剪之外：alpha 随窗口展开度（参考端 p.alpha = s * e）。
      final progress = item.fadeStyle == 'fade'
          ? item.alpha
          : (item.fadeStyle.startsWith('horiz')
                ? item.maskW / targetW
                : item.maskH / 720);
      canvas.drawRect(
        bounds,
        Paint()
          ..color = Colors.black.withValues(
            alpha: (item.blackAlpha * progress).clamp(0.0, 1.0),
          ),
      );
      canvas.save();
      canvas.clipRect(rect);
      canvas.drawRect(
        rect,
        Paint()..color = const Color(0xff313131).withValues(alpha: item.alpha),
      );
      if (image != null) {
        canvas.drawImageRect(
          image,
          Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
          Rect.fromCenter(
            center: Offset(centerX, centerY),
            width: image.width.toDouble(),
            height: image.height.toDouble(),
          ),
          Paint()
            ..color = Colors.white.withValues(alpha: item.alpha)
            ..filterQuality = FilterQuality.medium,
        );
      }
      canvas.restore();
      // 顶部横幅：参考端为反转后的对话栏纹理，染黑、透明度 0.706。
      final header = sprites['showitem_cutin_header'];
      if (header != null && rect.width > 0) {
        canvas.drawImageRect(
          header,
          Rect.fromLTWH(
            0,
            0,
            header.width.toDouble(),
            header.height.toDouble(),
          ),
          Rect.fromLTWH(rect.left, rect.top - 200, rect.width, 200),
          Paint()
            ..color = const Color(0xff201d25)
                .withValues(alpha: .706 * item.alpha)
            ..filterQuality = FilterQuality.medium,
        );
      }
      return;
    }
    // photo：黑底 + 九宫格相框 + 原图；相框与原图整体随 alpha 淡入淡出（参考端 root alpha）。
    canvas.save();
    canvas.drawRect(
      bounds,
      Paint()
        ..color = Colors.black.withValues(alpha: item.blackAlpha * item.alpha),
    );
    final frame = sprites['showitem_photo_frame'];
    final imageW = image?.width.toDouble() ?? 100,
        imageH = image?.height.toDouble() ?? 100;
    final frameRect = Rect.fromCenter(
      center: Offset(centerX, centerY),
      width: imageW + 64,
      height: imageH + 64,
    );
    canvas.saveLayer(
      bounds,
      Paint()
        ..color = Colors.white.withValues(alpha: item.alpha.clamp(0.0, 1.0)),
    );
    if (frame != null) {
      _nineSlice(canvas, frame, frameRect, 32);
    }
    if (image != null) {
      canvas.drawImageRect(
        image,
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        Rect.fromCenter(
          center: Offset(centerX, centerY),
          width: imageW,
          height: imageH,
        ),
        Paint()..filterQuality = FilterQuality.medium,
      );
    }
    canvas.restore();
    canvas.restore();
  }

  void _nineSlice(Canvas canvas, ui.Image frame, Rect rect, double border) {
    final src = Rect.fromLTWH(
      0,
      0,
      frame.width.toDouble(),
      frame.height.toDouble(),
    );
    final corners = [
      (
        Rect.fromLTWH(0, 0, border, border),
        Rect.fromLTWH(rect.left, rect.top, border, border),
      ),
      (
        Rect.fromLTWH(src.width - border, 0, border, border),
        Rect.fromLTWH(rect.right - border, rect.top, border, border),
      ),
      (
        Rect.fromLTWH(0, src.height - border, border, border),
        Rect.fromLTWH(rect.left, rect.bottom - border, border, border),
      ),
      (
        Rect.fromLTWH(src.width - border, src.height - border, border, border),
        Rect.fromLTWH(
          rect.right - border,
          rect.bottom - border,
          border,
          border,
        ),
      ),
    ];
    final edges = [
      (
        Rect.fromLTWH(border, 0, src.width - border * 2, border),
        Rect.fromLTWH(
          rect.left + border,
          rect.top,
          rect.width - border * 2,
          border,
        ),
      ),
      (
        Rect.fromLTWH(
          border,
          src.height - border,
          src.width - border * 2,
          border,
        ),
        Rect.fromLTWH(
          rect.left + border,
          rect.bottom - border,
          rect.width - border * 2,
          border,
        ),
      ),
      (
        Rect.fromLTWH(0, border, border, src.height - border * 2),
        Rect.fromLTWH(
          rect.left,
          rect.top + border,
          border,
          rect.height - border * 2,
        ),
      ),
      (
        Rect.fromLTWH(
          src.width - border,
          border,
          border,
          src.height - border * 2,
        ),
        Rect.fromLTWH(
          rect.right - border,
          rect.top + border,
          border,
          rect.height - border * 2,
        ),
      ),
    ];
    final paint = Paint()..filterQuality = FilterQuality.medium;
    for (final (s, d) in [...corners, ...edges]) {
      canvas.drawImageRect(frame, s, d, paint);
    }
    canvas.drawImageRect(
      frame,
      Rect.fromLTWH(
        border,
        border,
        src.width - border * 2,
        src.height - border * 2,
      ),
      Rect.fromLTWH(
        rect.left + border,
        rect.top + border,
        rect.width - border * 2,
        rect.height - border * 2,
      ),
      paint,
    );
  }

  void _cutinWindow({required Canvas c, required CutinWindow window}) {
    if (window.alpha <= 0 || window.maskW <= 0 || window.maskH <= 0) return;
    var x0 = -window.maskW / 2;
    switch (window.fadeStyle) {
      case 'horiz_expand_left2right':
        x0 = -window.targetW / 2;
      case 'horiz_expand_right2left':
        x0 = window.targetW / 2 - window.maskW;
    }
    var y0 = -window.maskH / 2;
    switch (window.fadeStyle) {
      case 'vert_expand_top2bottom':
        y0 = -360;
      case 'vert_expand_bottom2top':
        y0 = 360 - window.maskH;
    }
    final rect = Rect.fromLTWH(
      window.rootX + x0,
      window.rootY + y0,
      window.maskW,
      window.maskH,
    );
    c.save();
    c.clipRect(rect);
    c.drawRect(
      rect,
      Paint()..color = const Color(0xff898989).withValues(alpha: window.alpha),
    );
    c.save();
    c.translate(window.rootX + window.contentX, window.rootY + window.contentY);
    c.scale(window.zoom);
    for (final character in window.characters) {
      _drawCharacterArt(
        c,
        character.name,
        position: Offset(window.charOffsetX, 360 - window.charOffsetY),
        scale: 1,
        alpha: window.alpha * character.alpha,
        brightness: 1,
      );
    }
    c.restore();
    c.restore();
  }

  void _interlude(Canvas canvas, InterludeFrame frame) {
    if (frame.alpha <= 0) return;
    final center = Offset(640 + frame.offset.dx, 360 - frame.offset.dy);
    final terminal =
        frame.maskId == 'group_interclude_square_common' &&
        frame.elements['avatar']?.visible == true;
    final terminalScale = terminal ? .65 : 1.0;
    final width = frame.size.dx * frame.templateScale.dx * terminalScale;
    final height = frame.size.dy * frame.templateScale.dy * terminalScale;
    if (width <= 0 || height <= 0) return;
    final rect = Rect.fromCenter(center: center, width: width, height: height);
    canvas.save();
    if (frame.maskId == 'ui_cutin_mask_vertical' ||
        frame.maskId == 'ui_cutin_mask_horizon') {
      // 切入遮罩：仅裁剪区域，无窗口装饰。
      canvas.clipRect(rect);
      _interludeElements(canvas, frame, rect);
      canvas.restore();
      return;
    }
    if (terminal) {
      canvas.drawRect(
        rect,
        Paint()
          ..color = const Color(0xff6f706e)
              .withValues(alpha: frame.alpha * .72),
      );
    } else {
      final iconBack = sprites['interlude_icon_back'];
      final gradient = sprites['interlude_gradient_v'];
      final commonFrame = sprites['interlude_common_frame'];
      if (iconBack != null) {
        canvas.drawImageRect(
          iconBack,
          Rect.fromLTWH(
            0,
            0,
            iconBack.width.toDouble(),
            iconBack.height.toDouble(),
          ),
          rect,
          Paint()
            ..color = Colors.white.withValues(alpha: frame.alpha)
            ..filterQuality = FilterQuality.medium,
        );
      } else {
        canvas.drawRect(
          rect,
          Paint()
            ..color = const Color(0xff1c1c1c).withValues(alpha: frame.alpha),
        );
      }
      if (gradient != null) {
        canvas.drawImageRect(
          gradient,
          Rect.fromLTWH(
            0,
            0,
            gradient.width.toDouble(),
            gradient.height.toDouble(),
          ),
          rect.deflate(18),
          Paint()
            ..color = Colors.white.withValues(alpha: frame.alpha)
            ..filterQuality = FilterQuality.medium,
        );
      }
      if (frame.maskId == 'group_interclude_square_common' &&
          commonFrame != null) {
        canvas.drawImageRect(
          commonFrame,
          Rect.fromLTWH(
            0,
            0,
            commonFrame.width.toDouble(),
            commonFrame.height.toDouble(),
          ),
          Rect.fromCenter(center: center, width: 236, height: 236),
          Paint()
            ..color = Colors.white.withValues(alpha: frame.alpha)
            ..filterQuality = FilterQuality.medium,
        );
      }
    }
    canvas.clipRect(rect.deflate(18));
    _interludeElements(canvas, frame, rect);

    canvas.restore();
    if (terminal) _drawTerminalOverlay(canvas, frame, rect);
    _drawInterludeVoice(canvas, frame, rect);
    // 名称标签：方形模板右下角；其余模板显示白色旁白字。
    if (frame.charName.isNotEmpty && !terminal) {
      final square = frame.maskId == 'group_interclude_square_common';
      final tp = TextPainter(
        text: TextSpan(
          text: translateLabel(frame.charName),
          style: TextStyle(
            fontFamily: fontFamily,
            fontSize: square ? 18 : 24,
            color: square ? const Color(0xff323232) : Colors.white,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final labelOffset = square
          ? Offset(center.dx - width / 2 - 125, center.dy + height / 2 - 60)
          : Offset(center.dx - width / 2, center.dy + height / 2 - 40);
      final plate =
          sprites[square ? 'interlude_icon_back' : 'interlude_icon_back'];
      if (square && plate != null) {
        canvas.drawImageRect(
          plate,
          Rect.fromLTWH(0, 0, plate.width.toDouble(), plate.height.toDouble()),
          Rect.fromCenter(
            center: labelOffset + const Offset(20, 0),
            width: 40,
            height: 40,
          ),
          Paint()
            ..color = Colors.white.withValues(alpha: frame.alpha)
            ..filterQuality = FilterQuality.medium,
        );
        tp.paint(canvas, labelOffset + const Offset(44, 0));
      } else {
        tp.paint(canvas, labelOffset);
      }
    }
  }

  String translateLabel(String text) => text;

  void _drawInterludeVoice(Canvas canvas, InterludeFrame frame, Rect window) {
    if (!frame.voiceActive || window.width <= 0 || window.height <= 0) return;
    final scale = (window.width / 300).clamp(.65, 1.4).toDouble();
    final centerY = window.bottom + 22 * scale;
    final barWidth = 2.2 * scale;
    final gap = 3.4 * scale;
    final clusterWidth = 11 * gap;
    final groupGap = 14 * scale;
    final leftStart = window.center.dx - groupGap / 2 - clusterWidth;
    final rightStart = window.center.dx + groupGap / 2;
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: frame.alpha * .78);

    for (var group = 0; group < 2; group++) {
      final start = group == 0 ? leftStart : rightStart;
      for (var i = 0; i < 10; i++) {
        final oscillation = math.sin(
          frame.voicePhase * 5 + i * 1.73 + group * 2.1,
        );
        final secondary = math.sin(frame.voicePhase * 2.7 + i * .83);
        final height =
            ((5 + (oscillation.abs() * .65 + secondary.abs() * .35) * 15) *
                    scale)
                .toDouble();
        canvas.drawRect(
          Rect.fromLTWH(
            start + i * gap,
            centerY - height / 2,
            barWidth,
            height,
          ),
          paint,
        );
      }
    }
  }

  void _drawTerminalOverlay(Canvas canvas, InterludeFrame frame, Rect window) {
    final scale = (window.width / 300).clamp(.65, 1.4).toDouble();
    final linePaint = Paint()
      ..color = Colors.white.withValues(alpha: frame.alpha * .9)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6 * scale;
    canvas.drawRect(window.deflate(5 * scale), linePaint);
    final cornerPaint = Paint()
      ..color = Colors.white.withValues(alpha: frame.alpha);
    final cornerSize = 7 * scale;
    for (final point in [
      window.topLeft,
      window.topRight,
      window.bottomLeft,
      window.bottomRight,
    ]) {
      canvas.drawRect(
        Rect.fromCenter(center: point, width: cornerSize, height: cornerSize),
        cornerPaint,
      );
    }

    if (frame.charName.isEmpty) return;
    final fontSize = 20 * scale;
    final text = TextPainter(
      text: TextSpan(
        text: translateLabel(frame.charName),
        style: TextStyle(
          fontFamily: fontFamily,
          fontSize: fontSize,
          color: const Color(0xff252525),
          fontWeight: FontWeight.w700,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: window.width * .72);
    final plateHeight = 36 * scale;
    final plateWidth = (text.width + 48 * scale)
        .clamp(112 * scale, window.width * .9)
        .toDouble();
    final plate = Rect.fromLTWH(
      window.left - 42 * scale,
      window.bottom - plateHeight - 16 * scale,
      plateWidth,
      plateHeight,
    );
    canvas.drawRect(
      plate,
      Paint()..color = Colors.white.withValues(alpha: frame.alpha),
    );
    final markerSize = 20 * scale;
    canvas.drawRect(
      Rect.fromLTWH(
        plate.left + 9 * scale,
        plate.center.dy - markerSize / 2,
        markerSize,
        markerSize,
      ),
      Paint()..color = const Color(0xff252525).withValues(alpha: frame.alpha),
    );
    text.paint(
      canvas,
      Offset(
        plate.left + 38 * scale,
        plate.top + (plate.height - text.height) / 2,
      ),
    );
  }

  void _interludeElements(Canvas canvas, InterludeFrame frame, Rect window) {
    for (final element in frame.elements.values) {
      if (!element.visible || element.image.isEmpty || element.alpha <= 0) {
        continue;
      }
      if (element.key == 'avatar') {
        final art = catalog.character(element.image);
        final body = art == null ? null : textures[art.body];
        final scaleX = element.scale.dx * frame.dialogCharScale.dx;
        final scaleY = element.scale.dy * frame.dialogCharScale.dy;
        final center =
            window.center +
            Offset(frame.dialogCharOffset.dx, -frame.dialogCharOffset.dy);
        if (art != null && body != null) {
          final artWidth = art.size.width > 0
              ? art.size.width
              : body.width.toDouble();
          final artHeight = art.size.height > 0
              ? art.size.height
              : body.height.toDouble();
          final bodyScaleX = artWidth / body.width;
          final bodyScaleY = artHeight / body.height;
          final faceRect = art.faceRect == null
              ? null
              : Rect.fromLTWH(
                  art.faceRect!.left * bodyScaleX,
                  art.faceRect!.top * bodyScaleY,
                  art.faceRect!.width * bodyScaleX,
                  art.faceRect!.height * bodyScaleY,
                );
          final isTerminal = frame.maskId == 'group_interclude_square_common';
          final contentScaleX = faceRect == null && isTerminal
              ? window.width / frame.size.dx
              : 1.0;
          final contentScaleY = faceRect == null && isTerminal
              ? window.height / frame.size.dy
              : 1.0;
          final drawScaleX = scaleX * contentScaleX;
          final drawScaleY = scaleY * contentScaleY;
          final placementCenter = faceRect == null && isTerminal
              ? Offset(640 + element.offset.dx, 360 + element.offset.dy) +
                    Offset(
                      frame.dialogCharOffset.dx,
                      -frame.dialogCharOffset.dy,
                    )
              : center;
          final origin = faceRect == null
              ? Offset(
                  placementCenter.dx -
                      artWidth * drawScaleX / 2 +
                      art.position.dx * drawScaleX,
                  placementCenter.dy -
                      artHeight * drawScaleY / 2 +
                      (isTerminal ? 1 : -1) * art.position.dy * drawScaleY,
                )
              : Offset(
                  center.dx - faceRect.center.dx * scaleX,
                  center.dy - faceRect.center.dy * scaleY,
                );
          final target = Rect.fromLTWH(
            origin.dx,
            origin.dy,
            artWidth * drawScaleX,
            artHeight * drawScaleY,
          );
          canvas.drawImageRect(
            body,
            Rect.fromLTWH(0, 0, body.width.toDouble(), body.height.toDouble()),
            target,
            Paint()
              ..color = Colors.white.withValues(
                alpha: element.alpha * frame.alpha,
              )
              ..filterQuality = FilterQuality.medium,
          );
          final face = art.face == null ? null : textures[art.face];
          if (face != null && faceRect != null) {
            final faceTarget = Rect.fromLTWH(
              origin.dx + faceRect.left * scaleX,
              origin.dy + faceRect.top * scaleY,
              faceRect.width * scaleX,
              faceRect.height * scaleY,
            );
            canvas.drawImageRect(
              face,
              Rect.fromLTWH(
                0,
                0,
                face.width.toDouble(),
                face.height.toDouble(),
              ),
              faceTarget,
              Paint()
                ..color = Colors.white.withValues(
                  alpha: element.alpha * frame.alpha,
                )
                ..filterQuality = FilterQuality.medium,
            );
          }
          continue;
        }
        final image = textures[catalog.image(element.image, kind: 'cutin')];
        if (image == null) continue;
        final source = Rect.fromLTWH(
          0,
          0,
          image.width.toDouble(),
          image.height.toDouble(),
        );
        final target = Rect.fromCenter(
          center: center,
          width: window.width * .9 * scaleX,
          height: window.height * .9 * scaleY,
        );
        final fitted = applyBoxFit(BoxFit.contain, source.size, target.size);
        canvas.drawImageRect(
          image,
          Alignment.center.inscribe(fitted.source, source),
          Alignment.center.inscribe(fitted.destination, target),
          Paint()
            ..color = Colors.white.withValues(
              alpha: element.alpha * frame.alpha,
            )
            ..filterQuality = FilterQuality.medium,
        );
        continue;
      }
      final image =
          textures[catalog.image(
            element.image,
            kind: element.key == 'bg' ? 'background' : 'cutin',
          )];
      if (image == null) continue;
      if (element.key == 'bg') {
        canvas.drawImageRect(
          image,
          Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
          window,
          Paint()
            ..color = Colors.white.withValues(
              alpha: element.alpha * frame.alpha,
            )
            ..filterQuality = FilterQuality.medium,
        );
        continue;
      }
      canvas.drawImageRect(
        image,
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        Rect.fromCenter(
          center: window.center + element.offset,
          width: image.width * element.scale.dx,
          height: image.height * element.scale.dy,
        ),
        Paint()
          ..color = Colors.white.withValues(alpha: element.alpha * frame.alpha)
          ..filterQuality = FilterQuality.medium,
      );
    }
  }

  void _character(Canvas canvas, StageCharacter node) {
    final art = catalog.character(node.name);
    if (art == null) return;
    final body = textures[art.body];
    if (body == null || node.alpha <= 0) return;
    final w = art.size.width > 0 ? art.size.width : body.width.toDouble();
    final h = art.size.height > 0 ? art.size.height : body.height.toDouble();
    final x = switch (node.slot) {
      'l' => 440.0,
      'r' => 840.0,
      _ => 640.0,
    };
    final motionDx = node.actionX + node.zoomShiftX + node.shakeOffsetX;
    final motionDy =
        -node.actionY - node.zoomShiftY - node.jumpOffsetY + node.shakeOffsetY;
    _drawCharacterArt(
      canvas,
      node.name,
      position: Offset(
        x - w / 2 + art.position.dx + motionDx,
        720 - h / 2 - art.position.dy + motionDy,
      ),
      scale: 1,
      actionScale: Offset(node.scaleX, node.scaleY),
      alpha: node.alpha * node.contentAlpha,
      brightness: node.brightness,
      rotationDeg: node.rotationDeg,
      blackStart: node.blackStart,
      blackEnd: node.blackEnd,
      topLeftAnchor: true,
    );
  }

  /// 统一的立绘绘制：合成身体与表情切片，支持运动变换、黑边与滤镜。
  void _drawCharacterArt(
    Canvas canvas,
    String name, {
    required Offset position,
    required double scale,
    Offset actionScale = const Offset(1, 1),
    required double alpha,
    required double brightness,
    double rotationDeg = 0,
    double blackStart = -1,
    double blackEnd = -1,
    bool topLeftAnchor = false,
  }) {
    final art = catalog.character(name);
    if (art == null) return;
    final body = textures[art.body];
    if (body == null || alpha <= 0) return;
    final w = art.size.width > 0 ? art.size.width : body.width.toDouble();
    final h = art.size.height > 0 ? art.size.height : body.height.toDouble();
    canvas.save();
    canvas.translate(position.dx, position.dy);
    if (!topLeftAnchor) {
      canvas.translate(-w / 2, -h / 2);
    }
    canvas.scale(scale * actionScale.dx, scale * actionScale.dy);
    canvas.translate(w / 2, h / 2);
    canvas.rotate(rotationDeg * math.pi / 180);
    canvas.translate(-w / 2, -h / 2);
    final b = brightness.clamp(0.0, 1.0).toDouble();
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: alpha.clamp(0.0, 1.0).toDouble())
      ..filterQuality = FilterQuality.medium
      ..colorFilter = ColorFilter.matrix([
        b,
        0,
        0,
        0,
        0,
        0,
        b,
        0,
        0,
        0,
        0,
        0,
        b,
        0,
        0,
        0,
        0,
        0,
        1,
        0,
      ]);
    final rect = Rect.fromLTWH(0, 0, w, h);
    canvas.saveLayer(rect.inflate(64), paint);
    canvas.save();
    canvas.scale(w / body.width, h / body.height);
    canvas.drawImage(body, Offset.zero, Paint());
    final face = art.face == null ? null : textures[art.face];
    if (face != null && art.faceRect != null) {
      canvas.drawImageRect(
        face,
        Rect.fromLTWH(0, 0, face.width.toDouble(), face.height.toDouble()),
        art.faceRect!,
        Paint(),
      );
    }
    canvas.restore();
    // 边缘黑化：顶部到 bstart 全黑，bstart 到 bend 渐隐。
    if (blackStart.isFinite && blackEnd.isFinite && blackEnd > 0) {
      final start = blackStart.clamp(0.0, 1.0).toDouble(),
          end = blackEnd.clamp(0.0, 1.0).toDouble();
      final gradientHeight = math.max(1.0, end * h);
      canvas.drawRect(
        Rect.fromLTWH(0, 0, w, gradientHeight),
        Paint()
          ..blendMode = BlendMode.srcATop
          ..shader = ui.Gradient.linear(
            Offset(0, 0),
            Offset(0, gradientHeight),
            [
              const Color(0xff000000),
              const Color(0xff000000),
              const Color(0x00000000),
            ],
            [0.0, (start * h / gradientHeight).clamp(0.0, 1.0), 1.0],
          ),
      );
    }
    canvas.restore();
    canvas.restore();
  }

  void _curtain(Canvas canvas, int direction, CurtainState item) {
    final alpha = item.alpha.clamp(0.0, 1.0);
    if (alpha <= 0 || item.fill <= 0) return;
    final angle = _curtainAngles[direction]! * math.pi / 180;
    final v = Offset(math.sin(angle), -math.cos(angle));
    final anchor = _curtainAnchors[direction];
    double threshold;
    if (anchor != null) {
      threshold = anchor.$1 * v.dx + anchor.$2 * v.dy + 1600 * item.fill;
    } else {
      final projections = [
        Offset(0, 0),
        Offset(1280, 0),
        Offset(1280, 720),
        Offset(0, 720),
      ].map((p) => p.dx * v.dx + p.dy * v.dy).toList();
      final min = projections.reduce(math.min),
          max = projections.reduce(math.max);
      if ((max - min).abs() <= 1e-6) return;
      threshold = min + (max - min) * item.fill;
    }
    final diagonal = anchor != null;
    final inset = (item.grad || !diagonal) ? 20.0 : 0.0;
    final solidThreshold = threshold - inset;
    final solid = _halfPlane(v, solidThreshold);
    canvas.save();
    canvas.clipPath(solid);
    canvas.drawRect(
      bounds,
      Paint()..color = Colors.black.withValues(alpha: alpha),
    );
    canvas.restore();
    if (item.grad && inset > 0) {
      final band = Path.combine(
        PathOperation.intersect,
        _halfPlane(v, threshold),
        _halfPlane(-v, -solidThreshold),
      );
      canvas.save();
      canvas.clipPath(band);
      canvas.drawRect(
        bounds,
        Paint()
          ..shader = ui.Gradient.linear(v * solidThreshold, v * threshold, [
            Colors.black.withValues(alpha: alpha),
            Colors.black.withValues(alpha: 0),
          ]),
      );
      canvas.restore();
    }
  }

  /// 构造半平面 p·v <= threshold 的裁剪路径。
  Path _halfPlane(Offset v, double threshold) {
    final perp = Offset(-v.dy, v.dx);
    const far = 4000.0;
    final base = v * threshold;
    return Path()
      ..moveTo((base + perp * far).dx, (base + perp * far).dy)
      ..lineTo((base - perp * far).dx, (base - perp * far).dy)
      ..lineTo(
        (base - perp * far - v * far).dx,
        (base - perp * far - v * far).dy,
      )
      ..lineTo(
        (base + perp * far - v * far).dx,
        (base + perp * far - v * far).dy,
      )
      ..close();
  }

  void _blocker(Canvas canvas) {
    final alpha = state.blockerAlpha.clamp(0.0, 1.0);
    if (alpha <= 0 && state.blockerImage.isEmpty) return;
    if (['slider', 'verticalslider'].contains(state.blockerStyle)) {
      final mask = slideMask;
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
        final rect = vertical
            ? Rect.fromLTWH(
                0,
                state.blockerInverse ? 720 - extent : 0,
                1280,
                extent,
              )
            : Rect.fromLTWH(
                state.blockerInverse ? 1280 - extent : 0,
                0,
                extent,
                720,
              );
        canvas.drawRect(rect, Paint()..color = state.blockerColor);
      }
    } else if (state.blockerImage.isNotEmpty) {
      final image = textures[catalog.image(state.blockerImage, cg: true)];
      if (image != null) {
        final tint = ColorFilter.matrix([
          state.blockerColor.r,
          0,
          0,
          0,
          0,
          0,
          state.blockerColor.g,
          0,
          0,
          0,
          0,
          0,
          state.blockerColor.b,
          0,
          0,
          0,
          0,
          0,
          1,
          0,
        ]);
        canvas.drawImageRect(
          image,
          Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
          bounds,
          Paint()
            ..color = Colors.white.withValues(alpha: alpha)
            ..colorFilter = tint
            ..filterQuality = FilterQuality.medium,
        );
      }
    } else {
      canvas.drawRect(
        bounds,
        Paint()..color = state.blockerColor.withValues(alpha: alpha),
      );
    }
  }

  double _track(double t, List<(double, double)> keys) {
    if (t <= keys.first.$1) return keys.first.$2;
    for (var i = 1; i < keys.length; i++) {
      final current = keys[i], previous = keys[i - 1];
      if (t <= current.$1) {
        final local = (t - previous.$1) / (current.$1 - previous.$1);
        return previous.$2 + (current.$2 - previous.$2) * local;
      }
    }
    return keys.last.$2;
  }

  /// animtext 地点印章：按参考端 5 秒关键帧时间线绘制。
  void _stamp(Canvas canvas, LocationStamp stamp) {
    final t = stamp.elapsedMs.clamp(0.0, 5000.0) / 1000;
    final alpha = _track(t, [(0.0, 0.0), (1 / 3, 1.0), (4.0, 1.0), (5.0, 0.0)]);
    if (alpha <= 0) return;
    final backShadow = sprites['stamp_back_shadow'];
    final backGradient = sprites['stamp_back_gradient'];
    final frameOuter = sprites['stamp_frame_outer'];
    final frameInner = sprites['stamp_frame_inner'];
    final iconBack = sprites['stamp_icon_back'];
    final iconComps = sprites['stamp_icon_comps'];
    final iconStart = sprites['stamp_icon_start'];
    canvas.save();
    canvas.translate(640 + stamp.position.dx, 360 - stamp.position.dy);
    canvas.saveLayer(
      const Rect.fromLTWH(-500, -500, 1000, 1000),
      Paint()..color = Colors.white.withValues(alpha: alpha),
    );
    if (backShadow != null) {
      canvas.drawImageRect(
        backShadow,
        Rect.fromLTWH(
          0,
          0,
          backShadow.width.toDouble(),
          backShadow.height.toDouble(),
        ),
        const Rect.fromLTWH(-244.14, -104.53, 520, 209.06),
        Paint()..filterQuality = FilterQuality.medium,
      );
    }
    // 外框（frame_outer）：尺寸关键帧 25→140.01，2.5s 后开始淡出（参考端 l 元素）。
    if (frameOuter != null) {
      final outerSize = _track(t, [
        (0.0, 25.0),
        (1 / 3, 109.74),
        (5 / 6, 123.0),
        (5.0, 140.01),
      ]);
      final outerAlpha = _track(t, [(0.0, 1.0), (2.5, 1.0), (4.5, 0.0)]);
      if (outerAlpha > 0) {
        canvas.drawImageRect(
          frameOuter,
          Rect.fromLTWH(
            0,
            0,
            frameOuter.width.toDouble(),
            frameOuter.height.toDouble(),
          ),
          Rect.fromCenter(
            center: const Offset(-143.42, 0),
            width: outerSize,
            height: outerSize,
          ),
          Paint()
            ..color = Colors.white.withValues(alpha: outerAlpha)
            ..filterQuality = FilterQuality.medium,
        );
      }
    }
    // 图标组整体 alpha：4.5~5s 额外淡出（参考端 u 容器）。
    final iconGroupAlpha = _track(t, [(0.0, 1.0), (4.5, 1.0), (5.0, 0.0)]);
    if (iconBack != null) {
      canvas.drawImageRect(
        iconBack,
        Rect.fromLTWH(
          0,
          0,
          iconBack.width.toDouble(),
          iconBack.height.toDouble(),
        ),
        Rect.fromCenter(
          center: const Offset(-143.42, 0),
          width: 74,
          height: 74,
        ),
        Paint()
          ..color = Colors.white.withValues(alpha: .6 * iconGroupAlpha)
          ..filterQuality = FilterQuality.medium,
      );
    }
    final innerSize = _track(t, [
      (0.0, 16.0),
      (1 / 3, 50.1),
      (5 / 6, 53.0),
      (5.0, 55.81),
    ]);
    if (frameInner != null) {
      canvas.drawImageRect(
        frameInner,
        Rect.fromLTWH(
          0,
          0,
          frameInner.width.toDouble(),
          frameInner.height.toDouble(),
        ),
        Rect.fromCenter(
          center: const Offset(-143.42, 0),
          width: innerSize,
          height: innerSize,
        ),
        Paint()
          ..color = Colors.white.withValues(alpha: .6 * iconGroupAlpha)
          ..filterQuality = FilterQuality.medium,
      );
    }
    if (iconComps != null) {
      final compsAlpha = _track(t, [
        (0.0, 0.0),
        (.95, 0.0),
        (1.1167, 1.0),
        (5.0, 1.0),
      ]);
      if (compsAlpha > 0) {
        canvas.drawImageRect(
          iconComps,
          Rect.fromLTWH(
            0,
            0,
            iconComps.width.toDouble(),
            iconComps.height.toDouble(),
          ),
          Rect.fromCenter(
            center: const Offset(-143.42, 0),
            width: 14,
            height: 42,
          ),
          Paint()
            ..color = Colors.white.withValues(
              alpha: compsAlpha * iconGroupAlpha,
            )
            ..filterQuality = FilterQuality.medium,
        );
      }
    }
    if (iconStart != null) {
      for (final (dx, dy) in [
        (-5.5, -5.5),
        (5.5, -5.5),
        (5.5, 5.5),
        (-5.5, 5.5),
      ]) {
        final startAlpha = _track(t, [
          (0.0, 0.0),
          (1 / 12, 1.0),
          (.8167, 1.0),
          (.9667, 0.0),
        ]);
        final scale = _track(t, [
          (0.0, 0.0),
          (2 / 3, .92),
          (.9167, 1.0),
          (5.0, 1.0),
        ]);
        if (startAlpha <= 0) continue;
        canvas.drawImageRect(
          iconStart,
          Rect.fromLTWH(
            0,
            0,
            iconStart.width.toDouble(),
            iconStart.height.toDouble(),
          ),
          Rect.fromCenter(
            center: Offset(-143.42 + dx * scale, dy * scale),
            width: 11,
            height: 11,
          ),
          Paint()
            ..color = Colors.white.withValues(
              alpha: startAlpha * iconGroupAlpha,
            )
            ..filterQuality = FilterQuality.medium,
        );
      }
    }
    final textX = _track(t, [
      (0.0, -121.03),
      (1 / 3, -97.31),
      (5 / 6, -93.42),
      (5.0, -85.35),
    ]);
    canvas.save();
    canvas.translate(textX, 0);
    if (backGradient != null) {
      canvas.drawImageRect(
        backGradient,
        Rect.fromLTWH(
          0,
          0,
          backGradient.width.toDouble(),
          backGradient.height.toDouble(),
        ),
        const Rect.fromLTWH(-200, -43.5, 260, 87),
        Paint()
          ..color = Colors.white.withValues(alpha: .15)
          ..filterQuality = FilterQuality.medium,
      );
    }
    final segments = stamp.segments;
    if (segments.isNotEmpty &&
        segments[0].isNotEmpty &&
        stamp.style != 'avg_only_medium') {
      _stampText(
        canvas,
        segments[0],
        30,
        FontWeight.w900,
        const Offset(0, -20),
      );
    }
    if (segments.length > 1 &&
        segments[1].isNotEmpty &&
        stamp.style != 'avg_only_heavy') {
      _stampText(canvas, segments[1], 26, FontWeight.w500, const Offset(0, 20));
    }
    canvas.restore();
    canvas.restore();
    canvas.restore();
  }

  void _stampText(
    Canvas canvas,
    String text,
    double fontSize,
    FontWeight weight,
    Offset at,
  ) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: fontFamily,
          fontSize: fontSize,
          fontWeight: weight,
          color: Colors.white,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    canvas.save();
    // 参考端文本锚点 (0,.5)：左中锚定，TextPainter 从左上绘制，需上移半行高。
    canvas.translate(at.dx, at.dy - tp.height / 2);
    tp.paint(canvas, Offset.zero);
    canvas.restore();
  }

  @override
  bool shouldRepaint(StagePainter oldDelegate) => true;
}
