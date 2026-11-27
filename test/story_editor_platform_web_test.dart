import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_test/flutter_test.dart';
import 'package:arknights_story_player/story_editor/editor_platform.dart';
import 'package:arknights_story_player/story_editor/editor_project.dart';

Future<T> _bounded<T>(Future<T> future, String operation) => future.timeout(
  const Duration(seconds: 15),
  onTimeout: () => throw TimeoutException('Web storage timeout: $operation'),
);

void main() {
  test('Web 草稿将素材单独持久化并可删除', () async {
    final storage = EditorStorage();
    final asset = EditorAsset.create(
      'sample.png',
      Uint8List.fromList([1, 2, 3]),
      width: 1,
      height: 1,
    );
    final project = EditorProject.create('Web 存储回归')
        .copyWith(assets: {asset.key: asset});
    addTearDown(() => _bounded(storage.delete(project.id), 'clean up'));

    await _bounded(storage.save(project), 'save');
    const position = EditorPosition(scene: 1, beat: 2, command: 3);
    await _bounded(
      storage.savePosition(project.id, project.updatedAt, position),
      'save position',
    );
    final restored = (await _bounded(
      storage.list(),
      'list after save',
    )).singleWhere((item) => item.id == project.id);
    expect(restored.assets[asset.key]?.bytes, asset.bytes);
    expect(restored.lastPosition?.toJson(), position.toJson());

    final newer = project.copyWith(
      updatedAt: project.updatedAt.add(const Duration(seconds: 1)),
    );
    await _bounded(storage.save(newer), 'save newer draft');
    final latest = (await _bounded(
      storage.list(),
      'list new draft',
    )).singleWhere((item) => item.id == project.id);
    expect(latest.lastPosition, isNull);

    await _bounded(storage.delete(project.id), 'delete');
    expect(
      (await _bounded(
        storage.list(),
        'list after delete',
      )).any((item) => item.id == project.id),
      isFalse,
    );
  }, skip: kIsWeb ? false : '仅在浏览器中运行 CacheStorage 测试');
}
