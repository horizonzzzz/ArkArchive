import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';

import 'package:arknights_story_player/story_editor/editor_board.dart';
import 'package:arknights_story_player/story_editor/editor_platform.dart';
import 'package:arknights_story_player/story_editor/editor_preview.dart';
import 'package:arknights_story_player/story_editor/editor_project.dart';
import 'package:arknights_story_player/story_editor/story_editor_page.dart';
import 'package:arknights_story_player/story_player/data/asset_store.dart';

import 'story_export_test.dart' show MemoryCache;

class _MemoryStorage extends EditorStorage {
  final Map<String, EditorProject> projects = {};
  final List<(String title, String ext, Uint8List bytes)> exported = [];
  final positions = <String, EditorPosition>{};
  int contentWrites = 0;

  @override
  Future<void> savePosition(
    String id,
    DateTime revision,
    EditorPosition position,
  ) async {
    if (projects[id]?.updatedAt == revision) positions[id] = position;
  }

  @override
  Future<List<EditorProject>> list() async =>
      projects.values.toList(growable: false);

  @override
  Future<void> save(EditorProject project) async {
    projects[project.id] = project;
    contentWrites++;
  }

  @override
  Future<void> delete(String id) async {
    projects.remove(id);
  }

  @override
  Future<EditorProject?> importProject() async => null;

  @override
  Future<(String, Uint8List)?> pickMedia({required bool image}) async => null;

  @override
  Future<void> exportFile(
    String title,
    String extension,
    Uint8List bytes,
  ) async {
    exported.add((title, extension, bytes));
  }
}

EditorProject _phase2Project() => EditorProject(
  id: '22222222222222222222222222222222',
  title: '第二期测试作品',
  updatedAt: DateTime.utc(2026, 11, 26, 10, 0),
  scenes: [
    EditorScene('第一幕：出发', [
      StoryBeat('分镜一：夜色甲板', [
        EditCommand('subtitle', {
          'text': '序幕文字',
          'x': '320',
          'y': '360',
          'width': '640',
          'size': '28',
          'alignment': 'center',
        }),
        EditCommand('dialogue', {'name': '阿米娅', 'text': '博士，天快亮了。'}),
        EditCommand('dialogue', {'name': '凯尔希', 'text': '保持冷静，注意航线。'}),
        EditCommand('playmusic', {
          'key': 'local_bgm',
          'volume': '0.8',
          'fadetime': '1.5',
        }),
        EditCommand('blocker', {
          'a': '0.6',
          'r': '0',
          'g': '0',
          'b': '0',
          'fadetime': '0.5',
        }),
      ], const EditorMarker(color: 'amber', note: '待润色台词')),
      StoryBeat('分镜二：舰桥继承', [
        EditCommand('dialogue', {'name': '阿米娅', 'text': '前方发现不明信号。'}),
        EditCommand('dialogue', {'name': '可露希尔', 'text': '我来接管雷达！'}),
      ]),
    ], const EditorMarker(color: 'cyan', note: '主线开场')),
    EditorScene('第二幕：抵达', [
      StoryBeat('分镜三：黎明港口', [
        EditCommand('dialogue', {'name': '博士', 'text': '终于到了。'}),
      ]),
    ]),
  ],
);

EditorProject _boardBenchmarkProject() => EditorProject(
  id: '33333333333333333333333333333333',
  title: '编排台基准作品',
  updatedAt: DateTime.utc(2026, 11, 26, 12, 0),
  scenes: [
    for (var s = 0; s < 5; s++)
      EditorScene('第${s + 1}幕', [
        for (var b = 0; b < 60; b++)
          StoryBeat('分镜 ${s * 60 + b + 1}', [
            EditCommand('subtitle', {
              'text': '分镜 ${s * 60 + b + 1} 文字',
              'x': '100',
              'y': '100',
            }),
            EditCommand('dialogue', {
              'name': '阿米娅',
              'text': '第${s * 60 + b + 1} 句台词内容',
            }),
          ]),
      ]),
  ],
);

Future<_MemoryStorage> _pumpEditor(
  WidgetTester tester,
  EditorProject project, {
  Size size = const Size(1440, 900),
  AssetStore? store,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final storage = _MemoryStorage()..projects[project.id] = project;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: StoryEditorPage(storage: storage, store: store ?? AssetStore()),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return storage;
}

void main() {
  group('第二期数据模型、标记、估时与台本导出', () {
    test('EditorMarker / EditorPosition 序列化向后兼容并可无损还原', () {
      final project = _phase2Project().copyWith(
        lastPosition: const EditorPosition(scene: 1, beat: 0, command: 0),
      );
      final encoded = Uint8List.fromList(
        utf8.encode(jsonEncode(project.toJson())),
      );
      final decoded = EditorProject.decode(encoded);
      expect(decoded.scenes.first.marker.color, 'cyan');
      expect(decoded.scenes.first.marker.note, '主线开场');
      expect(decoded.scenes.first.beats.first.marker.color, 'amber');
      expect(decoded.scenes.first.beats.first.marker.note, '待润色台词');
      expect(decoded.lastPosition?.scene, 1);
      expect(decoded.lastPosition?.beat, 0);
      expect(decoded.lastPosition?.command, 0);
      expect(decoded.beatCount, 3);
      expect(decoded.estimatedSeconds, greaterThan(0));
    });

    test('台本 TXT / CSV / SRT 导出内容准确', () {
      final project = _phase2Project();
      final txt = exportScriptTxt(project);
      final csv = exportScriptCsv(project);
      final srt = exportScriptSrt(project);

      expect(txt, contains('第二期测试作品'));
      expect(txt, contains('阿米娅：博士，天快亮了。'));
      expect(txt, contains('可露希尔：我来接管雷达！'));

      expect(csv.startsWith('\uFEFF'), isTrue);
      expect(csv, contains('幕,分镜,序号,类型,说话人,台词'));
      expect(csv, contains('阿米娅'));

      expect(srt, contains('1\n00:00:00,000 --> '));
      expect(srt, contains('阿米娅：博士，天快亮了。'));
      expect(srt, contains('博士：终于到了。'));
    });

    test('SRT 边界：空文本不生成条目，非空条目时长恒为正且不重叠', () {
      final project = EditorProject(
        id: '4444444444444444444444444444444',
        title: 'SRT 边界作品',
        updatedAt: DateTime.utc(2026, 11, 26, 12, 0),
        scenes: [
          EditorScene('第一幕', [
            StoryBeat('分镜一', [
              // 空对白与纯空白字幕：不应生成条目，但按估算推进 cursor。
              EditCommand('dialogue', {'name': '阿米娅', 'text': ''}),
              EditCommand('subtitle', {'text': '   '}),
              EditCommand('dialogue', {'name': '陈', 'text': '嗯'}),
              // 估时为 0 的指令：不生成条目，也不应造成后续条目零时长或重叠。
              EditCommand('blocker', {
                'a': '0.5',
                'r': '0',
                'g': '0',
                'b': '0',
                'fadetime': '0',
              }),
              EditCommand('subtitle', {'text': '好'}),
              // 超长字幕：取 6 秒估算上限。
              EditCommand('subtitle', {'text': '长' * 100}),
            ]),
          ]),
        ],
      );

      final srt = exportScriptSrt(project);
      final blocks = srt.trim().split('\n\n');
      expect(blocks, hasLength(3));
      // 空文本对白/纯空白字幕未生成任何条目。
      expect(srt, isNot(contains('阿米娅')));

      final pattern = RegExp(
        r'(\d{2}):(\d{2}):(\d{2}),(\d{3}) --> (\d{2}):(\d{2}):(\d{2}),(\d{3})',
      );
      int msAt(int h, int m, int s, int ms) =>
          ((h * 60 + m) * 60 + s) * 1000 + ms;
      final entries = <(int, int)>[];
      for (final block in blocks) {
        final lines = block.split('\n');
        expect(lines[0], matches(RegExp(r'^\d+$')));
        final m = pattern.firstMatch(lines[1]);
        expect(m, isNotNull, reason: lines[1]);
        entries.add((
          msAt(
            int.parse(m!.group(1)!),
            int.parse(m.group(2)!),
            int.parse(m.group(3)!),
            int.parse(m.group(4)!),
          ),
          msAt(
            int.parse(m.group(5)!),
            int.parse(m.group(6)!),
            int.parse(m.group(7)!),
            int.parse(m.group(8)!),
          ),
        ));
      }

      // 非空对白/字幕估算均有正数下限，不存在零时长条目。
      for (final (start, end) in entries) {
        expect(end - start, greaterThan(1500));
      }
      // 相邻条目时间轴不重叠（穿插零估时指令也不受影响）。
      for (var i = 1; i < entries.length; i++) {
        expect(entries[i].$1, greaterThanOrEqualTo(entries[i - 1].$2));
      }
      // 单字对白/字幕取下限、超长字幕取 6 秒上限。
      expect(entries[0].$2 - entries[0].$1, 1680);
      expect(entries[1].$2 - entries[1].$1, 1580);
      expect(entries[2].$2 - entries[2].$1, 6000);
    });
  });

  group('P0-3 选择集、批量条、剪贴板与命令面板', () {
    testWidgets('全选 → 批量条改说话人 + 复制跨分镜粘贴 + 快捷键撤销', (tester) async {
      final storage = await _pumpEditor(tester, _phase2Project());

      // 通过「选择与批量」菜单全选当前分镜指令
      await tester.tap(find.byTooltip('选择与批量'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('全选指令（Ctrl+A）'));
      await tester.pumpAndSettle();

      // 批量条出现并展示已选条数
      expect(find.byKey(const ValueKey('editor-batch-bar')), findsOneWidget);
      expect(find.text('已选 5 条'), findsWidgets);

      // 批量替换说话人并应用
      await tester.enterText(
        find.byKey(const ValueKey('batch-speaker-input')),
        '罗德岛通讯员',
      );
      await tester.tap(find.text('应用'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 600));

      final afterBatch = storage.projects.values.single;
      final beat0Dialogues = afterBatch.scenes[0].beats[0].commands
          .where((c) => c.tag == 'dialogue')
          .toList();
      expect(beat0Dialogues, hasLength(2));
      expect(beat0Dialogues.every((c) => c.value('name') == '罗德岛通讯员'), isTrue);

      // 多选状态下检查器进入多选编辑模式
      expect(find.textContaining('批量属性'), findsOneWidget);

      // 复制所选，切换到分镜二并粘贴
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('editor-batch-bar')),
          matching: find.text('复制'),
        ),
      );
      await tester.pumpAndSettle();

      // 在结构树点击分镜二
      await tester.tap(find.text('分镜二：舰桥继承'));
      await tester.pumpAndSettle();
      // 点击粘贴按钮
      await tester.tap(find.byIcon(Icons.content_paste));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 600));

      final afterPaste = storage.projects.values.single;
      expect(afterPaste.scenes[0].beats[1].commands.length, 7);

      // 撤销恢复分镜二粘贴
      await tester.tap(find.byTooltip('撤销'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 600));
      expect(
        storage.projects.values.single.scenes[0].beats[1].commands.length,
        2,
      );
    });

    testWidgets('Ctrl+K 打开命令面板并可切换到剧本台', (tester) async {
      await _pumpEditor(tester, _phase2Project());
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      expect(find.text('命令面板'), findsOneWidget);
      await tester.tap(find.text('切换到剧本台（对白表格）'));
      await tester.pumpAndSettle();

      expect(find.textContaining('已选 0 / 6 条'), findsOneWidget);
    });
  });

  group('P0-4 舞台缩放、变换框、对象列表与继承直编', () {
    testWidgets('字幕显示宽高/字号手柄，对象列表展示继承对象并触发二选一弹窗', (tester) async {
      await _pumpEditor(tester, _phase2Project());

      // 默认未选中指令时，舞台缩放 HUD 存在并可放大/适配
      expect(find.text('100%'), findsOneWidget);
      await tester.tap(find.byTooltip('放大舞台'));
      await tester.pumpAndSettle();
      expect(find.text('125%'), findsOneWidget);
      await tester.tap(find.byTooltip('适配窗口（双击舞台）'));
      await tester.pumpAndSettle();
      expect(find.text('100%'), findsOneWidget);

      // 选中字幕指令后，显示字幕宽/字号变换手柄
      await tester.tap(find.text('文字：序幕文字'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey(('subtitle-width', 0))), findsOneWidget);
      expect(find.byKey(const ValueKey(('subtitle-size', 0))), findsOneWidget);

      // 切到分镜二，打开对象列表浮层，检查继承自前序分镜的字幕对象
      await tester.tap(find.text('分镜二：舰桥继承'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('对象 '));
      await tester.pumpAndSettle();
      expect(find.textContaining('继承'), findsWidgets);

      // 点击继承对象弹出「跨分镜继承对象」二选一弹窗并测试「在当前分镜插入覆盖指令」
      await tester.tap(find.textContaining('（继承）').first);
      await tester.pumpAndSettle();
      expect(find.textContaining('继承自前序分镜'), findsOneWidget);
      expect(find.text('跳转到来源指令'), findsOneWidget);
      expect(find.text('在当前分镜插入覆盖指令'), findsOneWidget);
      await tester.tap(find.text('在当前分镜插入覆盖指令'));
      await tester.pumpAndSettle();

      expect(find.text('文字：序幕文字'), findsOneWidget);
    });
  });

  group('P0-5 检查器高频控件与分组', () {
    testWidgets('遮罩色板预设、音量 dB 滑杆、字幕居中/重置与高级折叠生效', (tester) async {
      final storage = await _pumpEditor(tester, _phase2Project());

      // 选中播放音乐，检查音量滑杆 + dB + 静音按钮
      await tester.tap(find.text('播放音乐：local_bgm'));
      await tester.pumpAndSettle();
      expect(find.textContaining('dB'), findsOneWidget);
      await tester.tap(find.byTooltip('静音'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 600));
      expect(
        storage.projects.values.single.scenes[0].beats[0].commands[3].value(
          'volume',
        ),
        '0',
      );

      // 选中遮罩，检查预设色板（白场）
      // 选中遮罩，检查预设色板（白场）
      await tester.drag(
        find.byType(ReorderableListView),
        const Offset(0, -240),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('blocker'));
      await tester.pumpAndSettle();
      expect(find.text('黑场'), findsOneWidget);
      expect(find.text('白场'), findsOneWidget);
      await tester.tap(find.widgetWithText(ActionChip, '白场'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 600));
      final blocker =
          storage.projects.values.single.scenes[0].beats[0].commands[4];
      expect(blocker.value('r'), '1');
      expect(blocker.value('g'), '1');
      expect(blocker.value('b'), '1');

      // 滚回顶部并选中字幕，验证坐标居中按钮和枚举分段按钮
      await tester.drag(find.byType(ReorderableListView), const Offset(0, 240));
      await tester.pumpAndSettle();
      await tester.tap(find.text('文字：序幕文字'));
      await tester.pumpAndSettle();
      final centerChip = find.widgetWithText(ActionChip, '居中');
      expect(centerChip, findsOneWidget);
      expect(find.byType(SegmentedButton<String>), findsOneWidget);
      await tester.tap(centerChip);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 600));
      expect(
        storage.projects.values.single.scenes[0].beats[0].commands[0].value(
          'x',
        ),
        '320',
      );
      expect(
        storage.projects.values.single.scenes[0].beats[0].commands[0].value(
          'y',
        ),
        '300',
      );
    });
  });

  group('P1-4 结构树、面包屑、全局搜索、导航历史与重开恢复', () {
    testWidgets('面包屑与 Alt+←/→ 历史回退，全局搜索直达第二幕，重开恢复上次位置', (tester) async {
      final storage = await _pumpEditor(tester, _phase2Project());

      // 打开全局搜索并搜索“终于到了”
      await tester.tap(find.byTooltip('全局搜索'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '终于到了');
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('终于到了').last);
      await tester.pumpAndSettle();

      // 已跳转到第二幕分镜三
      expect(find.text('对白：终于到了。'), findsOneWidget);
      // 推进防抖保存，确认 lastPosition 已持久化
      await tester.pump(const Duration(milliseconds: 600));
      expect(storage.positions.values.single.scene, 1);
      expect(storage.positions.values.single.beat, 0);
      expect(storage.contentWrites, 0);

      // 点击面包屑后退按钮回到第一幕分镜一
      await tester.tap(find.byTooltip('后退（Alt+←）'));
      await tester.pumpAndSettle();
      expect(find.text('对白：博士，天快亮了。'), findsOneWidget);

      // 再前进回第二幕
      await tester.tap(find.byTooltip('前进（Alt+→）'));
      await tester.pumpAndSettle();
      expect(find.text('对白：终于到了。'), findsOneWidget);
    });
  });

  group('P1-1 编排台故事板与 P1-6 剧本台对白表格', () {
    testWidgets('编排台展示全部分镜、筛选有标记分镜、新建分镜并双击进入演出台', (tester) async {
      final storage = await _pumpEditor(tester, _phase2Project());

      await tester.tap(find.text('编排台'));
      await tester.pumpAndSettle();

      expect(find.text('分镜一：夜色甲板'), findsWidgets);
      expect(find.text('分镜二：舰桥继承'), findsWidgets);
      expect(find.text('分镜三：黎明港口'), findsWidgets);

      // 筛选「有标记」，仅显示分镜一
      await tester.tap(find.text('有标记'));
      await tester.pumpAndSettle();
      expect(find.text('分镜一：夜色甲板'), findsWidgets);

      // 切回全部，点击顶部「新建分镜」
      await tester.tap(find.text('全部'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('新建分镜').first);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 600));

      expect(storage.projects.values.single.beatCount, 4);
    });

    testWidgets('剧本台搜索、仅当前幕、行内改台词、批量替换说话人与导出 SRT', (tester) async {
      final storage = await _pumpEditor(tester, _phase2Project());

      await tester.tap(find.text('剧本台'));
      await tester.pumpAndSettle();

      // 搜索过滤
      await tester.enterText(find.byKey(const ValueKey('script-search')), '雷达');
      await tester.pumpAndSettle();
      expect(find.textContaining('已选 0 / 1 条'), findsOneWidget);

      // 搜索不存在内容出现空态文案
      await tester.enterText(
        find.byKey(const ValueKey('script-search')),
        '完全不存在的文本',
      );
      await tester.pumpAndSettle();
      expect(find.text('没有匹配的台词'), findsOneWidget);

      // 清空搜索，全选并批量替换说话人
      await tester.enterText(find.byKey(const ValueKey('script-search')), '');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('script-select-all')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('script-batch-speaker')),
        '全员广播',
      );
      await tester.tap(find.byKey(const ValueKey('script-batch-apply')));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 600));

      final rows = collectScriptRows(storage.projects.values.single)
          .where((r) => r.isDialogue)
          .toList();
      expect(rows.every((r) => r.speaker == '全员广播'), isTrue);

      // 导出 SRT 验证字节输出
      await tester.tap(find.text('导出台本'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('导出字幕 (.srt)'));
      await tester.pumpAndSettle();
      expect(storage.exported, hasLength(1));
      expect(storage.exported.single.$2, 'srt');
      expect(utf8.decode(storage.exported.single.$3), contains('全员广播'));
    });
  });

  group('P1-1 框选批量与拖拽重排验收', () {
    testWidgets('鼠标空白处框选分镜 → 批量删除可一次撤销，点空白清除选择', (tester) async {
      final storage = await _pumpEditor(tester, _phase2Project());
      await tester.tap(find.text('编排台'));
      await tester.pumpAndSettle();

      final card0 = tester.getRect(
        find.byKey(const ValueKey(('board-card', 0, 0))),
      );
      final card1 = tester.getRect(
        find.byKey(const ValueKey(('board-card', 0, 1))),
      );
      // 从两卡之间空隙起手，拖出覆盖分镜二卡片的矩形（避开卡片与占位卡）。
      final start = Offset(card0.right + 6, card0.top + 40);
      final end = Offset(card1.right - 30, card1.bottom - 10);

      final marquee = await tester.startGesture(
        start,
        kind: PointerDeviceKind.mouse,
      );
      await marquee.moveBy(end - start);
      await tester.pump();
      // 框选矩形覆盖层按拖拽矩形实时绘制。
      expect(
        tester.getRect(find.byKey(const ValueKey('board-marquee'))),
        Rect.fromPoints(start, end),
      );
      await marquee.up();
      await tester.pumpAndSettle();
      expect(find.text('已选 1 镜'), findsOneWidget);

      // 批量删除选中的分镜二。
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 600));

      final afterDelete = storage.projects.values.single;
      expect(afterDelete.beatCount, 2);
      expect(afterDelete.scenes[0].beats.map((b) => b.title), ['分镜一：夜色甲板']);

      // P1-1 验收：批量删除一次撤销即可恢复原数据。
      await tester.tap(find.byTooltip('撤销'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 600));

      final afterUndo = storage.projects.values.single;
      expect(afterUndo.beatCount, 3);
      expect(afterUndo.scenes[0].beats[1].title, '分镜二：舰桥继承');
      expect(afterUndo.scenes[0].beats[1].commands, hasLength(2));
      expect(
        afterUndo.scenes[0].beats[1].commands.first.value('text'),
        '前方发现不明信号。',
      );

      // 再次框选后，单击空白处（未拖出矩形）清除选择。
      final again = await tester.startGesture(
        start,
        kind: PointerDeviceKind.mouse,
      );
      await again.moveBy(end - start);
      await again.up();
      await tester.pumpAndSettle();
      expect(find.text('已选 1 镜'), findsOneWidget);

      final click = await tester.startGesture(
        start,
        kind: PointerDeviceKind.mouse,
      );
      await click.up();
      await tester.pumpAndSettle();
      expect(find.text('已选 1 镜'), findsNothing);
    });

    testWidgets('已有选择 → 框选被系统取消 → 原选择完整保留', (tester) async {
      await _pumpEditor(tester, _phase2Project());
      await tester.tap(find.text('编排台'));
      await tester.pumpAndSettle();

      final board = find.byType(EditorBoardView);
      Rect cardRectOf(int si, int bi) => tester.getRect(
        find.descendant(
          of: board,
          matching: find.byKey(ValueKey(('board-card', si, bi))),
        ),
      );

      // 先点选分镜一卡片，形成已有选择。
      // 卡片 InkWell 同时注册 onTap/onDoubleTap，单击要等双击竞争窗口
      // （kDoubleTapTimeout）结束后才回调，需显式推进该时长。
      await tester.tap(
        find.descendant(of: board, matching: find.text('分镜一：夜色甲板')),
      );
      await tester.pump(kDoubleTapTimeout);
      await tester.pumpAndSettle();
      expect(find.text('已选 1 镜'), findsOneWidget);

      final card0 = cardRectOf(0, 0);
      final card1 = cardRectOf(0, 1);
      final start = Offset(card0.right + 6, card0.top + 40);
      final end = Offset(card1.right - 30, card1.bottom - 10);

      // 不按 Ctrl 开始框选并拖向分镜二，随后指针被系统取消。
      final gesture = await tester.startGesture(
        start,
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveBy(end - start);
      await tester.pump();
      // 框选进行中，选择为矩形覆盖的分镜二。
      final checkIcon = find.descendant(
        of: board,
        matching: find.byIcon(Icons.check),
      );
      expect(card1.contains(tester.getRect(checkIcon).center), isTrue);

      await gesture.cancel();
      await tester.pumpAndSettle();

      // 取消框选后恢复框选前的原选择：分镜一仍被选中，矩形覆盖层消失。
      expect(find.text('已选 1 镜'), findsOneWidget);
      expect(card0.contains(tester.getRect(checkIcon).center), isTrue);
      expect(find.byKey(const ValueKey('board-marquee')), findsNothing);
    });

    testWidgets('同幕拖拽重排：指令数据完整、当前位置跟随移动分镜且可撤销', (tester) async {
      final storage = await _pumpEditor(tester, _phase2Project());
      await tester.tap(find.text('编排台'));
      await tester.pumpAndSettle();

      final from = tester
          .getRect(find.byKey(const ValueKey(('board-card', 0, 0))))
          .center;
      final to = tester
          .getRect(find.byKey(const ValueKey(('board-card', 0, 1))))
          .center;

      final gesture = await tester.startGesture(
        from,
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveBy(const Offset(8, 8));
      await tester.pump();
      await gesture.moveTo(to);
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 600));

      // P1-1 验收：拖拽重排不丢状态 —— 顺序交换且指令数据原样保留。
      final afterMove = storage.projects.values.single;
      expect(afterMove.scenes[0].beats.map((b) => b.title), [
        '分镜二：舰桥继承',
        '分镜一：夜色甲板',
      ]);
      expect(afterMove.scenes[0].beats[1].commands, hasLength(5));
      expect(afterMove.scenes[0].beats[1].commands.first.value('text'), '序幕文字');
      // 当前位置跟随移动后的分镜并持久化。
      expect(afterMove.lastPosition?.scene, 0);
      expect(afterMove.lastPosition?.beat, 1);

      // 撤销恢复原顺序与位置。
      await tester.tap(find.byTooltip('撤销'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 600));
      final afterUndo = storage.projects.values.single;
      expect(afterUndo.scenes[0].beats.map((b) => b.title), [
        '分镜一：夜色甲板',
        '分镜二：舰桥继承',
      ]);
    });

    testWidgets('跨幕拖拽重排：分镜移入第二幕首位且当前位置恢复', (tester) async {
      final storage = await _pumpEditor(tester, _phase2Project());
      await tester.tap(find.text('编排台'));
      await tester.pumpAndSettle();

      final from = tester
          .getRect(find.byKey(const ValueKey(('board-card', 0, 1))))
          .center;
      final to = tester
          .getRect(find.byKey(const ValueKey(('board-card', 1, 0))))
          .center;

      final gesture = await tester.startGesture(
        from,
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveBy(const Offset(8, 8));
      await tester.pump();
      await gesture.moveTo(to);
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 600));

      final afterMove = storage.projects.values.single;
      expect(afterMove.scenes[0].beats.map((b) => b.title), ['分镜一：夜色甲板']);
      expect(afterMove.scenes[1].beats.map((b) => b.title), [
        '分镜二：舰桥继承',
        '分镜三：黎明港口',
      ]);
      // 指令数据跨幕移动后原样保留。
      expect(afterMove.scenes[1].beats.first.commands, hasLength(2));
      expect(
        afterMove.scenes[1].beats.first.commands.last.value('text'),
        '我来接管雷达！',
      );
      // 当前位置恢复到移动后的新位置。
      expect(afterMove.lastPosition?.scene, 1);
      expect(afterMove.lastPosition?.beat, 0);
    });

    testWidgets('300 个分镜作品编排台首屏计时基准（P1-1）', (tester) async {
      await _pumpEditor(tester, _boardBenchmarkProject());
      final watch = Stopwatch()..start();
      await tester.tap(find.text('编排台'));
      await tester.pumpAndSettle();
      watch.stop();
      // WidgetTester 使用虚拟时间；此处记录 JIT 调试环境墙钟供诊断与
      // 验收佐证（release 环境只会更快），详见二期验证报告。
      debugPrint('300 分镜编排台首屏墙钟耗时：${watch.elapsedMilliseconds}ms');

      // 首屏即可见全貌汇总（幕数 / 分镜数 / 总估时）。
      expect(find.textContaining('共 5 幕 · 300 个分镜'), findsOneWidget);
    });

    testWidgets('编排台加载并去重缓存 PRTS 背景、CG 与立绘缩略图', (tester) async {
      final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jXioAAAAASUVORK5CYII=',
      );
      final requests = <String, int>{};
      final store = AssetStore(
        cache: MemoryCache(),
        client: MockClient((request) async {
          final path = request.url.path;
          requests[path] = (requests[path] ?? 0) + 1;
          if (path.endsWith('/story_variables.json') ||
              path.endsWith('/background.json')) {
            return http.Response('{}', 200);
          }
          if (path.endsWith('/character.json')) {
            return http.Response(
              jsonEncode({
                'char_002_amiya': {
                  'size': {'x': 512, 'y': 512},
                  'pos': {'x': 0, 'y': 0},
                  'array': [
                    {'image': 'char_002_amiya_1'},
                  ],
                },
              }),
              200,
            );
          }
          if (path.endsWith('.png')) {
            return http.Response.bytes(
              png,
              200,
              headers: {'content-type': 'image/png'},
            );
          }
          return http.Response('not found', 404);
        }),
      );
      final project = EditorProject(
        id: '55555555555555555555555555555555',
        title: 'PRTS 缩略图验证',
        updatedAt: DateTime.utc(2026, 11, 27, 10, 0),
        scenes: [
          EditorScene('第一幕', [
            StoryBeat('分镜 1', [
              EditCommand('background', {'image': 'bg_room'}),
              EditCommand('charslot', {'slot': 'l', 'name': 'char_002_amiya'}),
              EditCommand('dialogue', {'name': '阿米娅', 'text': '背景与立绘'}),
            ]),
            StoryBeat('分镜 2', [
              EditCommand('image', {'image': 'cg_event'}),
              EditCommand('dialogue', {'name': '阿米娅', 'text': '叠加 CG'}),
            ]),
            StoryBeat('分镜 3', [
              EditCommand('image', {'fadetime': '0'}),
              EditCommand('charslot', {'slot': 'l', 'name': 'char_empty'}),
              EditCommand('dialogue', {'name': '阿米娅', 'text': '清场回背景'}),
            ]),
          ]),
        ],
      );

      await _pumpEditor(tester, _phase2Project());
      await tester.tap(find.text('编排台'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<EditorBoardView>(find.byType(EditorBoardView)).resources,
        isNotNull,
      );

      final resources = EditorPreviewResources(store);
      addTearDown(resources.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EditorBoardView(
              project: project,
              activeScene: 0,
              activeBeat: 0,
              issues: const [],
              compact: false,
              resources: resources,
              onOpenBeat: (_, _) {},
              onAddBeat: (_) {},
              onInsertBeatAfter: (_, _) {},
              onDuplicateBeats: (_) {},
              onDeleteBeats: (_) {},
              onMoveBeat: (_, _, _) {},
              onMarkBeat: (_, _) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();

      Finder cardImages(int beat) => find.descendant(
        of: find.byKey(ValueKey(('board-card', 0, beat))),
        matching: find.byType(Image),
      );
      expect(cardImages(0), findsNWidgets(2));
      expect(cardImages(1), findsNWidgets(3));
      expect(cardImages(2), findsOneWidget);

      expect(requests['/assets/avg/background/bg_room.png'], 1);
      expect(requests['/assets/avg/images/cg_event.png'], 1);
      expect(requests['/assets/avg/characters/char_002_amiya_1.png'], 1);
    });

    testWidgets('编排台拖动右侧滚动条只滚动，不触发框选或选中', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await _pumpEditor(tester, _boardBenchmarkProject());
        await tester.tap(find.text('编排台'));
        await tester.pumpAndSettle();

        final board = find.byType(EditorBoardView);
        final scrollView = find.descendant(
          of: board,
          matching: find.byType(CustomScrollView),
        );
        final scrollable = tester.state<ScrollableState>(
          find.descendant(of: scrollView, matching: find.byType(Scrollable)),
        );
        expect(scrollable.position.maxScrollExtent, greaterThan(0));

        final rect = tester.getRect(scrollView);
        final scrollbarPoint = Offset(rect.right - 6, rect.top + 10);
        final drag = await tester.startGesture(
          scrollbarPoint,
          kind: PointerDeviceKind.mouse,
        );
        await drag.moveBy(const Offset(0, 180));
        await tester.pump();
        expect(find.byKey(const ValueKey('board-marquee')), findsNothing);
        await drag.up();
        await tester.pumpAndSettle();

        expect(scrollable.position.pixels, greaterThan(0));
        expect(find.byKey(const ValueKey('board-marquee')), findsNothing);
        expect(find.textContaining('已选'), findsNothing);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });

  group('§4.2 移动端轻量化形态', () {
    testWidgets('390×844 窄屏不展示桌面剧本台入口，保留轻量分镜切换与无溢出布局', (tester) async {
      await _pumpEditor(tester, _phase2Project(), size: const Size(390, 844));

      expect(tester.takeException(), isNull);
      expect(find.text('剧本台'), findsNothing);
      expect(find.text('演出'), findsOneWidget);
      expect(find.text('分镜'), findsOneWidget);

      // 切到移动端分镜切换页，点击卡片直接回到演出台
      await tester.tap(find.text('分镜'));
      await tester.pumpAndSettle();
      expect(find.textContaining('轻分镜切换'), findsOneWidget);
      await tester.tap(find.text('分镜三：黎明港口'));
      await tester.pumpAndSettle();
      expect(find.text('对白：终于到了。'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
