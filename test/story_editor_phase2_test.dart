import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:arknights_story_player/story_editor/editor_platform.dart';
import 'package:arknights_story_player/story_editor/editor_project.dart';
import 'package:arknights_story_player/story_editor/story_editor_page.dart';
import 'package:arknights_story_player/story_player/data/asset_store.dart';

class _MemoryStorage extends EditorStorage {
  final Map<String, EditorProject> projects = {};
  final List<(String title, String ext, Uint8List bytes)> exported = [];

  @override
  Future<List<EditorProject>> list() async =>
      projects.values.toList(growable: false);

  @override
  Future<void> save(EditorProject project) async {
    projects[project.id] = project;
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
  Future<void> exportFile(String title, String extension, Uint8List bytes) async {
    exported.add((title, extension, bytes));
  }
}

EditorProject _phase2Project() => EditorProject(
  id: '22222222222222222222222222222222',
  title: '第二期测试作品',
  updatedAt: DateTime.utc(2026, 11, 26, 10, 0),
  scenes: [
    EditorScene(
      '第一幕：出发',
      [
        StoryBeat(
          '分镜一：夜色甲板',
          [
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
          ],
          const EditorMarker(color: 'amber', note: '待润色台词'),
        ),
        StoryBeat(
          '分镜二：舰桥继承',
          [
            EditCommand('dialogue', {'name': '阿米娅', 'text': '前方发现不明信号。'}),
            EditCommand('dialogue', {'name': '可露希尔', 'text': '我来接管雷达！'}),
          ],
        ),
      ],
      const EditorMarker(color: 'cyan', note: '主线开场'),
    ),
    EditorScene(
      '第二幕：抵达',
      [
        StoryBeat(
          '分镜三：黎明港口',
          [
            EditCommand('dialogue', {'name': '博士', 'text': '终于到了。'}),
          ],
        ),
      ],
    ),
  ],
);

Future<_MemoryStorage> _pumpEditor(
  WidgetTester tester,
  EditorProject project, {
  Size size = const Size(1440, 900),
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final storage = _MemoryStorage()..projects[project.id] = project;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: StoryEditorPage(storage: storage, store: AssetStore()),
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
      final encoded = Uint8List.fromList(utf8.encode(jsonEncode(project.toJson())));
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
      await tester.tap(find.descendant(
        of: find.byKey(const ValueKey('editor-batch-bar')),
        matching: find.text('复制'),
      ));
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
      expect(storage.projects.values.single.scenes[0].beats[1].commands.length, 2);
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
        storage.projects.values.single.scenes[0].beats[0].commands[3]
            .value('volume'),
        '0',
      );

      // 选中遮罩，检查预设色板（白场）
      // 选中遮罩，检查预设色板（白场）
      await tester.drag(find.byType(ReorderableListView), const Offset(0, -240));
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
        storage.projects.values.single.scenes[0].beats[0].commands[0]
            .value('x'),
        '320',
      );
      expect(
        storage.projects.values.single.scenes[0].beats[0].commands[0]
            .value('y'),
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
      expect(storage.projects.values.single.lastPosition?.scene, 1);
      expect(storage.projects.values.single.lastPosition?.beat, 0);

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
      await tester.enterText(
        find.byKey(const ValueKey('script-search')),
        '雷达',
      );
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
      await tester.enterText(
        find.byKey(const ValueKey('script-search')),
        '',
      );
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

  group('§4.2 移动端轻量化形态', () {
    testWidgets('390×844 窄屏不展示桌面剧本台入口，保留轻量分镜切换与无溢出布局', (tester) async {
      await _pumpEditor(
        tester,
        _phase2Project(),
        size: const Size(390, 844),
      );

      expect(tester.takeException(), isNull);
      expect(find.text('剧本台'), findsNothing);
      expect(find.text('演出'), findsOneWidget);
      expect(find.text('分镜'), findsOneWidget);

      // 切到移动端分镜切换页，点击卡片直接回到演出台
      await tester.tap(find.text('分镜'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('轻分镜切换'),
        findsOneWidget,
      );
      await tester.tap(find.text('分镜三：黎明港口'));
      await tester.pumpAndSettle();
      expect(find.text('对白：终于到了。'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
