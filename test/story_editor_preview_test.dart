import 'package:arknights_story_player/story_editor/editor_preview.dart';
import 'package:arknights_story_player/story_editor/editor_project.dart';
import 'package:arknights_story_player/story_player/data/asset_store.dart';
import 'package:arknights_story_player/story_player/data/media_catalog.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'story_export_test.dart' show MemoryCache;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('素材、FX、舞台状态和缓存隔离可跨作品导出导入', () async {
    final png = Uint8List.sublistView(
      await rootBundle.load('assets/images/slide_mask.png'),
    );
    final requests = <Uri>[];
    final cache = MemoryCache();
    final store = AssetStore(
      cache: cache,
      client: MockClient((request) async {
        requests.add(request.url);
        if (MediaCatalog.tableUris.contains(request.url)) {
          return http.Response('{}', 200);
        }
        if (request.url.path.endsWith('/avg/background/test.png')) {
          return http.Response.bytes(png, 200);
        }
        return http.Response('not found', 404);
      }),
    );
    addTearDown(store.close);
    final resources = EditorPreviewResources(store);
    addTearDown(resources.dispose);
    expect(await resources.effects(), contains('avg_fire_01'));
    final portrait = EditorAsset.create(
      'portrait.png',
      png,
      width: 1,
      height: 1,
    );
    final project = EditorProject.create('演出验证').copyWith(
      assets: {portrait.key: portrait},
      scenes: [
        EditorScene('第一幕', [
          StoryBeat('开场', [
            const EditCommand('background', {'image': 'test', 'fadetime': '0'}),
            EditCommand('charslot', {
              'slot': 'l',
              'name': portrait.key,
              'posto': '8,20',
              'duration': '0',
            }),
            EditCommand('charslot', {
              'slot': 'r',
              'name': portrait.key,
              'posto': '3,4',
              'duration': '0',
            }),
            const EditCommand('blocker', {'a': '0.4', 'fadetime': '0'}),
            const EditCommand('bgeffect', {'name': 'avg_fire_01', 'x': '42'}),
            const EditCommand('dialogue', {'text': '第一句'}),
          ]),
          const StoryBeat('第二幕', [
            EditCommand('dialogue', {'text': '第二句'}),
          ]),
          const StoryBeat('收尾', [
            EditCommand('dialogue', {'text': '第三句'}),
          ]),
        ]),
      ],
    );
    Future<PreparedStage> prepare(EditorProject p) {
      final compiled = p.compile();
      return resources.prepare(
        p,
        compiled,
        end: compiled.script.commands.length,
        audible: false,
        active: () => true,
      );
    }

    final restored = EditorProject.decode(project.export());
    final linear = await prepare(project);
    addTearDown(linear.dispose);
    final resumed = await prepare(restored);
    addTearDown(resumed.dispose);
    expect(resumed.textures[portrait.uri]?.width, 128);
    expect(resumed.textures[resumed.catalog.image('test')]?.width, 128);
    expect(resumed.engine.warnings, isEmpty);
    await linear.engine.start();
    expect(linear.engine.state.text, '第一句');
    final start = restored.compile().ranges[(0, 1)]!.$1;
    expect(await resumed.engine.rebuildBefore(start), isTrue);
    final actual = resumed.engine.state;
    final original = linear.engine.state;
    expect(actual.backgrounds.single.key, original.backgrounds.single.key);
    expect(actual.characters.map((n) => (n.slot, n.actionX, n.actionY)), [
      ('l', 8.0, 20.0),
      ('r', 3.0, 4.0),
    ]);
    expect(
      actual.characters.map((n) => (n.slot, n.actionX, n.actionY)),
      original.characters.map((n) => (n.slot, n.actionX, n.actionY)),
    );
    expect(actual.blockerAlpha, closeTo(original.blockerAlpha, 0.01));
    expect(actual.effects.single.offset.dx, 42);
    expect(actual.effects.single.offset, original.effects.single.offset);
    await resumed.engine.advance();
    expect(actual.text, '第一句');
    await resumed.engine.advance();
    expect(actual.text, '第二句');
    await resumed.engine.advance();
    await resumed.engine.advance();
    expect(actual.text, '第三句');
    expect(requests, hasLength(4));
    expect(cache.data, isEmpty);
    expect(cache.stories, isEmpty);
    expect(store.playbackProgresses, isEmpty);
    expect(store.completedStories, isEmpty);
  });
}
