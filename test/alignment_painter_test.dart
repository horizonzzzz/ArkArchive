import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';
import 'package:arknights_story_player/story_player/data/media_catalog.dart';
import 'package:arknights_story_player/story_player/stage_state.dart';
import 'package:arknights_story_player/story_player/ui/stage_painter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final catalog = MediaCatalog(variables: {}, characters: {}, backgroundPpu: {});

  Future<ui.Image> solid(ui.Color color) async {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(color, ui.BlendMode.src);
    final picture = recorder.endRecording();
    addTearDown(picture.dispose);
    final image = await picture.toImage(1, 1);
    addTearDown(image.dispose);
    return image;
  }

  Future<List<int>> pixel(StageState state, {
    MediaCatalog? mediaCatalog,
    Map<Uri, ui.Image> textures = const {},
    Map<String, ui.Image> sprites = const {},
    int x = 640, int y = 360,
  }) async {
    final recorder = ui.PictureRecorder();
    StagePainter(state, mediaCatalog ?? catalog, textures, null, null, sprites)
        .paint(ui.Canvas(recorder), const ui.Size(1280, 720));
    final picture = recorder.endRecording();
    addTearDown(picture.dispose);
    final image = await picture.toImage(1280, 720);
    addTearDown(image.dispose);
    final bytes = (await image.toByteData())!;
    final offset = (y * 1280 + x) * 4;
    return List.generate(4, (i) => bytes.getUint8(offset + i));
  }

  for (final focus in [false, true]) {
    test('${focus ? "聚焦" : "镜头"}反色将 RGB(10,20,30) 转为 RGB(245,235,225)', () async {
      final state = StageState();
      if (focus) {
        state.focus['bg'] = 1;
        state.focusBlur = false;
        state.focusColor = 'Colorinverse';
      } else {
        state.inverse = 1;
      }
      state.backgrounds.add(StageImage('color')..fit = 'fill');
      final rgba = await pixel(state, textures: {
        catalog.image('color'): await solid(const ui.Color(0xff0a141e)),
      });
      for (var i = 0; i < 3; i++) {
        expect(rgba[i], closeTo([245, 235, 225][i], 1));
      }
      expect(rgba[3], 255);
    });
  }

  test('切入窗口绘制交叉淡化并缩放立绘位置', () async {
    final characters = <String, dynamic>{
      for (final name in ['a', 'b']) name: {
        'array': [{'image': name}],
        'size': {'x': 20, 'y': 20},
        'pos': {'x': 0, 'y': 0},
      },
    };
    final media = MediaCatalog(variables: {}, characters: characters, backgroundPpu: {});
    final textures = {
      media.character('a')!.body: await solid(const ui.Color(0xffff0000)),
      media.character('b')!.body: await solid(const ui.Color(0xff0000ff)),
    };
    final window = CutinWindow('w')
      ..maskW = 400
      ..maskH = 720
      ..targetW = 400
      ..charOffsetX = 40
      ..charOffsetY = 360
      ..zoom = 2
      ..characters.addAll([CutinCharacter('a', .5), CutinCharacter('b', .5)]);
    final state = StageState()..cutins['w'] = window;
    final mixed = await pixel(state, mediaCatalog: media, textures: textures, x: 720);
    expect(mixed[0], closeTo(98, 2));
    expect(mixed[1], closeTo(34, 2));
    expect(mixed[2], closeTo(162, 2));
    final background = await pixel(state, mediaCatalog: media, textures: textures, x: 680);
    expect(background.take(3), [137, 137, 137]);
  });
  test('地点印章在 500ms 可见、4500ms 淡出、5000ms 消失', () async {
    final state = StageState();
    final stamp = LocationStamp(ui.Offset.zero, const ['', ''], '')..elapsedMs = 500;
    state.stamps.add(stamp);
    final sprites = {'stamp_back_shadow': await solid(const ui.Color(0xffffffff))};
    expect((await pixel(state, sprites: sprites))[0], 255);
    stamp.elapsedMs = 4500;
    expect((await pixel(state, sprites: sprites))[0], closeTo(128, 1));
    stamp.elapsedMs = 5000;
    expect((await pixel(state, sprites: sprites))[0], 0);
  });
}
