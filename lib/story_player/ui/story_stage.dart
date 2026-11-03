import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../data/media_catalog.dart';
import '../runtime/story_engine.dart';
import '../stage_state.dart';
import 'stage_painter.dart';
import 'story_text.dart';

class StoryStage extends StatelessWidget {
  const StoryStage({
    super.key,
    required this.engine,
    required this.catalog,
    required this.textures,
    this.slideMask,
    this.slideMaskShader,
    this.sprites = const {},
    this.fontFamily = 'StoryNotoSans',
  });
  final StoryEngine engine;
  final MediaCatalog catalog;
  final Map<Uri, ui.Image> textures;
  final ui.Image? slideMask;
  final String fontFamily;
  final ui.FragmentShader? slideMaskShader;
  final Map<String, ui.Image> sprites;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: engine,
    builder: (context, _) {
      final s = engine.state;
      final base = TextStyle(fontFamily: fontFamily, fontSize: 24, fontWeight: FontWeight.w500, color: Colors.white, shadows: const [Shadow(color: Color(0xe6404040), blurRadius: 4)]);
      final spans = storyTextSpans(s.text, s.revealed, base);
      final messageLayout = TextPainter(text: TextSpan(children: spans), textDirection: TextDirection.ltr)..layout(maxWidth: 735);
      final messageTop = 626.5 - (messageLayout.height - 89).clamp(0.0, double.infinity);
      messageLayout.dispose();
      var nameSize = 30.0;
      while (nameSize > 25) {
        final layout = TextPainter(text: TextSpan(text: s.speaker, style: base.copyWith(fontSize: nameSize)), textDirection: TextDirection.ltr)..layout();
        final fits = layout.width <= 312.3;
        layout.dispose();
        if (fits) break;
        nameSize--;
      }
      return FittedBox(fit: BoxFit.contain, child: SizedBox(width: 1280, height: 720,
        child: GestureDetector(key: const Key('story-stage'), behavior: HitTestBehavior.opaque, onTap: engine.advance,
          child: Stack(fit: StackFit.expand, children: [
            CustomPaint(painter: StagePainter(s, catalog, textures, slideMask, slideMaskShader, sprites, fontFamily: fontFamily)),
            if (s.dialogueVisible) IgnorePointer(child: Opacity(opacity: s.dialogueAlpha.clamp(0, 1), child: Stack(children: [
              Positioned(left: 0, right: 0, bottom: 0, height: 182, child: DecoratedBox(decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.transparent, Colors.black.withValues(alpha: .85)], stops: const [0, .6])))),
              Positioned(left: 20.75, width: 312.3, top: 622.9, child: Text(s.speaker, textAlign: TextAlign.right, textScaler: TextScaler.noScaling, style: base.copyWith(fontSize: nameSize, color: const Color(0xff929292)))),
              Positioned(left: 382.28, width: 735, top: messageTop, child: Semantics(label: s.speaker.isEmpty ? StoryEngine.plainText(s.text) : '${s.speaker}：${StoryEngine.plainText(s.text)}', child: ExcludeSemantics(child: Text.rich(TextSpan(children: spans), textScaler: TextScaler.noScaling)))),
              if (!engine.typing) const Positioned(right: 80, bottom: 25, child: Icon(Icons.arrow_drop_down, color: Colors.white70, size: 26)),
            ]))),
            // 自由坐标旁白与贴纸：打字机随引擎推进。
            for (final overlay in <OverlayText>[
              if (s.subtitle != null) s.subtitle!,
              ...s.stickers.values,
            ])
              if (overlay.visible && overlay.text.isNotEmpty)
                Positioned(
                  left: overlay.x,
                  top: overlay.y,
                  width: overlay.width,
                  child: IgnorePointer(child: Opacity(opacity: overlay.alpha.clamp(0, 1), child: Transform.rotate(
                    angle: overlay.rotation * 3.141592653589793 / 180,
                    child: Text.rich(
                      TextSpan(children: storyTextSpans(overlay.text, overlay.revealed, base.copyWith(fontSize: overlay.size.clamp(8, 100)))),
                      textAlign: switch (overlay.alignment) { 'center' => TextAlign.center, 'right' => TextAlign.right, _ => TextAlign.left },
                      textScaler: TextScaler.noScaling,
                    ),
                  ))),
                ),
            if (s.timer != null && s.timer!.visible)
              Positioned(
                left: s.timer!.x,
                top: s.timer!.y,
                width: s.timer!.width,
                child: IgnorePointer(child: Opacity(opacity: s.timer!.alpha.clamp(0, 1), child: Text(
                  _formatTimer(s.timer!.elapsedSeconds < 0 ? 0 : s.timer!.elapsedSeconds),
                  style: base.copyWith(fontSize: s.timer!.size.clamp(8, 100)),
                  textScaler: TextScaler.noScaling,
                ))),
              ),
            if (s.choices.isNotEmpty) Center(child: SizedBox(width: 760, child: Column(mainAxisSize: MainAxisSize.min, children: [for (final choice in s.choices) Padding(padding: const EdgeInsets.all(8), child: SizedBox(width: double.infinity, height: 64, child: FilledButton(
              onPressed: choice.disabled ? null : () => engine.choose(choice.value),
              style: FilledButton.styleFrom(backgroundColor: choice.disabled ? const Color(0xff1c1c1c) : const Color(0xff303030), foregroundColor: choice.disabled ? const Color(0xff8c8c8c) : Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4))),
              child: Text(choice.label, style: base.copyWith(fontSize: 20)),
            )))]))),
          ]),
        ),
      ));
    },
  );
}

String _formatTimer(int seconds) {
  final h = (seconds ~/ 3600) % 24, m = (seconds % 3600) ~/ 60, s = seconds % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(h)}:${two(m)}:${two(s)}';
}
