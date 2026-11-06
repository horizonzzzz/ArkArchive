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
    expect(find.byKey(const Key('fast-forward-speed-panel')), findsNothing);
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

  testWidgets('长按舞台进入快进并显示倍速面板，下滑换挡，松手恢复手动', (tester) async {
    final stage = await openPlayer(tester);
    final hold = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('story-stage'))),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(stage.engine.fastForwarding, isFalse);
    await tester.pump(const Duration(milliseconds: 300));
    expect(stage.engine.fastForwarding, isTrue);
    expect(stage.engine.fastForwardMultiplier, 2);
    expect(find.byKey(const Key('fast-forward-speed-panel')), findsOneWidget);
    for (final label in ['2x', '4x', '8x', '16x']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('倍速'), findsNWidgets(4));
    // 面板样式对齐参考：淡灰描边、近乎透明底、直角，右边框在选中档位处留空。
    final panelRect = tester.getRect(
      find.byKey(const Key('fast-forward-speed-panel')),
    );
    final panelDecoration =
        tester
            .widget<DecoratedBox>(
              find.byKey(const Key('fast-forward-speed-panel')),
            )
            .decoration as BoxDecoration;
    expect(panelDecoration.color, const Color(0x38000000));
    expect(panelDecoration.border?.top.color, const Color(0x59ffffff));
    expect((panelDecoration.border as Border).right, BorderSide.none);
    expect(panelDecoration.borderRadius, isNull);
    // 选中档位：白色 2px 直角框，向右突出约 20%，突出区带快进图标。
    Rect frameRect() => tester.getRect(
      find.byKey(const Key('fast-forward-speed-selected-frame')),
    );
    final frameDecoration =
        tester
            .widget<DecoratedBox>(
              find.byKey(const Key('fast-forward-speed-selected-frame')),
            )
            .decoration as BoxDecoration;
    expect(frameDecoration.color, const Color(0x59000000));
    expect(frameDecoration.border?.top.color, Colors.white);
    expect(frameDecoration.border?.top.width, 2);
    expect(tester.getSize(
      find.byKey(const Key('fast-forward-speed-selected-frame')),
    ), const Size(128, 44));
    expect(frameRect().top, panelRect.top);
    expect(frameRect().right, greaterThan(panelRect.right));
    expect(find.byIcon(Icons.fast_forward), findsOneWidget);
    // 按住下滑换挡：每 64 逻辑像素一档，上滑回退。
    await hold.moveBy(const Offset(0, 70));
    await tester.pump();
    expect(stage.engine.fastForwardMultiplier, 4);
    expect(frameRect().top, panelRect.top + 44);
    await hold.moveBy(const Offset(0, 62));
    await tester.pump();
    expect(stage.engine.fastForwardMultiplier, 8);
    expect(frameRect().top, panelRect.top + 88);
    await hold.moveBy(const Offset(0, 60));
    await tester.pump();
    expect(stage.engine.fastForwardMultiplier, 16);
    expect(frameRect().top, panelRect.top + 132);
    await hold.moveBy(const Offset(0, -132));
    await tester.pump();
    expect(stage.engine.fastForwardMultiplier, 2);
    expect(frameRect().top, panelRect.top);
    await hold.up();
    await tester.pump();
    expect(stage.engine.fastForwarding, isFalse);
    expect(find.byKey(const Key('fast-forward-speed-panel')), findsNothing);
    expect(stage.engine.autoMode, 'default');
    expect(find.text('2x'), findsNothing);
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
    expect(find.byKey(const Key('fast-forward-speed-panel')), findsNothing);
    final hold = await tester.startGesture(center);
    await tester.pump(const Duration(milliseconds: 600));
    expect(stage.engine.fastForwarding, isTrue);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(stage.engine.fastForwarding, isFalse);
    expect(find.byKey(const Key('fast-forward-speed-panel')), findsNothing);
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
      expect(find.byKey(const Key('fast-forward-speed-panel')), findsNothing);
      await hold.cancel();
      await tester.pump();
    }
    expect(stage.engine.state.history, hasLength(1));
    expect(stage.engine.autoMode, 'default');
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
