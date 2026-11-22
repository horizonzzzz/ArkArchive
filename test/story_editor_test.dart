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
}
