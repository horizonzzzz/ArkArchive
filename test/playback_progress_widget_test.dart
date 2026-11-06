import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:arknights_story_player/story_player/story_player.dart';
import 'package:arknights_story_player/story_player/ui/story_stage.dart';

Future<StoryEngine> _mountPlayer(
  WidgetTester tester, {
  required StoryScript script,
  PlaybackProgress? resumable,
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
      resumable: resumable,
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
    expect(find.text('从上次继续'), findsNothing);
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

  testWidgets('有可选恢复点时，点从上次继续恢复当前句', (tester) async {
    final script = StoryScript.parse('第一句\n第二句');
    final original = StoryEngine(script);
    await original.start();
    await original.advance();
    await original.advance();
    final checkpoint = original.checkpoint!;
    original.dispose();
    final saved = <PlaybackCheckpoint?>[];
    final restored = await _mountPlayer(
      tester,
      script: script,
      resumable: PlaybackProgress(
        path: 'test/story',
        scriptHash: PlaybackProgress.fingerprint(script),
        checkpoint: checkpoint,
      ),
      saved: saved,
    );
    // 不自动恢复：开始画面同时提供从头与续播两个入口。
    expect(find.text('开始播放'), findsOneWidget);
    expect(find.text('从上次继续'), findsOneWidget);
    expect(restored.state.text, isNot('第二句'));
    await tester.tap(find.text('从上次继续'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(restored.state.text, '第二句');
    expect(restored.state.revealed, 0);
    expect(saved.single!.toJson(), checkpoint.toJson());
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('断点失效时点从上次继续提示失效，不清除原进度', (tester) async {
    final script = StoryScript.parse('第一句\n第二句');
    final original = StoryEngine(script);
    await original.start();
    await original.advance();
    await original.advance();
    final checkpoint = original.checkpoint!;
    original.dispose();
    final saved = <PlaybackCheckpoint?>[];
    final stale = PlaybackProgress(
      path: 'test/story',
      // 脚本已更新，指纹与断点记录不一致。
      scriptHash: PlaybackProgress.fingerprint(StoryScript.parse('内容已更新')),
      checkpoint: checkpoint,
    );
    final engine = await _mountPlayer(
      tester,
      script: script,
      resumable: stale,
      saved: saved,
    );
    await tester.tap(find.text('从上次继续'));
    await tester.pump();
    expect(find.text('观看断点已失效，无法恢复原观看位置。'), findsOneWidget);
    expect(find.text('从头观看'), findsOneWidget);
    expect(engine.cursor, 0);
    expect(saved, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
