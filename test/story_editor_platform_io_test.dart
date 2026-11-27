@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:arknights_story_player/story_editor/editor_platform.dart';
import 'package:arknights_story_player/story_editor/editor_project.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('原生草稿分离素材和导航位置，并兼容内嵌素材', () async {
    final root = await Directory.systemTemp.createTemp('story-editor-test');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (_) async => root.path);
    addTearDown(() async {
      messenger.setMockMethodCallHandler(channel, null);
      await root.delete(recursive: true);
    });

    final asset = EditorAsset.create(
      'sample.png',
      Uint8List.fromList([1, 2, 3]),
      width: 1,
      height: 1,
    );
    final project = EditorProject.create('草稿存储回归')
        .copyWith(assets: {asset.key: asset});
    final storage = EditorStorage();
    final drafts = '${root.path}/story-editor-v1';
    final file = File('$drafts/${project.id}.json');
    await file.create(recursive: true);
    await file.writeAsBytes(project.export());
    expect((await storage.list()).single.assets[asset.key]?.bytes, asset.bytes);

    await storage.save(project);
    final metadata = await file.readAsString();
    expect(jsonDecode(metadata), isNot(contains('script')));
    final media = File('$drafts/assets/${project.id}/${asset.key}');
    expect(await media.readAsBytes(), asset.bytes);

    const position = EditorPosition(scene: 0, beat: 3, command: 2);
    await storage.savePosition(project.id, project.updatedAt, position);
    expect(await file.readAsString(), metadata);
    final restored = (await EditorStorage().list()).single;
    expect(restored.assets[asset.key]?.bytes, asset.bytes);
    expect(restored.lastPosition?.toJson(), position.toJson());

    final newer = project.copyWith(
      updatedAt: project.updatedAt.add(const Duration(seconds: 1)),
    );
    await storage.save(newer);
    expect((await storage.list()).single.lastPosition, project.lastPosition);

    await storage.delete(project.id);
    expect(await storage.list(), isEmpty);
    expect(await media.exists(), isFalse);
    expect(await File('$drafts/${project.id}.position').exists(), isFalse);
  });
}
