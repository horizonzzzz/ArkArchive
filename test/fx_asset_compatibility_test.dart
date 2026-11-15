import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:arknights_story_player/story_player/data/asset_store.dart';
import 'package:arknights_story_player/story_player/fx/fx_loader.dart';
import 'package:arknights_story_player/story_player/fx/fx_painter.dart';
import 'package:arknights_story_player/story_player/fx/fx_simulation.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('全部打包特效兼容现有描述、纹理解码和绘制管线', () async {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final descriptions = manifest.listAssets().where(
      (path) =>
          path.startsWith('assets/fx-runtime/') && path.endsWith('/fx.json'),
    );
    expect(descriptions, isNotEmpty);
    final store = AssetStore();
    addTearDown(store.close);
    final loader = FxLoader(storyFxRoot, store);
    for (final description in descriptions) {
      final name = description.split('/').reversed.elementAt(1);
      final asset = await loader.load(name);
      final textures = <Uri, ui.Image>{};
      try {
        for (final texture in asset.textures) {
          final uri = asset.textureUri(texture);
          final codec = await ui.instantiateImageCodec(await loader.bytes(uri));
          try {
            textures[uri] = (await codec.getNextFrame()).image;
          } finally {
            codec.dispose();
          }
        }
        final simulation = FxSimulation(asset, seed: 17);
        for (final time in [0.0, .1, .3, .7]) {
          simulation.advance(time - simulation.elapsed);
          final recorder = ui.PictureRecorder();
          final canvas = ui.Canvas(recorder);
          final effect = StageEffect(simulation, group: 'effect', layer: 1);
          paintEffects(canvas, [effect], textures, 'effect');
          paintEffects(
            canvas,
            [effect],
            textures,
            'effect',
            afterBlocker: true,
          );
          final picture = recorder.endRecording();
          try {
            final image = await picture.toImage(1280, 720);
            image.dispose();
          } finally {
            picture.dispose();
          }
        }
      } finally {
        for (final image in textures.values) {
          image.dispose();
        }
      }
    }
  });
}
