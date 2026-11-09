import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../data/media_catalog.dart';
import '../runtime/story_engine.dart';
import '../runtime/dialogue_voice.dart';
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
    this.showDialogue = true,
    this.onFastForwardStart,
    this.onFastForwardMove,
    this.onFastForwardEnd,
  });
  final StoryEngine engine;
  final MediaCatalog catalog;
  final Map<Uri, ui.Image> textures;
  final ui.Image? slideMask;
  final String fontFamily;
  final bool showDialogue;
  final ui.FragmentShader? slideMaskShader;
  final Map<String, ui.Image> sprites;

  /// 长按快进：按下进入 2 倍速，按住下滑提升到 4/8/16 倍，松手结束。
  /// 均回传全局坐标，供播放器把下滑距离换算为倍速档位。
  final void Function(Offset globalPosition)? onFastForwardStart;
  final ValueChanged<Offset>? onFastForwardMove;
  final VoidCallback? onFastForwardEnd;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: engine,
    builder: (context, _) {
      final s = engine.state;
      final base = storyDialogueStyle(fontFamily);
      final spans = storyTextSpans(s.text, s.revealed, base);
      final messageLayout = TextPainter(
        text: TextSpan(children: spans),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: 735);
      final messageTop =
          626.5 - (messageLayout.height - 89).clamp(0.0, double.infinity);
      messageLayout.dispose();
      var nameSize = 30.0;
      while (nameSize > 25) {
        final layout = TextPainter(
          text: TextSpan(
            text: s.speaker,
            style: base.copyWith(fontSize: nameSize),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        final fits = layout.width <= 312.3;
        layout.dispose();
        if (fits) break;
        nameSize--;
      }
      return FittedBox(
        fit: BoxFit.contain,
        child: SizedBox(
          width: 1280,
          height: 720,
          child: GestureDetector(
            key: const Key('story-stage'),
            behavior: HitTestBehavior.opaque,
            onTap: engine.advance,
            onLongPressStart:
                onFastForwardStart != null &&
                    engine.cursor > 0 &&
                    !engine.finished &&
                    !engine.paused &&
                    s.choices.isEmpty
                ? (details) => onFastForwardStart!(details.globalPosition)
                : null,
            onLongPressMoveUpdate: onFastForwardMove == null
                ? null
                : (details) => onFastForwardMove!(details.globalPosition),
            onLongPressEnd: onFastForwardEnd == null
                ? null
                : (_) => onFastForwardEnd!(),
            onLongPressCancel: onFastForwardEnd,
            child: Stack(
              fit: StackFit.expand,
              children: [
                CustomPaint(
                  painter: StagePainter(
                    s,
                    catalog,
                    textures,
                    slideMask,
                    slideMaskShader,
                    sprites,
                    fontFamily: fontFamily,
                  ),
                ),
                if (showDialogue && s.dialogueVisible)
                  IgnorePointer(
                    child: Opacity(
                      opacity: s.dialogueAlpha.clamp(0, 1),
                      child: Stack(
                        children: [
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            height: 182,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [
                                    Colors.transparent,
                                    Colors.black.withValues(alpha: .85),
                                  ],
                                  stops: const [0, .6],
                                ),
                              ),
                            ),
                          ),
                          Positioned(
                            left: 20.75,
                            width: 312.3,
                            top: 622.9,
                            child: Text(
                              s.speaker,
                              textAlign: TextAlign.right,
                              textScaler: TextScaler.noScaling,
                              style: base.copyWith(
                                fontSize: nameSize,
                                color: const Color(0xff929292),
                              ),
                            ),
                          ),
                          Positioned(
                            left: 344, top: 629,
                            child: ValueListenableBuilder<VoiceStatus>(
                              valueListenable: engine.voice.status,
                              builder: (context, status, _) {
                                if (status == VoiceStatus.unavailable) return const SizedBox.shrink();
                                final muted = engine.fastForwarding || engine.autoMode == 'quick_play';
                                final speaking = status == VoiceStatus.speaking;
                                final label = muted ? '快进中，语音静音' : speaking ? '正在朗读' : status == VoiceStatus.failed ? '语音暂不可用' : '语音待机';
                                return Tooltip(message: label, child: Semantics(label: label,
                                  child: Icon(muted ? Icons.volume_off_outlined : speaking ? Icons.graphic_eq : Icons.volume_up_outlined,
                                    size: 22, color: speaking ? const Color(0xffe9d995) : const Color(0xff929292))));
                              },
                            ),
                          ),
                          Positioned(
                            left: 382.28,
                            width: 735,
                            top: messageTop,
                            child: Semantics(
                              label: s.speaker.isEmpty
                                  ? StoryEngine.plainText(s.text)
                                  : '${s.speaker}：${StoryEngine.plainText(s.text)}',
                              child: ExcludeSemantics(
                                child: Text.rich(
                                  TextSpan(children: spans),
                                  textScaler: TextScaler.noScaling,
                                ),
                              ),
                            ),
                          ),
                          if (!engine.typing)
                            const Positioned(
                              right: 80,
                              bottom: 25,
                              child: Icon(
                                Icons.arrow_drop_down,
                                color: Colors.white70,
                                size: 26,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
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
                      child: IgnorePointer(
                        child: Opacity(
                          opacity: overlay.alpha.clamp(0, 1),
                          child: Transform.rotate(
                            angle: overlay.rotation * 3.141592653589793 / 180,
                            child: Text.rich(
                              TextSpan(
                                children: storyTextSpans(
                                  overlay.text,
                                  overlay.revealed,
                                  base.copyWith(
                                    fontSize: overlay.size.clamp(8, 100),
                                  ),
                                ),
                              ),
                              textAlign: switch (overlay.alignment) {
                                'center' => TextAlign.center,
                                'right' => TextAlign.right,
                                _ => TextAlign.left,
                              },
                              textScaler: TextScaler.noScaling,
                            ),
                          ),
                        ),
                      ),
                    ),
                if (s.timer != null && s.timer!.visible)
                  Positioned(
                    left: s.timer!.x,
                    top: s.timer!.y,
                    width: s.timer!.width,
                    child: IgnorePointer(
                      child: Opacity(
                        opacity: s.timer!.alpha.clamp(0, 1),
                        child: Text(
                          _formatTimer(
                            s.timer!.elapsedSeconds < 0
                                ? 0
                                : s.timer!.elapsedSeconds,
                          ),
                          style: base.copyWith(
                            fontSize: s.timer!.size.clamp(8, 100),
                          ),
                          textScaler: TextScaler.noScaling,
                        ),
                      ),
                    ),
                  ),
                if (s.choices.isNotEmpty)
                  Center(
                    child: SizedBox(
                      width: 760,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final choice in s.choices)
                            Padding(
                              padding: const EdgeInsets.all(8),
                              child: SizedBox(
                                width: double.infinity,
                                height: 64,
                                child: FilledButton(
                                  onPressed: choice.disabled
                                      ? null
                                      : () => engine.choose(choice.value),
                                  style: FilledButton.styleFrom(
                                    backgroundColor: choice.disabled
                                        ? const Color(0xff1c1c1c)
                                        : const Color(0xff303030),
                                    foregroundColor: choice.disabled
                                        ? const Color(0xff8c8c8c)
                                        : Colors.white,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                  ),
                                  child: Text(
                                    choice.label,
                                    style: base.copyWith(fontSize: 20),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

String _formatTimer(int seconds) {
  final h = (seconds ~/ 3600) % 24,
      m = (seconds % 3600) ~/ 60,
      s = seconds % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(h)}:${two(m)}:${two(s)}';
}
