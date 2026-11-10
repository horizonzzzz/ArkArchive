import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:arknights_story_player/story_player/story_player.dart';
import 'package:arknights_story_player/story_player/ui/story_stage.dart';

Future<StoryEngine> _mountPlayer(
  WidgetTester tester, {
  required StoryScript script,
  PlaybackProgress? resumable,
  required List<PlaybackCheckpoint?> saved,
  bool archiveMode = false,
  int? initialCommandIndex,
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
    await tester.pumpWidget(
      MaterialApp(
        home: StoryPlayer(
          story: story,
          audio: SilentStoryAudio(),
          resumable: resumable,
          archiveMode: archiveMode,
          initialCommandIndex: initialCommandIndex,
          onProgress: (value) async {
            saved.add(value);
          },
        ),
      ),
    );
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
    final engine = await _mountPlayer(
      tester,
      script: StoryScript.parse('第一句\n第二句'),
      saved: saved,
    );
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
    expect(engine.paused, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

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
  testWidgets('档案回放自动定位且推进、后台和退出都不写进度', (tester) async {
    final saved = <PlaybackCheckpoint?>[];
    final engine = await _mountPlayer(
      tester,
      script: StoryScript.parse('第一句\n第二句\n第三句'),
      saved: saved,
      archiveMode: true,
      initialCommandIndex: 1,
    );
    expect(engine.cursor, 2);
    expect(engine.state.text, '第二句');
    expect(find.textContaining('档案回放 · 不保存进度'), findsOneWidget);
    expect(saved, isEmpty);
    await engine.advance();
    await engine.advance();
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(saved, isEmpty);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(saved, isEmpty);
  });

  testWidgets('档案回放明确确认继续观看才允许覆盖断点', (tester) async {
    final saved = <PlaybackCheckpoint?>[];
    final engine = await _mountPlayer(
      tester,
      script: StoryScript.parse('第一句\n第二句\n第三句'),
      saved: saved,
      archiveMode: true,
      initialCommandIndex: 1,
    );
    await tester.tap(find.text('继续观看'));
    await tester.pumpAndSettle();
    expect(saved, isEmpty);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(saved, isEmpty);
    await tester.tap(find.text('继续观看'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '继续观看'));
    await tester.pumpAndSettle();
    expect(saved, isNotEmpty);
    expect(saved.last!.cursor, engine.cursor);
    expect(find.textContaining('档案回放 · 不保存进度'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('档案回放无法到达目标时退到开头并保留只读状态', (tester) async {
    final saved = <PlaybackCheckpoint?>[];
    final engine = await _mountPlayer(
      tester,
      script: StoryScript.parse('第一句\n第二句'),
      saved: saved,
      archiveMode: true,
      initialCommandIndex: 99,
    );
    expect(engine.cursor, 1);
    expect(find.textContaining('已回到剧情开头'), findsOneWidget);
    expect(saved, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('非默认分支台词不会伪装为精准回放', (tester) async {
    final saved = <PlaybackCheckpoint?>[];
    final engine = await _mountPlayer(
      tester,
      script: StoryScript.parse('''
[name="甲"]开头
[Decision(options="左;右",values="1;2")]
[Predicate(references="1")]
[name="甲"]左分支
[Predicate(references="2")]
[name="乙"]右分支
[Predicate]
[name="甲"]结尾
'''),
      saved: saved,
      archiveMode: true,
      initialCommandIndex: 5,
    );
    expect(engine.state.text, '开头');
    expect(find.textContaining('无法在默认分支中定位'), findsOneWidget);
    expect(saved, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
