import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:arknights_story_player/story_editor/editor_project.dart';
import 'package:arknights_story_player/story_player/script.dart';

void main() {
  test('dialogue escaping survives editor export and import', () {
    const original = '引号 "回声"\n第二行\t反斜杠 \\ 尾端\r\n';
    const dialogue = EditCommand('dialogue', {'name': '阿米娅', 'text': original});
    final project = EditorProject.fromScript(
      '往返测试',
      StoryScript.parse(dialogue.source),
    );

    final restored = EditorProject.decode(project.export()).compile();
    expect(restored.script.commands.single.text, original);
    expect(
      StoryScript.parse(restored.source).commands.single.text,
      restored.script.commands.single.text,
    );
  });

  test('portable project preserves local media and 100 beats', () {
    final asset = EditorAsset.create(
      'bg.png',
      Uint8List.fromList([1, 2, 3]),
      width: 16,
      height: 9,
    );
    final command = EditCommand('background', {'image': asset.key});
    final project = EditorProject.create('大作品').copyWith(
      assets: {asset.key: asset},
      scenes: [
        EditorScene('第一幕', [
          for (var i = 0; i < 100; i++) StoryBeat('分镜 ${i + 1}', [command]),
        ]),
      ],
    );

    final restored = EditorProject.decode(project.export());
    expect(restored.scenes.single.beats, hasLength(100));
    expect(restored.assets[asset.key]!.bytes, asset.bytes);
    expect(restored.validate(), isEmpty);
  });

  test('validation locates broken jumps and unreferenced local assets', () {
    final missing = EditorProject.create('异常作品').copyWith(
      scenes: [
        EditorScene('开场', [
          const StoryBeat('分镜', [
            EditCommand('warp', {'name': '不存在'}),
            EditCommand('background', {'image': 'local_missing'}),
          ]),
        ]),
      ],
    );

    final issues = missing.validate();
    expect(issues, contains(contains('跳转目标不存在')));
    expect(issues, contains(contains('本地素材缺失')));
  });

  test('validateIssues 携带可前往定位的 (幕/分镜/指令)', () {
    final project = EditorProject.create('定位作品').copyWith(
      scenes: [
        const EditorScene('第一幕', [
          StoryBeat('分镜 1', [
            EditCommand('dialogue', {'name': '阿米娅', 'text': '开场'}),
          ]),
          StoryBeat('分镜 2', [
            EditCommand('dialogue', {'name': '陈', 'text': '过场'}),
            EditCommand('subtitle', {'text': '越界', 'y': '-10'}),
          ]),
        ]),
        const EditorScene('第二幕', [
          StoryBeat('分镜 3', [
            EditCommand('warp', {'name': '不存在'}),
          ]),
        ]),
      ],
    );

    final issues = project.validateIssues();
    final outOfRange = issues.singleWhere(
      (issue) => issue.message.contains('超出舞台范围'),
    );
    expect(outOfRange.locatable, isTrue);
    expect(outOfRange.sceneIndex, 0);
    expect(outOfRange.beatIndex, 1);
    expect(outOfRange.commandIndex, 1);

    final brokenWarp = issues.singleWhere(
      (issue) => issue.message.contains('跳转目标不存在'),
    );
    expect(brokenWarp.locatable, isTrue);
    expect(brokenWarp.sceneIndex, 1);
    expect(brokenWarp.beatIndex, 0);
    expect(brokenWarp.commandIndex, 0);

    // validate() 与结构化结果保持一致的消息。
    expect(
      project.validate(),
      equals([for (final issue in issues) issue.message]),
    );
  });

  test('同名分镜的相同校验问题都保留，位置互不覆盖', () {
    final project = EditorProject.create('同名分镜').copyWith(
      scenes: [
        const EditorScene('第一幕', [
          StoryBeat('分镜 2', [
            EditCommand('subtitle', {'text': '越界', 'y': '-10'}),
          ]),
          StoryBeat('分镜 2', [
            EditCommand('subtitle', {'text': '越界', 'y': '-10'}),
          ]),
        ]),
      ],
    );

    final issues = project.validateIssues();
    // 两个分镜同名且消息相同：按消息去重会丢掉前一个的「前往」地址。
    expect(issues, hasLength(2));
    expect(issues[0].beatIndex, 0);
    expect(issues[1].beatIndex, 1);
  });

  test('assets reject invalid type, dimensions and digest changes', () {
    expect(
      () => EditorAsset.create('story.exe', Uint8List.fromList([1])),
      throwsFormatException,
    );
    expect(
      () => EditorAsset.create(
        'bg.png',
        Uint8List.fromList([1]),
        width: 0,
        height: 1,
      ),
      throwsFormatException,
    );
    final asset = EditorAsset.create(
      'voice.mp3',
      Uint8List.fromList([1, 2, 3]),
    );
    final json = asset.toJson()..['data'] = base64Encode([9, 9, 9]);
    expect(() => EditorAsset.fromJson(json), throwsFormatException);
  });
  test('project metadata survives export and import', () {
    final project = EditorProject.create('派生作品')
        .copyWith(derivedFrom: 'story/main.txt');

    final restored = EditorProject.decode(project.export());
    expect(restored.title, '派生作品');
    expect(restored.derivedFrom, 'story/main.txt');
    expect(restored.updatedAt, project.updatedAt);
  });
  test('draft keeps assets separate and verifies them when restored', () async {
    final asset = EditorAsset.create(
      'bg.png',
      Uint8List.fromList([1, 2, 3]),
      width: 16,
      height: 9,
    );
    final project = EditorProject.create('草稿')
        .copyWith(assets: {asset.key: asset});
    final draft = project.encodeDraft();
    final draftJson = utf8.decode(draft);

    expect(draftJson, contains('"draftAssets":1'));
    expect(draftJson, isNot(contains('"data"')));
    expect(draftJson, isNot(contains('"script"')));

    final restored = await EditorProject.decodeDraft(
      draft,
      (key) async => key == '${project.id}/${asset.key}' ? asset.bytes : null,
    );
    expect(restored.assets[asset.key]!.bytes, asset.bytes);
    expect(
      EditorProject.decode(project.export()).assets[asset.key]!.bytes,
      asset.bytes,
    );

    await expectLater(
      EditorProject.decodeDraft(draft, (_) async => Uint8List.fromList([9])),
      throwsFormatException,
    );
  });

  test('立绘清除命令保留引擎识别的 char_empty 标记', () {
    const clear = EditCommand('charslot', {'slot': 'm', 'name': 'char_empty'});
    final command = StoryScript.parse(clear.source).commands.single;

    expect(command.tag, 'charslot');
    expect(command.value('slot'), 'm');
    expect(command.value('name'), 'char_empty');
  });
  test('官方 Character 双人立绘导入为可编辑节点并保留未编辑参数', () {
    const source =
        '[Character(name="char_108_silent_1#3",name2="char_242_mayer#2",fadetime=1,blackstart=0.2)]';
    final project = EditorProject.fromScript('双人立绘', StoryScript.parse(source));
    final imported = project.scenes.single.beats.single.commands.single;

    expect(imported.tag, 'character');
    expect(imported.raw, isNull);
    expect(imported.value('name'), 'char_108_silent_1#3');
    expect(imported.value('name2'), 'char_242_mayer#2');
    expect(editorFields['character']?.$1, contains('立绘'));

    final edited = imported.withArgs({'focus': '2'});
    expect(edited.value('blackstart'), '0.2');
    final roundTrip = EditorProject.decode(
      project
          .copyWith(
            scenes: [
              project.scenes.single.copyWith(
                beats: [
                  project.scenes.single.beats.single.copyWith(
                    commands: [edited],
                  ),
                ],
              ),
            ],
          )
          .export(),
    ).compile().script.commands.single;
    expect(roundTrip.tag, 'character');
    expect(roundTrip.value('name2'), 'char_242_mayer#2');
    expect(roundTrip.value('focus'), '2');
    expect(roundTrip.value('blackstart'), '0.2');
  });
  test('official imports split long stories into manageable scenes', () {
    final script = StoryScript.parse(
      List.generate(61, (i) => '[name="阿米娅"] 台词 $i').join('\n'),
    );
    final project = EditorProject.fromScript('长篇', script);

    expect(project.scenes.map((scene) => scene.beats.length), [30, 30, 1]);
    expect(project.compile().script.commands, hasLength(61));
    expect(project.validateIssues(), isEmpty);
  });
  test('official import keeps command order when splitting on background', () {
    final script = StoryScript.parse(
      [
        '[Background(image="room_a")]',
        for (var i = 0; i < 8; i++) '[name="阿米娅"] 台词 $i',
        '[Background(image="room_b")]',
        '[name="阿米娅"] 新背景',
      ].join('\n'),
    );
    final project = EditorProject.fromScript('背景切换', script);

    expect(project.scenes.map((scene) => scene.beats.length), [8, 1]);
    expect(
      project.compile().script.commands.map(
        (command) => (command.tag, command.value('image'), command.text),
      ),
      orderedEquals(
        script.commands.map(
          (command) => (command.tag, command.value('image'), command.text),
        ),
      ),
    );
  });
}
