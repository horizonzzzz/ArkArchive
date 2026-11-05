import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:arknights_story_player/story_player/story_player.dart';
import 'package:arknights_story_player/story_player/ui/story_stage.dart';

Future<StoryEngine> _mountPlayer(
  WidgetTester tester, {
  required StoryScript script,
  PlaybackCheckpoint? checkpoint,
  required List<PlaybackCheckpoint?> saved,
}) async {
  final assets = AssetStore();
  addTearDown(assets.close);
  final story = PreparedStory(
    StoryDocument(title: '观看断点测试', script: script),
    MediaCatalog(variables: {}, characters: {}, backgroundPpu: {}),
    assets,
    [],
  );
  await tester.runAsync(() async {
    await tester.pumpWidget(MaterialApp(home: StoryPlayer(
      story: story,
      audio: SilentStoryAudio(),
      checkpoint: checkpoint,
      onProgress: (value) async { saved.add(value); },
    )));
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (find.byType(StoryStage).evaluate().isEmpty &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await tester.pump();
    }
  });
  expect(find.byType(StoryStage), findsOneWidget);
  return tester.widget<StoryStage>(find.byType(StoryStage)).engine;
}

void main() {
  testWidgets('尚未开始就退出不会替换旧断点', (tester) async {
    final saved = <PlaybackCheckpoint?>[];
    await _mountPlayer(tester, script: StoryScript.parse('正文'), saved: saved);
    expect(saved, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(saved, isEmpty);
  });

  testWidgets('推进时保存，逐字显示不重复写入，后台补存，播完清除', (tester) async {
    final saved = <PlaybackCheckpoint?>[];
    final engine = await _mountPlayer(tester,
      script: StoryScript.parse('第一句\n第二句'), saved: saved);
    await tester.tap(find.text('开始播放'));
    await tester.pump();
    expect(saved.length, 2);
    expect(saved.first!.cursor, 0);
    expect(saved.last!.cursor, 1);
    await tester.pump(const Duration(milliseconds: 16));
    expect(saved.length, 2);
    await engine.advance();
    await tester.pump();
    expect(saved.length, 2);
    await engine.advance();
    await tester.pump();
    expect(saved.length, 3);
    expect(saved.last!.cursor, 2);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(saved.length, 4);
    expect(engine.paused, isTrue);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await engine.setPaused(false);
    await engine.advance();
    await engine.advance();
    await tester.pump();
    expect(engine.finished, isTrue);
    expect(saved.last, isNull);
    final writes = saved.length;
    await tester.pumpWidget(const SizedBox.shrink());
    expect(saved.length, writes);
  });

  testWidgets('继续观看自动恢复当前句，不需要再点开始播放', (tester) async {
    final script = StoryScript.parse('第一句\n第二句');
    final original = StoryEngine(script);
    await original.start();
    await original.advance();
    await original.advance();
    final checkpoint = original.checkpoint!;
    original.dispose();
    final saved = <PlaybackCheckpoint?>[];
    final restored = await _mountPlayer(tester,
      script: script, checkpoint: checkpoint, saved: saved);
    expect(find.text('开始播放'), findsNothing);
    expect(restored.state.text, '第二句');
    expect(restored.state.revealed, 0);
    expect(saved.single!.toJson(), checkpoint.toJson());
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
