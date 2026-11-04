@TestOn('browser')
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:arknights_story_player/story_player/data/file_cache.dart';

void main() {
  test('浏览器缓存可跨实例读取，音频使用本地数据地址', () async {
    final uri = Uri.parse(
      'https://example.test/${DateTime.now().microsecondsSinceEpoch}.mp3',
    );
    await FileCache().write(uri, Uint8List.fromList([1, 2, 3]));
    final cache = FileCache();
    expect(await cache.read(uri), [1, 2, 3]);
    final playable = await cache.playableUri(uri);
    expect(playable.scheme, 'data');
    expect(playable.data!.contentAsBytes(), [1, 2, 3]);
  });

  test('浏览器缓存统计和单项删除', () async {
    final cache = FileCache();
    final uri = Uri.parse(
      'https://example.test/${DateTime.now().microsecondsSinceEpoch}.png',
    );
    final previousSize = await cache.size();
    await cache.write(uri, Uint8List.fromList([1, 2, 3, 4]));
    expect(await cache.size(), previousSize + 4);
    expect(await cache.location(), isNull);
    await cache.delete(uri);
    expect(await cache.read(uri), isNull);
    expect(await cache.size(), previousSize);
    final keep = Uri.parse('https://example.test/retained');
    await cache.write(keep, Uint8List.fromList([9]));
    await cache.write(uri, Uint8List.fromList([1, 2]));
    await cache.clear(keep: {keep});
    expect(await cache.read(uri), isNull);
    expect(await cache.read(keep), [9]);
    await cache.delete(keep);
  });
}
