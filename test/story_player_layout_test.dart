import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:arknights_story_player/story_player/data/asset_store.dart';
import 'package:arknights_story_player/story_player/data/media_catalog.dart';
import 'package:arknights_story_player/story_player/data/story_repository.dart';
import 'package:arknights_story_player/story_player/runtime/story_audio.dart';
import 'package:arknights_story_player/story_player/script.dart';
import 'package:arknights_story_player/story_player/ui/story_player.dart';
import 'package:arknights_story_player/story_player/ui/story_stage.dart';

void main() {
  testWidgets('开始按钮消失后舞台仍占满可用宽度并响应点击', (tester) async {
    final assets = AssetStore();
    addTearDown(assets.close);
    final story = PreparedStory(
      StoryDocument(title: '布局回归', script: StoryScript.parse('[header(is_autoable=false)]\n第一句\n第二句')),
      MediaCatalog(variables: {}, characters: {}, backgroundPpu: {}),
      assets,
      [],
    );
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: StoryPlayer(story: story, audio: SilentStoryAudio()),
        ),
      );
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (find.text('开始播放').evaluate().isEmpty &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await tester.pump();
      }
    });
    expect(find.text('开始播放'), findsOneWidget);
    expect(tester.widget<TextButton>(find.widgetWithText(TextButton, '手动')).onPressed, isNull);
    expect(tester.widget<TextButton>(find.widgetWithText(TextButton, '手动')).onLongPress, isNull);
    expect(tester.widget<IconButton>(find.byWidgetPredicate((w) => w is IconButton && w.tooltip == '自动播放')).onPressed, isNull);
    await tester.tap(find.text('开始播放'));
    await tester.pump();
    final stage = tester.widget<StoryStage>(find.byType(StoryStage));
    expect(stage.engine.state.history.single.text, '第一句');
    expect(find.text('开始播放'), findsNothing);
    expect(
      tester.getSize(find.byType(StoryStage)).width,
      tester.getSize(find.byType(Scaffold)).width,
    );
    await tester.tap(find.byKey(const Key('story-stage')));
    await tester.pump();
    expect(stage.engine.state.revealed, stage.engine.totalCharacters);
    await tester.tap(find.byKey(const Key('story-stage')));
    await tester.pump();
    expect(stage.engine.state.text, '第二句');
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
