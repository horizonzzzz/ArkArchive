import 'dart:typed_data';

import 'package:arknights_story_player/story_editor/editor_platform.dart';
import 'package:arknights_story_player/story_editor/editor_project.dart';
import 'package:arknights_story_player/story_editor/story_editor_page.dart';
import 'package:arknights_story_player/story_player/data/asset_store.dart';
import 'package:arknights_story_player/story_player/ui/story_stage.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

class _Drafts extends EditorStorage {
  final projects = <String, EditorProject>{};
  Uint8List? exported;

  @override
  Future<List<EditorProject>> list() async => projects.values.toList();

  @override
  Future<void> save(EditorProject project) async =>
      projects[project.id] = project;

  @override
  Future<void> exportFile(
    String title,
    String extension,
    Uint8List bytes,
  ) async {
    expect(extension, 'json');
    exported = bytes;
  }

  @override
  Future<EditorProject?> importProject() async =>
      EditorProject.decode(exported!);
}

void main() {
  for (final size in [
    const Size(1440, 900),
    const Size(390, 844),
    const Size(844, 390),
  ]) {
    testWidgets('编辑、撤销、试播及导入导出：$size', (tester) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final storage = _Drafts();
      final initial = EditorProject.create('测试剧情');
      storage.projects[initial.id] = initial;
      final store = AssetStore();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StoryEditorPage(storage: storage, store: store),
          ),
        ),
      );
      await tester.pumpAndSettle();

      Future<void> select(String tooltip, String label) async {
        final button = find.byTooltip(tooltip);
        await tester.ensureVisible(button);
        await tester.tap(button);
        await tester.pumpAndSettle();
        final item = find.text(label).last;
        await tester.ensureVisible(item);
        await tester.tap(item);
        if (tooltip == '试播') {
          await tester.pump(const Duration(seconds: 1));
        } else {
          await tester.pumpAndSettle();
        }
      }

      const dialogue = '舞台已就绪';
      await select('添加演出指令', '对白');
      final field = find.byType(TextFormField).last;
      await tester.ensureVisible(field);
      await tester.enterText(field, dialogue);
      await tester.pump();
      await tester.tap(find.byTooltip('撤销'));
      await tester.pumpAndSettle();
      expect(find.text(dialogue), findsNothing);
      await tester.tap(find.byTooltip('重做'));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(
        storage.projects.values.single
            .compile()
            .script
            .commands
            .singleWhere((command) => command.tag == 'dialogue')
            .text,
        dialogue,
      );

      await select('试播', '从头播放');
      final stage = tester.widget<StoryStage>(
        find.descendant(
          of: find.byType(Dialog),
          matching: find.byType(StoryStage),
        ),
      );
      expect(stage.engine.state.text, dialogue);
      expect(find.byTooltip('退出试播'), findsOneWidget);
      await tester.tap(find.byTooltip('退出试播'));
      await tester.pump(const Duration(seconds: 1));
      expect(store.playbackProgresses, isEmpty);
      expect(store.completedStories, isEmpty);

      await select('作品操作', '导出作品（含上传素材）');
      expect(storage.exported, isNotNull);
      await select('作品操作', '导入作品');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(storage.projects, hasLength(2));
      expect(
        storage.projects.values.map((p) => p.compile().source).toSet(),
        hasLength(1),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('空态不会自动创建未命名作品', (tester) async {
    final storage = _Drafts();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StoryEditorPage(storage: storage, store: AssetStore()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('还没有本地作品'), findsOneWidget);
    expect(storage.projects, isEmpty);
    await tester.tap(find.text('新建作品'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '新的作品');
    await tester.tap(find.text('确定'));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    expect(storage.projects.values.single.title, '新的作品');
  });
}
