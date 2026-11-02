import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:arknights_story_player/app/app.dart';
import 'package:arknights_story_player/story_player/script.dart';
import 'package:arknights_story_player/story_player/runtime/story_engine.dart';
import 'package:arknights_story_player/story_player/data/media_catalog.dart';
import 'package:arknights_story_player/story_player/ui/story_stage.dart';
import 'package:arknights_story_player/story_player/ui/story_text.dart';

void main() {
  testWidgets('入口从 PRTS 目录选择剧情，不内置关卡输入框', (tester) async {
    await tester.pumpWidget(const MyApp());
    expect(find.byKey(const Key('story-search')), findsOneWidget);
    expect(find.text('正在从 PRTS 读取剧情目录…'), findsOneWidget);
    expect(find.byKey(const Key('story-source')), findsNothing);
    // 测试环境的 HTTP 一律返回 400，等待首次目录请求落定，避免留下未完成的异步。
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('点击先补全当前文本，再推进到下一句，最后结束', (tester) async {
    final start = tester.binding.clock.now();
    final engine = StoryEngine(
      StoryScript.parse('[name="测试角色"]甲乙丙\n这是旁白'),
      elapsed: () => tester.binding.clock.now().difference(start),
    );
    try {
      await engine.start();
      await tester.pumpWidget(
        MaterialApp(
          home: StoryStage(
            engine: engine,
            catalog: MediaCatalog(
              variables: {},
              characters: {},
              backgroundPpu: {},
            ),
            textures: const {},
          ),
        ),
      );
      expect(engine.state.speaker, '测试角色');
      expect(engine.state.revealed, 0);
      await tester.tap(find.byKey(const Key('story-stage')));
      await tester.pump();
      expect(engine.state.revealed, 3);
      await tester.tap(find.byKey(const Key('story-stage')));
      await tester.pump();
      expect(engine.state.speaker, '');
      expect(engine.state.text, '这是旁白');
      await engine.advance();
      await engine.advance();
      expect(engine.finished, isTrue);
    } finally {
      engine.dispose();
    }
  });

  test('富文本隐藏字仍保留排版，颜色和粗体不会丢失', () {
    final spans = storyTextSpans(
      '<color=#ff0000>甲<b>乙</b></color>丙',
      1,
      const TextStyle(color: Colors.white),
    ).cast<TextSpan>();
    expect(spans.map((s) => s.text).join(), '甲乙丙');
    expect(spans.first.style!.color, const Color(0xffff0000));
    expect(spans.elementAt(1).style!.color, Colors.transparent);
    expect(spans.elementAt(1).style!.fontWeight, FontWeight.bold);
  });
}
