import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:arknights_story_player/story_player/data/asset_store.dart';
import 'package:arknights_story_player/story_player/data/media_catalog.dart';
import 'package:arknights_story_player/story_player/data/story_repository.dart';
import 'package:arknights_story_player/story_player/runtime/story_audio.dart';
import 'package:arknights_story_player/story_player/script.dart';
import 'package:arknights_story_player/story_player/stage_state.dart';
import 'package:arknights_story_player/story_player/ui/story_player.dart';
import 'package:arknights_story_player/story_player/ui/story_stage.dart';
import 'package:arknights_story_player/story_player/ui/stage_painter.dart';

Future<StoryStage> openPlayer(
  WidgetTester tester, {
  bool autoable = false,
  String? script,
}) async {
  final assets = AssetStore();
  addTearDown(assets.close);
  final story = PreparedStory(
    StoryDocument(
      title: '布局回归',
      script: StoryScript.parse(
        script ??
            '[header(is_autoable=$autoable)]\n[Background(image="bg_a")]\n[Character(name="char_a")]\n第一句\n[Background(image="bg_b")]\n[Character(name="char_b")]\n第二句\n[Background(image="bg_c")]\n第三句',
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

  testWidgets('对话记录覆盖舞台，定位最新记录并可上下滚动', (tester) async {
    final stage = await openPlayer(tester);
    stage.engine.state.history
      ..clear()
      ..addAll(List.generate(40, (i) => DialogueLine('角色$i', '对白$i', i)))
      ..add(const DialogueLine('最新角色', '<color=#ff0000>最新对白</color>', 40));
    await tester.tap(find.byTooltip('对话记录'));
    await tester.pumpAndSettle();

    expect(stage.engine.paused, isFalse);
    expect(
      tester.widget<StoryStage>(find.byType(StoryStage)).showDialogue,
      isFalse,
    );
    expect(find.text('最新角色'), findsOneWidget);
    expect(find.text('角色0'), findsNothing);
    final latest = tester.widget<Text>(
      find.ancestor(
        of: find.text('最新对白', findRichText: true),
        matching: find.byType(Text),
      ),
    );
    final span = (latest.textSpan! as TextSpan).children!.single as TextSpan;
    expect(span.style!.fontFamily, 'StoryNotoSans');
    expect(span.style!.color, const Color(0xffff0000));

    final list = find.byKey(const Key('dialogue-history-list'));
    await tester.drag(list, const Offset(0, 500));
    await tester.pumpAndSettle();
    expect(find.text('最新角色'), findsNothing);
    await tester.drag(list, const Offset(0, -1000));
    await tester.pumpAndSettle();
    expect(find.text('最新角色'), findsOneWidget);

    await tester.tap(find.byTooltip('关闭对话记录'));
    await tester.pumpAndSettle();
    expect(stage.engine.paused, isFalse);
    expect(
      tester.widget<StoryStage>(find.byType(StoryStage)).showDialogue,
      isTrue,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('空记录和诊断面板不暂停剧情', (tester) async {
    final stage = await openPlayer(tester);
    stage.engine.state.history.clear();

    await tester.tap(find.byTooltip('对话记录'));
    await tester.pumpAndSettle();
    expect(find.text('暂无对话记录'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭对话记录'));
    await tester.pumpAndSettle();
    expect(stage.engine.paused, isFalse);

    stage.engine.warn('诊断测试信息');
    await tester.tap(find.byTooltip('资源与指令诊断'));
    await tester.pumpAndSettle();
    expect(find.text('资源与指令诊断'), findsOneWidget);
    expect(find.text('诊断测试信息'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(stage.engine.paused, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('诊断面板可按顺序复制全部信息', (tester) async {
    final stage = await openPlayer(tester);
    stage.engine.warnings.clear();
    await tester.tap(find.byTooltip('资源与指令诊断'));
    await tester.pumpAndSettle();
    final copyButton = find.byWidgetPredicate(
      (widget) => widget is IconButton && widget.tooltip == '复制全部',
    );
    expect(tester.widget<IconButton>(copyButton).onPressed, isNull);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();

    stage.engine.warnings.addAll(['第一条\n详细信息', '第二条']);
    await tester.tap(find.byTooltip('资源与指令诊断'));
    await tester.pumpAndSettle();
    String? copiedText;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copiedText = (call.arguments as Map)['text'] as String?;
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await tester.tap(find.byTooltip('复制全部'));
    await tester.pumpAndSettle();
    expect(copiedText, '第一条\n详细信息\n第二条');
    expect(find.byTooltip('已复制全部'), findsOneWidget);
    expect(find.text('第一条\n详细信息'), findsOneWidget);
    expect(find.text('第二条'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
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
                .decoration
            as BoxDecoration;
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
                .decoration
            as BoxDecoration;
    expect(frameDecoration.color, const Color(0x59000000));
    expect(frameDecoration.border?.top.color, Colors.white);
    expect(frameDecoration.border?.top.width, 2);
    expect(
      tester.getSize(
        find.byKey(const Key('fast-forward-speed-selected-frame')),
      ),
      const Size(128, 44),
    );
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
  testWidgets('进度条位于顶部并可拖动跳转到后续对白', (tester) async {
    final stage = await openPlayer(tester);
    final progress = find.byKey(const Key('story-progress-hit-area'));
    expect(progress, findsOneWidget);
    final rect = tester.getRect(progress);
    expect(rect.top, greaterThan(35));
    expect(rect.top, lessThan(80));
    expect(rect.width, greaterThan(600));
    expect(rect.height, closeTo(28, .01));
    expect(
      tester.getRect(find.byKey(const Key('story-progress-track'))).width,
      greaterThan(600),
    );
    final trackPainter = find.descendant(
      of: find.byKey(const Key('story-progress-track')),
      matching: find.byType(CustomPaint),
    );
    expect(tester.getSize(trackPainter).width, greaterThan(600));

    final gesture = await tester.startGesture(
      Offset(rect.left + 8, rect.center.dy),
    );
    await gesture.moveTo(Offset(rect.right - 8, rect.center.dy));
    await tester.pump(const Duration(milliseconds: 300));
    final previewImage = find.byKey(const Key('story-progress-preview-stage'));
    expect(previewImage, findsOneWidget);
    expect(tester.getRect(previewImage).width, greaterThan(100));
    final previewPainter =
        tester.widget<CustomPaint>(previewImage).painter! as StagePainter;
    expect(previewPainter.state.backgrounds.single.key, 'bg_c');

    // 信息区跟随目标句切换（key 必须在 AnimatedSwitcher 直接 child 上，
    // 否则跨句不更新且入场动画方向错乱）。
    final ordinal = find.text('第 3 / 3 句');
    expect(ordinal, findsOneWidget);
    expect(find.textContaining('第三句'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 200));
    // 位置回归：信息区文本不得越过画面区下边界（防「上浮黑块」复发）。
    expect(
      tester.getTopLeft(ordinal).dy,
      greaterThanOrEqualTo(tester.getBottomRight(previewImage).dy - 2),
    );

    await gesture.up();
    await tester.pumpAndSettle();
    expect(stage.engine.state.history.last.text, '第三句');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('下拉超过阈值进入精细定位并可取消', (tester) async {
    await openPlayer(tester);
    final progress = find.byKey(const Key('story-progress-hit-area'));
    final before = tester.getRect(progress);
    final gesture = await tester.startGesture(
      Offset(before.center.dx, before.center.dy),
    );
    await gesture.moveBy(const Offset(0, 30));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 180));
    // 面板随下拉深度连续展开（拉 30px：深度 30/110，下移 36×30/110≈9.8px）。
    final partial = tester.getRect(progress);
    expect(partial.top - before.top, closeTo(36 * 30 / 110, 1));
    expect(find.byKey(const Key('story-fine-tag')), findsOneWidget);
    expect(find.textContaining('×0.50'), findsOneWidget);
    // 拉满深度：下移到位、灵敏度降到 ×0.18、出现停顿点刻度。
    await gesture.moveBy(const Offset(0, 110));
    // 隐式动画（duration 0）同样需要两帧：一帧触发、一帧 layout。
    await tester.pump();
    await tester.pump();
    final full = tester.getRect(progress);
    expect(full.top - before.top, closeTo(36, 1));
    expect(find.textContaining('×0.18'), findsOneWidget);
    // C1 回归 + 误触修复：精细态下横向左右滑动不得退出（原 bug：单帧
    // 负 dy 即恢复非精细，移动端左右扫动即误触）。
    await gesture.moveBy(const Offset(60, 0));
    await tester.pump();
    expect(find.byKey(const Key('story-fine-tag')), findsOneWidget);
    await gesture.moveBy(const Offset(-60, 0));
    await tester.pump();
    expect(find.byKey(const Key('story-fine-tag')), findsOneWidget);
    // 上滑回拉把深度拉回 0 才退出精细。
    await gesture.moveBy(const Offset(0, -110));
    await tester.pump();
    expect(find.byKey(const Key('story-fine-tag')), findsNothing);
    // 退出后小幅度下移不会立即重入。
    await gesture.moveBy(const Offset(0, 5));
    await tester.pump();
    expect(find.byKey(const Key('story-fine-tag')), findsNothing);
    // 重新下拉超过 24px 阈值才再次进入。
    await gesture.moveBy(const Offset(0, 26));
    await tester.pump();
    expect(find.byKey(const Key('story-fine-tag')), findsOneWidget);
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('story-fine-tag')), findsNothing);
    expect(tester.getRect(progress).top, before.top);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('小幅拖动松手视为取消，明显拖动跳转到目标句', (tester) async {
    final stage = await openPlayer(tester);
    expect(stage.engine.state.text, '第一句');
    final rect = tester.getRect(
      find.byKey(const Key('story-progress-hit-area')),
    );

    // 增量拖动（§0/S4）：拖回原位松手即取消，不产生跳转。
    final cancel = await tester.startGesture(
      Offset(rect.center.dx, rect.center.dy),
    );
    await cancel.moveBy(const Offset(40, 0));
    await tester.pump();
    await cancel.moveBy(const Offset(-40, 0));
    await tester.pump();
    await cancel.up();
    await tester.pumpAndSettle();
    expect(stage.engine.state.text, '第一句');
    expect(stage.engine.state.history, hasLength(1));

    // 拖出 1.5% 以上才生效，吸附到最近停顿点。
    final seek = await tester.startGesture(
      Offset(rect.center.dx, rect.center.dy),
    );
    await seek.moveBy(const Offset(40, 0));
    await tester.pump();
    await seek.moveBy(const Offset(80, 0));
    await tester.pump();
    await seek.up();
    // 黑闪期间（§5-A8）：黑闪层 target opacity 为 1。
    await tester.pump(const Duration(milliseconds: 40));
    expect(
      tester
          .widget<AnimatedOpacity>(find.byKey(const Key('story-seek-flash')))
          .opacity,
      1,
    );
    await tester.pumpAndSettle();
    expect(stage.engine.state.text, '第二句');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('选项面板弹出时进度条禁用，选择后恢复', (tester) async {
    final stage = await openPlayer(
      tester,
      script: '[header]\n第一句\n[Decision(options="甲;乙",values="1;2")]\n[Predicate(references="1")]\n甲分支\n[Predicate]\n结尾',
    );
    GestureDetector hitArea() => tester.widget<GestureDetector>(
      find.byKey(const Key('story-progress-hit-area')),
    );
    expect(hitArea().onPanStart, isNotNull);
    // tap1 完成第一句打字，tap2 推进到 decision 面板。
    await tester.tap(find.byKey(const Key('story-stage')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('story-stage')));
    await tester.pump();
    expect(stage.engine.state.choices, isNotEmpty);
    expect(hitArea().onPanStart, isNull);
    expect(hitArea().onTapUp, isNull);
    await stage.engine.choose(stage.engine.state.choices.first.value);
    await tester.pump();
    expect(stage.engine.state.choices, isEmpty);
    expect(hitArea().onPanStart, isNotNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Log 行点击跳转带黑闪，hover 提示且当前句高亮锚定', (tester) async {
    final stage = await openPlayer(tester);
    // 推进到第二句：Log 有两行，第二句为当前句。
    await tester.tap(find.byKey(const Key('story-stage')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('story-stage')));
    await tester.pump();
    expect(stage.engine.state.text, '第二句');

    await tester.tap(find.byTooltip('对话记录'));
    await tester.pumpAndSettle();
    expect(find.text('当前句 ▸'), findsOneWidget);
    expect(find.text('跳转 ↵'), findsNothing);

    // hover 第一句行显示跳转提示（仅指针设备）。
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(find.text('第一句')));
    await tester.pump();
    expect(find.text('跳转 ↵'), findsOneWidget);
    await mouse.removePointer();
    await tester.pump();
    expect(find.text('跳转 ↵'), findsNothing);

    await tester.tap(find.text('第一句'));
    await tester.pump();
    // 跳转通道黑闪中（§4：Log 与进度条走同一 seek 通道）。
    await tester.pump(const Duration(milliseconds: 60));
    expect(
      tester
          .widget<AnimatedOpacity>(find.byKey(const Key('story-seek-flash')))
          .opacity,
      1,
    );
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pumpAndSettle();
    expect(stage.engine.state.text, '第一句');
    expect(stage.engine.state.revealed, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('进度条播放中自动隐藏，轻点呼出后再点跳转', (tester) async {
    final stage = await openPlayer(tester);
    double fadeOpacity() => tester
        .widget<AnimatedOpacity>(find.byKey(const Key('story-progress-fade')))
        .opacity;
    final rect = tester.getRect(
      find.byKey(const Key('story-progress-hit-area')),
    );

    // 开始播放的头几秒展示进度条（功能可发现性）。
    expect(fadeOpacity(), 1);
    // 3 秒无操作自动淡出，让位给剧情。
    await tester.pump(const Duration(milliseconds: 3200));
    expect(fadeOpacity(), 0);

    // 隐藏态轻点条带：只呼出、不跳转（防误触）。
    await tester.tapAt(Offset(rect.center.dx, rect.center.dy));
    await tester.pump();
    expect(fadeOpacity(), 1);
    expect(stage.engine.state.text, '第一句');
    expect(stage.engine.state.history, hasLength(1));

    // 呼出后的第二次轻点：吸附最近停顿点跳转。
    await tester.tapAt(Offset(rect.left + rect.width * .9, rect.center.dy));
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pumpAndSettle();
    expect(stage.engine.state.text, '第三句');
    // seek 完成后展示 3 秒再淡出。
    expect(fadeOpacity(), 1);
    await tester.pump(const Duration(milliseconds: 3200));
    expect(fadeOpacity(), 0);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('进度条隐藏后可直接拖动呼出，或经顶部热区 hover 呼出', (tester) async {
    final stage = await openPlayer(tester);
    double fadeOpacity() => tester
        .widget<AnimatedOpacity>(find.byKey(const Key('story-progress-fade')))
        .opacity;
    final rect = tester.getRect(
      find.byKey(const Key('story-progress-hit-area')),
    );
    await tester.pump(const Duration(milliseconds: 3200));
    expect(fadeOpacity(), 0);

    // 隐藏态直接拖动：呼出并进入正常增量拖动流程。
    final gesture = await tester.startGesture(
      Offset(rect.center.dx, rect.center.dy),
    );
    await gesture.moveBy(const Offset(40, 0));
    await tester.pump();
    expect(fadeOpacity(), 1);
    await gesture.moveBy(const Offset(80, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(stage.engine.state.text, '第二句');

    // 隐藏后鼠标进入顶部宽热区（工具条区域）hover 呼出，移出后重新计时。
    await tester.pump(const Duration(milliseconds: 3200));
    expect(fadeOpacity(), 0);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(400, 30));
    await tester.pump();
    expect(fadeOpacity(), 1);
    await mouse.moveTo(const Offset(400, 400));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 3200));
    expect(fadeOpacity(), 0);
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
