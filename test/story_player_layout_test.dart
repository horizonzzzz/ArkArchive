import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:arknights_story_player/story_player/data/asset_store.dart';
import 'package:arknights_story_player/story_player/data/media_catalog.dart';
import 'package:arknights_story_player/story_player/data/story_repository.dart';
import 'package:arknights_story_player/story_player/runtime/story_audio.dart';
import 'package:arknights_story_player/story_player/script.dart';
import 'package:arknights_story_player/story_player/ui/story_player.dart';
import 'package:arknights_story_player/story_player/ui/story_stage.dart';

Future<StoryStage> openPlayer(
  WidgetTester tester, {
  bool autoable = false,
}) async {
  final assets = AssetStore();
  addTearDown(assets.close);
  final story = PreparedStory(
    StoryDocument(
      title: '布局回归',
      script: StoryScript.parse(
        '[header(is_autoable=$autoable)]\n第一句\n第二句\n第三句',
      ),
    ),
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
  await tester.tap(find.text('开始播放'));
  await tester.pump();
  return tester.widget<StoryStage>(find.byType(StoryStage));
}

void main() {
  testWidgets('无header的舞台占满可用空间，保留裸图标并响应点击', (tester) async {
    final stage = await openPlayer(tester);
    expect(stage.engine.state.history.single.text, '第一句');
    expect(find.text('开始播放'), findsNothing);
    expect(find.text('布局回归'), findsNothing);
    expect(find.byTooltip('手动播放：开启'), findsOneWidget);
    expect(find.byTooltip('退出播放器'), findsOneWidget);
    expect(find.byTooltip('对话记录'), findsOneWidget);
    expect(find.byTooltip('资源与指令诊断'), findsOneWidget);
    expect(find.byTooltip('速度'), findsNothing);
    expect(find.byTooltip('快速模式'), findsNothing);
    expect(find.byTooltip('暂停'), findsNothing);
    expect(find.text('2× 加速中'), findsNothing);
    expect(
      tester.getSize(find.byType(StoryStage)),
      tester.getSize(find.byType(Scaffold)),
    );
    for (final button in tester.widgetList<IconButton>(
      find.byType(IconButton),
    )) {
      expect(button.style?.backgroundColor, isNull);
      expect(
        tester.getSize(find.byWidget(button)).shortestSide,
        greaterThanOrEqualTo(44),
      );
    }
    await tester.tap(find.byKey(const Key('story-stage')));
    await tester.pump();
    expect(stage.engine.state.revealed, stage.engine.totalCharacters);
    await tester.tap(find.byKey(const Key('story-stage')));
    await tester.pump();
    expect(stage.engine.state.text, '第二句');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('手动和自动显示不同图标并可来回切换', (tester) async {
    final stage = await openPlayer(tester, autoable: true);
    expect(find.byIcon(Icons.touch_app), findsOneWidget);
    await tester.tap(find.byTooltip('手动播放：开启'));
    await tester.pump();
    expect(stage.engine.autoMode, 'button_auto');
    expect(find.byIcon(Icons.play_circle_outline), findsOneWidget);
    expect(find.byIcon(Icons.touch_app), findsNothing);
    await tester.tap(find.byTooltip('自动播放：开启'));
    await tester.pump();
    expect(stage.engine.autoMode, 'default');
    expect(find.byIcon(Icons.touch_app), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('长按舞台显示二倍速，松手恢复且不推进剧情', (tester) async {
    final stage = await openPlayer(tester);
    final hold = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('story-stage'))),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(stage.engine.fastForwarding, isFalse);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('2× 加速中'), findsOneWidget);
    expect(stage.engine.fastForwarding, isTrue);
    await hold.up();
    await tester.pump();
    expect(find.text('2× 加速中'), findsNothing);
    expect(stage.engine.fastForwarding, isFalse);
    expect(stage.engine.state.text, '第一句');
    expect(stage.engine.state.history, hasLength(1));
    expect(stage.engine.autoMode, 'default');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('取消手势或切到后台会清除二倍速', (tester) async {
    final stage = await openPlayer(tester);
    final center = tester.getCenter(find.byKey(const Key('story-stage')));
    final cancelled = await tester.startGesture(center);
    await tester.pump(const Duration(milliseconds: 600));
    expect(stage.engine.fastForwarding, isTrue);
    await cancelled.cancel();
    await tester.pump();
    expect(stage.engine.fastForwarding, isFalse);
    expect(find.text('2× 加速中'), findsNothing);
    final hold = await tester.startGesture(center);
    await tester.pump(const Duration(milliseconds: 600));
    expect(stage.engine.fastForwarding, isTrue);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(stage.engine.fastForwarding, isFalse);
    expect(find.text('2× 加速中'), findsNothing);
    await hold.up();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('长按顶部功能图标不触发舞台二倍速', (tester) async {
    final stage = await openPlayer(tester, autoable: true);
    for (final tooltip in ['对话记录', '资源与指令诊断', '手动播放：开启']) {
      final hold = await tester.startGesture(
        tester.getCenter(find.byTooltip(tooltip)),
      );
      await tester.pump(const Duration(milliseconds: 600));
      expect(stage.engine.fastForwarding, isFalse);
      expect(find.text('2× 加速中'), findsNothing);
      await hold.cancel();
      await tester.pump();
    }
    expect(stage.engine.state.history, hasLength(1));
    expect(stage.engine.autoMode, 'default');
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
