import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:arknights_story_player/story_player/data/asset_store.dart';
import 'package:arknights_story_player/story_player/fx/fx_asset.dart';
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
        await decodeTextures(loader, asset, textures);
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

  for (final (name, offset, rotation3D, visibleArea) in [
    (
      'avg_dao_guiji_hit_02',
      ui.Offset.zero,
      ui.Offset.zero,
      const ui.Rect.fromLTRB(470, 250, 790, 470),
    ),
    (
      'avg_daoguang_attack_02_small',
      const ui.Offset(-50, -360),
      const ui.Offset(-80 * math.pi / 180, -80 * math.pi / 180),
      const ui.Rect.fromLTRB(200, 320, 1100, 675),
    ),
  ]) {
    test('$name 在剧情指定位置的舞台内可见', () async {
      final store = AssetStore();
      addTearDown(store.close);
      final loader = FxLoader(storyFxRoot, store);
      final asset = await loader.load(name);
      final textures = <Uri, ui.Image>{};
      addTearDown(() {
        for (final image in textures.values) {
          image.dispose();
        }
      });
      await decodeTextures(loader, asset, textures);
      final simulation = FxSimulation(asset, seed: 455);
      final effect = StageEffect(
        simulation,
        group: 'effect',
        layer: 1,
        offset: offset,
        rotation3D: rotation3D,
      );
      var visiblePixels = 0;
      for (var frame = 0; frame < 12; frame++) {
        simulation.advance(1 / 60);
        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(recorder)
          ..drawColor(const ui.Color(0xff4c4c4c), ui.BlendMode.src);
        paintEffects(canvas, [effect], textures, 'effect', afterBlocker: true);
        final picture = recorder.endRecording();
        final image = await picture.toImage(1280, 720);
        picture.dispose();
        final pixels = (await image.toByteData())!;
        image.dispose();
        for (var y = visibleArea.top.toInt(); y < visibleArea.bottom; y++) {
          for (var x = visibleArea.left.toInt(); x < visibleArea.right; x++) {
            if (pixels.getUint8((y * 1280 + x) * 4) > 150) visiblePixels++;
          }
        }
      }
      expect(visiblePixels, greaterThan(100));
    });
  }
}

Future<void> decodeTextures(
  FxLoader loader,
  FxAsset asset,
  Map<Uri, ui.Image> textures,
) async {
  for (final texture in asset.textures) {
    final uri = asset.textureUri(texture);
    final codec = await ui.instantiateImageCodec(await loader.bytes(uri));
    try {
      textures[uri] = (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
    }
  }
}
