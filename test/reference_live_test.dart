import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:arknights_story_player/story_player/data/file_cache.dart';
import 'package:arknights_story_player/story_player/story_player.dart';

class _NoDiskCache extends FileCache {
  @override
  Future<Uint8List?> read(Uri uri) async => null;
  @override
  Future<void> write(Uri uri, Uint8List bytes) async {}
}

void main() {
  const reference = String.fromEnvironment('STORY_REFERENCE_URL');
  test('按指定的真实剧情检查映射、全部静态依赖与图片解码', () async {
    final store = AssetStore(cache: _NoDiskCache());
    addTearDown(store.close);
    final repository = StoryRepository(store);
    final document = await repository.load(Uri.parse(reference));
    final prepared = await repository.prepare(document);
    expect(document.script.commands.length, greaterThan(10));
    expect(prepared.warnings, isEmpty, reason: prepared.warnings.join('\n'));
    final dependencies = prepared.catalog.dependencies(document.script, []);
    var images = 0, decodedBytes = 0;
    for (final uri in dependencies.where((u) => u.path.endsWith('.png'))) {
      final bytes = store.peek(uri)!;
      final codec = await ui.instantiateImageCodec(bytes);
      final image = (await codec.getNextFrame()).image;
      expect(image.width, greaterThan(0));
      decodedBytes += image.width * image.height * 4;
      images++;
      image.dispose();
      codec.dispose();
    }
    final engine = StoryEngine(document.script, variables: prepared.catalog.variables, typingInterval: Duration.zero);
    addTearDown(engine.dispose);
    final unsupported = document.script.commands.map((c) => c.tag).where((t) => t != 'dialogue' && !engine.handlers.containsKey(t)).toSet();
    debugPrint('REFERENCE title=${document.title} commands=${document.script.commands.length} resources=${dependencies.length} images=$images decodedMiB=${(decodedBytes / 1048576).toStringAsFixed(1)} unsupported=${unsupported.join(',')}');
  }, skip: reference.isEmpty ? '仅显式指定 STORY_REFERENCE_URL 时访问网络' : false, timeout: const Timeout(Duration(minutes: 5)));
}
