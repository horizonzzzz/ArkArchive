import 'package:arknights_story_player/story_editor/editor_project.dart';
import 'package:arknights_story_player/story_editor/editor_stage.dart';
import 'package:arknights_story_player/story_editor/editor_platform.dart';
import 'package:arknights_story_player/story_editor/story_editor_page.dart';
import 'package:arknights_story_player/story_player/data/asset_store.dart';
import 'package:arknights_story_player/story_player/runtime/story_engine.dart';
import 'package:arknights_story_player/story_player/ui/story_stage.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

/// 第一期「演出台体验闭环」：播放头、非模态传输条、轻量增量与配套修复的验收测试。
class _Drafts extends EditorStorage {
  final projects = <String, EditorProject>{};

  @override
  Future<List<EditorProject>> list() async => projects.values.toList();

  @override
  Future<void> save(EditorProject project) async =>
      projects[project.id] = project;
}

/// 分镜 1：字幕 → 对白 → 字幕 → 对白。全部为无素材引用指令，离线可跑。
EditorProject _stageProject() => EditorProject.create('播放头验证').copyWith(
  scenes: const [
    EditorScene('第一幕', [
      StoryBeat('分镜 1', [
        EditCommand('subtitle', {'text': '序章', 'x': '100', 'y': '100'}),
        EditCommand('dialogue', {'name': '阿米娅', 'text': '第一句台词'}),
        EditCommand('subtitle', {'text': '终章', 'x': '100', 'y': '200'}),
        EditCommand('dialogue', {'name': '陈', 'text': '第二句台词'}),
      ]),
    ]),
  ],
);

EditorProject _twoBeatStageProject({bool withBranch = false}) {
  final project = _stageProject();
  return project.copyWith(
    scenes: [
      EditorScene('第一幕', [
        ...project.scenes.first.beats,
        StoryBeat('分镜 2', [
          if (withBranch)
            const EditCommand('decision', {'options': '继续', 'values': '1'})
          else
            const EditCommand('subtitle', {'text': '新字幕', 'y': '180'}),
          EditCommand('dialogue', {'name': '阿米娅', 'text': '第二幕台词'}),
        ]),
      ]),
    ],
  );
}

Future<EditorProject> _open(WidgetTester tester, EditorProject project) async {
  final storage = _Drafts()..projects[project.id] = project;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: StoryEditorPage(storage: storage, store: AssetStore()),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return project;
}

StoryEngine _engineOf(WidgetTester tester) => tester
    .widget<StoryStage>(
      find.descendant(
        of: find.byType(EditorStage),
        matching: find.byType(StoryStage),
      ),
    )
    .engine;

void main() {
  testWidgets('清空和恢复字幕后重新定位使用当前脚本', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _open(tester, _stageProject());
    await tester.tap(find.text('文字：终章').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, '');
    await tester.pumpAndSettle();
    expect(_engineOf(tester).state.subtitle, isNull);
    await tester.tap(find.byTooltip('分镜末态（End）'));
    await tester.pumpAndSettle();
    expect(_engineOf(tester).state.subtitle, isNull);
    await tester.tap(find.byTooltip('撤销'));
    await tester.pumpAndSettle();
    expect(_engineOf(tester).state.subtitle?.text, '终章');
  });
  testWidgets('切换分镜后返回复用静态舞台快照', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _open(tester, _twoBeatStageProject(withBranch: true));
    final firstEngine = _engineOf(tester);

    await tester.tap(find.byKey(const ValueKey(('tree-beat', 0, 1))));
    await tester.pumpAndSettle();
    expect(_engineOf(tester), isNot(same(firstEngine)));

    await tester.tap(find.byKey(const ValueKey(('tree-beat', 0, 0))));
    await tester.pumpAndSettle();
    expect(_engineOf(tester), same(firstEngine));
  });

  testWidgets('向前切换含字幕与对白的分镜时从已有舞台继续重放', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _open(tester, _twoBeatStageProject());
    final engine = _engineOf(tester);
    final state = engine.state;

    await tester.tap(find.byKey(const ValueKey(('tree-beat', 0, 1))));
    await tester.pumpAndSettle();

    expect(_engineOf(tester), same(engine));
    expect(engine.state, same(state));
    expect(engine.state.subtitle?.text, '新字幕');
    expect(engine.state.text, '第二幕台词');
    expect(engine.state.revealed, engine.totalCharacters);
  });

  testWidgets('全部分支禁用时结束播放并提示', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _open(
      tester,
      EditorProject.create('选项').copyWith(
        scenes: const [
          EditorScene('幕', [
            StoryBeat('分镜', [
              EditCommand('dialogue', {'text': '开始'}),
              EditCommand('decision', {'options': '&甲;&乙', 'values': '1;2'}),
              EditCommand('dialogue', {'text': '结束'}),
            ]),
          ]),
        ],
      ),
    );
    await tester.tap(find.byTooltip('播放（空格）'));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(find.byTooltip('播放（空格）'), findsOneWidget);
  });
  testWidgets('选中指令即预览：播放头停在该指令执行后，末态按钮回分镜末', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _open(tester, _stageProject());

    // 初始未选中：分镜末态，四条指令全部执行。
    var engine = _engineOf(tester);
    expect(engine.state.text, '第二句台词');
    expect(engine.cursor, 4);

    // 选中第 1 条指令：只执行第一条，画面与末态明显不同。
    await tester.tap(find.text('文字：序章').last);
    await tester.pumpAndSettle();
    engine = _engineOf(tester);
    expect(engine.cursor, 1);
    expect(engine.state.subtitle?.text, '序章');
    expect(engine.state.text, isEmpty);

    // 选中第 3 条指令：字幕被覆盖为「终章」，对白框显示第一句。
    await tester.tap(find.text('文字：终章').last);
    await tester.pumpAndSettle();
    engine = _engineOf(tester);
    expect(engine.cursor, 3);
    expect(engine.state.subtitle?.text, '终章');
    expect(engine.state.text, '第一句台词');

    // 「分镜末态」回到执行全部指令的末态。
    await tester.tap(find.byTooltip('分镜末态（End）'));
    await tester.pumpAndSettle();
    engine = _engineOf(tester);
    expect(engine.cursor, 4);
    expect(engine.state.text, '第二句台词');
  });

  testWidgets('改对白文本不重建舞台：引擎实例不变、对白框就地更新', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _open(tester, _stageProject());

    // 选中第 2 条（对白）指令，播放头显示第一句。
    await tester.tap(find.text('对白：第一句台词').last);
    await tester.pumpAndSettle();
    final engine = _engineOf(tester);
    expect(engine.state.text, '第一句台词');

    // 检查器字段顺序：说话人、台词。修改台词。
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(1), '改后的台词');
    await tester.pumpAndSettle();

    expect(identical(_engineOf(tester), engine), isTrue);
    expect(engine.state.text, '改后的台词');

    // 修改说话人同样就地生效。
    await tester.enterText(fields.at(0), '凯尔希');
    await tester.pumpAndSettle();
    expect(identical(_engineOf(tester), engine), isTrue);
    expect(engine.state.speaker, '凯尔希');
  });

  testWidgets('舞台参数就地同步：改字幕坐标不重建引擎', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _open(tester, _stageProject());

    await tester.tap(find.text('文字：终章').last);
    await tester.pumpAndSettle();
    final engine = _engineOf(tester);
    expect(engine.state.subtitle?.y, 200);

    // 字幕指令字段顺序：文字、X、Y、宽度、字号、对齐。改 Y 为 260。
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(2), '260');
    await tester.pumpAndSettle();

    expect(_engineOf(tester).state.subtitle?.y, 260);
    expect(identical(_engineOf(tester), engine), isTrue);
  });

  testWidgets('传输条：播放沿句推进、句级跳转、末态与位置标签', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _open(tester, _stageProject());

    final engine = _engineOf(tester);
    expect(find.textContaining('指令 4 / 4 · 第 2 / 2 句'), findsNothing);

    // 从末态按播放：从头开始。首个停顿是字幕（引擎将舞台文字也视为停顿点），
    // 节奏 400ms 后推进到第一句。
    await tester.tap(find.byTooltip('播放（空格）'));
    await tester.pump(const Duration(milliseconds: 80));
    expect(find.byTooltip('暂停（空格）'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 450));
    expect(engine.state.subtitle?.text, '序章');
    await tester.pump(const Duration(milliseconds: 450));
    expect(engine.state.text, '第一句台词');
    expect(find.textContaining('第 1 / 2 句'), findsOneWidget);

    // 暂停后，下一句跳到第 2 句；上一句跳回第 1 句。
    await tester.tap(find.byTooltip('暂停（空格）'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('下一句（→）'));
    await tester.pumpAndSettle();
    expect(engine.state.text, '第二句台词');
    await tester.tap(find.byTooltip('上一句（←）'));
    await tester.pumpAndSettle();
    expect(engine.state.text, '第一句台词');

    // 回到分镜开头：选中第一条指令，引擎重放到它执行后。
    await tester.tap(find.byTooltip('分镜开头（Home）'));
    await tester.pumpAndSettle();
    expect(engine.cursor, 1);
    expect(engine.state.subtitle?.text, '序章');

    // 倍速按钮循环 1× → 2× → 4× → 1×。
    final speed = find.text('1×');
    await tester.tap(speed);
    await tester.pump();
    expect(find.text('2×'), findsOneWidget);
    await tester.tap(find.text('2×'));
    await tester.pump();
    expect(find.text('4×'), findsOneWidget);
    await tester.tap(find.text('4×'));
    await tester.pump();
    expect(find.text('1×'), findsOneWidget);
  });

  testWidgets('播放自然结束停止、循环本段可反复播放', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _open(tester, _stageProject());

    await tester.tap(find.byTooltip('播放（空格）'));
    // 2 句对白 + 2 条字幕停顿：每轮 advance + 400ms 节奏，分段推进到播完。
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(find.byTooltip('播放（空格）'), findsOneWidget);
    expect(_engineOf(tester).state.text, '第二句台词');

    // 开启循环后再播放，分镜播完自动从头继续，不会停止。
    await tester.tap(find.byTooltip('循环本段'));
    await tester.pump();
    await tester.tap(find.byTooltip('播放（空格）'));
    await tester.pump(const Duration(seconds: 5));
    expect(find.byTooltip('暂停（空格）'), findsOneWidget);
  });

  testWidgets('键盘：空格播放暂停、方向键句跳，文本框聚焦时不干扰输入', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _open(tester, _stageProject());

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump(const Duration(milliseconds: 80));
    expect(find.byTooltip('暂停（空格）'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(find.byTooltip('播放（空格）'), findsOneWidget);

    // 末态 → 右方向键：跳到第一句。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(_engineOf(tester).state.text, '第一句台词');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(_engineOf(tester).state.text, '第二句台词');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(_engineOf(tester).state.text, '第一句台词');

    // Shift + 方向键逐指令移动（在第一句=指令 2 时右移到指令 3）。
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftRight);
    await tester.pumpAndSettle();
    expect(find.textContaining('指令 3 / 4'), findsOneWidget);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftRight);
    await tester.pumpAndSettle();
    expect(find.textContaining('指令 2 / 4'), findsOneWidget);

    // Home / End。
    await tester.sendKeyEvent(LogicalKeyboardKey.end);
    await tester.pumpAndSettle();
    expect(_engineOf(tester).state.text, '第二句台词');
    await tester.sendKeyEvent(LogicalKeyboardKey.home);
    await tester.pumpAndSettle();
    expect(_engineOf(tester).cursor, 1);

    // 文本框聚焦时方向键应交给输入框，不触发句跳。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), '序章二');
    await tester.pump();
    debugPrint(
      'focus=${FocusManager.instance.primaryFocus} '
      'type=${FocusManager.instance.primaryFocus.runtimeType}',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    // 焦点在文本框内，方向键未触发句跳，引擎停在当前句。
    expect(_engineOf(tester).cursor, 2);
  });

  testWidgets('校验问题支持「前往」定位到指令', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final project = EditorProject.create('带问题作品').copyWith(
      scenes: const [
        EditorScene('第一幕', [
          StoryBeat('分镜 1', [
            EditCommand('dialogue', {'name': '阿米娅', 'text': '第一句'}),
          ]),
          StoryBeat('分镜 2', [
            EditCommand('dialogue', {'name': '陈', 'text': '第二句'}),
            EditCommand('subtitle', {'text': '坐标越界', 'y': '-10'}),
          ]),
        ]),
      ],
    );
    await _open(tester, project);

    expect(project.validateIssues(), isNotEmpty);
    expect(
      project.validateIssues().first.locatable,
      isTrue,
      reason: '字幕坐标越界应携带位置信息',
    );

    await tester.tap(find.byTooltip('作品操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('检查作品'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('前往'));
    await tester.pumpAndSettle();

    // 跳到分镜 2 的第 2 条指令，传输条位置标签显示位置。
    expect(find.textContaining('指令 2 / 2'), findsOneWidget);
  });

  testWidgets('指令可拖动重排（宽屏无嵌套），作品列表最新在前', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final storage = _Drafts();
    final old = _stageProject();
    final newer = EditorProject.create('新作品')
        .copyWith(updatedAt: DateTime.now().add(const Duration(hours: 1)));
    storage.projects[old.id] = old;
    storage.projects[newer.id] = newer;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StoryEditorPage(storage: storage, store: AssetStore()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 我的作品列表：最新修改的作品排在第一位。
    await tester.tap(find.byTooltip('本地作品'));
    await tester.pumpAndSettle();
    expect(
      (tester
                  .widget<ListTile>(
                    find
                        .descendant(
                          of: find.byType(AlertDialog),
                          matching: find.byType(ListTile),
                        )
                        .first,
                  )
                  .title
              as Text)
          .data,
      '新作品',
    );
    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await tester.pumpAndSettle();

    // 宽屏指令列表支持拖动重排（无嵌套滚动，验证重排链路本身）。
    expect(find.byType(ReorderableListView), findsOneWidget);
    final handle = find.byType(ReorderableDragStartListener).first;
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await tester.pump(kLongPressTimeout);
    await gesture.moveBy(const Offset(0, 40));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 40));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 40));
    await tester.pump();
    await gesture.up();
    // 显式推进到自动保存防抖（450ms Timer）落地后再断言。
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();
    final saved = storage.projects.values.where((p) => p.id == old.id).single;
    expect(
      saved.scenes.single.beats.single.commands.first.value('text'),
      '第一句台词',
    );
  });

  testWidgets('窄屏指令可拖动重排', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final storage = _Drafts();
    final project = _stageProject();
    storage.projects[project.id] = project;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StoryEditorPage(storage: storage, store: AssetStore()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(ReorderableListView), findsOneWidget);
    final handle = find.byType(ReorderableDragStartListener).first;
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await tester.pump(kLongPressTimeout);
    await gesture.moveBy(const Offset(0, 36));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 36));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 36));
    await tester.pump();
    await gesture.up();
    // 显式推进到自动保存防抖（450ms Timer）落地后再断言。
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();
    final saved = storage.projects.values.single;
    expect(
      saved.scenes.single.beats.single.commands.first.value('text'),
      '第一句台词',
    );
  });

  testWidgets('保存状态展示带时间戳的已保存反馈', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _open(tester, _stageProject());

    // 选中字幕指令并修改文字字段，自动保存后展示“已保存 HH:mm”。
    await tester.tap(find.text('文字：序章').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).at(0), '改写序章');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(find.textContaining(RegExp(r'^已保存 \d{2}:\d{2}$')), findsOneWidget);
  });

  testWidgets('改完对白再播放：引擎使用当前台词，不读回旧文本', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _open(tester, _stageProject());

    // 选中第 2 条（对白）指令并修改台词：就地同步显示。
    await tester.tap(find.text('对白：第一句台词').last);
    await tester.pumpAndSettle();
    final engine = _engineOf(tester);
    await tester.enterText(find.byType(TextFormField).at(1), '改完复看');
    await tester.pumpAndSettle();
    expect(engine.state.text, '改完复看');
    expect(identical(_engineOf(tester), engine), isTrue);

    // 回分镜末态再播放：播放推进到该对白必须读当前台词。
    await tester.tap(find.byTooltip('分镜末态（End）'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('播放（空格）'));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pumpAndSettle();
    // 第一停顿：字幕。
    expect(_engineOf(tester).state.subtitle?.text, '序章');
    await tester.pump(const Duration(milliseconds: 450));
    // 第二停顿：对白读改后台词（回归点：不再读回引擎旧脚本）。
    expect(_engineOf(tester).state.text, '改完复看');
  });

  testWidgets('常驻播放遇选项沿默认分支推进，不卡在选项等待', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final project = EditorProject.create('选项分支').copyWith(
      scenes: const [
        EditorScene('第一幕', [
          StoryBeat('分镜 1', [
            EditCommand('dialogue', {'name': '阿米娅', 'text': '选哪个？'}),
            EditCommand('decision', {'options': '方案甲;方案乙', 'values': '1;2'}),
            EditCommand('dialogue', {'name': '阿米娅', 'text': '选定之后'}),
          ]),
        ]),
      ],
    );
    await _open(tester, project);

    final engine = _engineOf(tester);
    await tester.tap(find.byTooltip('播放（空格）'));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pumpAndSettle();
    // 第一停顿：对白「选哪个？」。
    expect(engine.state.text, '选哪个？');
    await tester.pump(const Duration(milliseconds: 450));
    // 第二停顿：选项被自动选择（与定位 rebuildBefore 的默认分支一致），
    // 播放推进到选项后的对白，而不是停在选项等待。
    expect(engine.state.choices, isEmpty);
    expect(engine.state.text, '选定之后');
    expect(find.byTooltip('暂停（空格）'), findsOneWidget);
  });

  testWidgets('改舞台文字正文：就地不重建、定位修正、播放读新文本', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _open(tester, _stageProject());

    // 选中第 3 条（字幕「终章」）指令并修改正文。
    await tester.tap(find.text('文字：终章').last);
    await tester.pumpAndSettle();
    final engine = _engineOf(tester);
    expect(engine.state.subtitle?.text, '终章');
    await tester.enterText(find.byType(TextFormField).at(0), '新终章');
    await tester.pumpAndSettle();
    // 就地更新：引擎实例不变、字幕直接显示新文本。
    expect(identical(_engineOf(tester), engine), isTrue);
    expect(engine.state.subtitle?.text, '新终章');

    // 定位时使用当前脚本重放，避免旧字幕复现。
    await tester.tap(find.byTooltip('分镜末态（End）'));
    await tester.pumpAndSettle();
    final updatedEngine = _engineOf(tester);
    expect(updatedEngine.state.subtitle?.text, '新终章');
    expect(identical(updatedEngine, engine), isFalse);

    // 播放：引擎重建使用当前脚本，推进到该字幕时读新文本。
    await tester.tap(find.byTooltip('播放（空格）'));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pumpAndSettle();
    expect(identical(_engineOf(tester), engine), isFalse);
    await tester.pump(const Duration(milliseconds: 450));
    expect(_engineOf(tester).state.subtitle?.text, '序章');
    await tester.pump(const Duration(milliseconds: 450));
    expect(_engineOf(tester).state.text, '第一句台词');
    await tester.pump(const Duration(milliseconds: 450));
    expect(_engineOf(tester).state.subtitle?.text, '新终章');
  });

  testWidgets('窄屏检查器连续输入不丢焦点（行身份跨编辑稳定）', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _open(tester, _stageProject());

    // 选中对白指令：窄屏下检查器内联在指令列表的行内。
    await tester.tap(find.text('对白：第一句台词').last);
    await tester.pumpAndSettle();
    final fields = find.descendant(
      of: find.byType(ReorderableListView),
      matching: find.byType(TextFormField),
    );
    expect(fields, findsNWidgets(2)); // 说话人 + 台词

    // 输入第一个字后，检查器输入框不应被整行替换（否则焦点丢失）。
    final before = tester.element(fields.at(1));
    await tester.enterText(fields.at(1), '一');
    await tester.pump();
    expect(
      identical(tester.element(fields.at(1)), before),
      isTrue,
      reason: '输入导致检查器随指令行被替换，焦点丢失',
    );

    // 连续编辑第二个字段（说话人）同样保持稳定，就地同步仍生效。
    final speakerBefore = tester.element(fields.at(0));
    await tester.enterText(fields.at(0), '陈');
    await tester.pump();
    expect(identical(tester.element(fields.at(0)), speakerBefore), isTrue);
    expect(_engineOf(tester).state.speaker, '陈');
    expect(_engineOf(tester).state.text, '一');
  });

  testWidgets('选中指令到画面更新的定位耗时基准（合成 500 指令）', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final project = EditorProject.create('性能基准').copyWith(
      scenes: [
        EditorScene('第一幕', [
          StoryBeat('分镜 1', [
            for (var i = 0; i < 500; i++)
              switch (i % 3) {
                0 => EditCommand('subtitle', {
                  'text': '字幕 $i',
                  'x': '100',
                  'y': '100',
                }),
                1 => EditCommand('dialogue', {'name': '阿米娅', 'text': '台词 $i'}),
                _ => EditCommand('blocker', {
                  'r': '0',
                  'g': '0.1',
                  'b': '0.28',
                  'a': '0.6',
                  'fadetime': '0',
                }),
              },
          ]),
        ]),
      ],
    );
    await _open(tester, project);

    await tester.tap(find.text('文字：字幕 0').first);
    await tester.pumpAndSettle();
    expect(_engineOf(tester).cursor, 1);
    final target = find.descendant(
      of: find.byType(ReorderableListView),
      matching: find.text('对白：台词 499'),
    );
    // 滚动到指令列表尾部，选中第 500 条指令。
    final scrollable = find
        .descendant(
          of: find.byType(ReorderableListView),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      target,
      400,
      scrollable: scrollable,
      maxScrolls: 150,
    );
    await tester.pumpAndSettle();
    final watch = Stopwatch()..start();
    expect(target.hitTestable(), findsOneWidget);
    await tester.tap(target.hitTestable());
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    watch.stop();
    // WidgetTester 使用虚拟时间，记录墙钟耗时供诊断；真实延迟须在 release 环境测量。
    debugPrint('500 指令实际定位测试耗时：${watch.elapsedMilliseconds}ms');
    expect(_engineOf(tester).cursor, 500);
  });
  testWidgets('剧本台逐行缓存输入，确认后提交', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final project = _stageProject();
    final storage = _Drafts()..projects[project.id] = project;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StoryEditorPage(storage: storage, store: AssetStore()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('剧本台').last);
    await tester.pumpAndSettle();
    final cells = find.byWidgetPredicate((widget) {
      return switch (widget.key) {
        ValueKey(value: ('script-cell', String _, false)) => true,
        _ => false,
      };
    });
    expect(find.byType(TextFormField), findsNothing);
    await tester.tap(cells.last);
    await tester.pumpAndSettle();
    expect(find.byType(TextFormField), findsOneWidget);
    final lastField = find.byType(TextFormField).last;
    await tester.enterText(lastField, '已提交台词');
    expect(
      storage.projects.values.single.compile().script.commands.any(
        (command) => command.text == '已提交台词',
      ),
      isFalse,
    );

    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      storage.projects.values.single.compile().script.commands.any(
        (command) => command.text == '已提交台词',
      ),
      isTrue,
    );

    await tester.tap(cells.last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '切换后保留台词');
    await tester.tap(find.text('演出台').last);
    await tester.pumpAndSettle();
    expect(
      storage.projects.values.single.compile().script.commands.last.text,
      '切换后保留台词',
    );
  });
}
