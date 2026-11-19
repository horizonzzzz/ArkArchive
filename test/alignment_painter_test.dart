import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:arknights_story_player/story_player/data/asset_store.dart';
import 'package:arknights_story_player/story_player/data/media_catalog.dart';
import 'package:arknights_story_player/story_player/fx/fx_asset.dart';
import 'package:arknights_story_player/story_player/fx/fx_loader.dart';
import 'package:arknights_story_player/story_player/fx/fx_simulation.dart';
import 'package:arknights_story_player/story_player/stage_state.dart';
import 'package:arknights_story_player/story_player/script.dart';
import 'package:arknights_story_player/story_player/ui/stage_painter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final catalog = MediaCatalog(
    variables: {},
    characters: {},
    backgroundPpu: {},
  );

  Future<ui.Image> solid(
    ui.Color color, {
    int width = 1,
    int height = 1,
  }) async {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(color, ui.BlendMode.src);
    final picture = recorder.endRecording();
    addTearDown(picture.dispose);
    final image = await picture.toImage(width, height);
    addTearDown(image.dispose);
    return image;
  }

  Future<List<int>> pixel(
    StageState state, {
    MediaCatalog? mediaCatalog,
    Map<Uri, ui.Image> textures = const {},
    Map<String, ui.Image> sprites = const {},
    int x = 640,
    int y = 360,
  }) async {
    final recorder = ui.PictureRecorder();
    StagePainter(
      state,
      mediaCatalog ?? catalog,
      textures,
      null,
      null,
      sprites,
    ).paint(ui.Canvas(recorder), const ui.Size(1280, 720));
    final picture = recorder.endRecording();
    addTearDown(picture.dispose);
    final image = await picture.toImage(1280, 720);
    addTearDown(image.dispose);
    final bytes = (await image.toByteData())!;
    final offset = (y * 1280 + x) * 4;
    return List.generate(4, (i) => bytes.getUint8(offset + i));
  }

  test('白黑遮罩只影响边缘，旧电视色调按独立图层叠加', () async {
    final store = AssetStore();
    addTearDown(store.close);
    final loader = FxLoader('asset:///assets/fx-runtime/', store);
    final gray = await solid(const ui.Color(0xff808080));
    final state = StageState()..images.add(StageImage('gray')..fit = 'fill');
    const grayPixel = [128, 128, 128, 255];
    final textures = {catalog.image('gray'): gray};

    Future<StageEffect> effect(String name, int layer) async => StageEffect(
      FxSimulation(await loader.load(name)),
      group: 'bgeffect',
      layer: layer,
      offset: const ui.Offset(300, 0),
    );
    Future<List<int>> sample([int x = 640]) =>
        pixel(state, textures: textures, x: x);

    final white = await effect('avg_062_white_01', 1);
    state.effects.add(white);
    expect(await sample(), grayPixel);
    final whiteEdge = await sample(4);
    expect(whiteEdge[0], greaterThan(148));
    expect((await sample(1275))[0], closeTo(whiteEdge[0], 1));
    white.delayRemaining = 1;
    expect(await sample(4), grayPixel);
    white
      ..delayRemaining = 0
      ..alpha = .5;
    expect((await sample(4))[0], inExclusiveRange(128, whiteEdge[0]));

    final black = await effect('avg_062_black_01', 1);
    state.effects
      ..clear()
      ..add(black);
    expect(await sample(), grayPixel);
    expect((await sample(4))[0], lessThan(100));
    final oldTv = await effect('avg_old_tv_01', 2);
    state.effects.add(oldTv);
    final warmCenter = await sample();
    expect(warmCenter[0], greaterThan(128));
    expect(warmCenter[2], lessThan(128));
    state.effects.remove(oldTv);
    expect(await sample(), grayPixel);
    state.blockerAlpha = 1;
    state.effects
      ..clear()
      ..add(white);
    expect(await sample(4), [0, 0, 0, 255]);
  });

  test('背景特效按资源设置绘制在 CG 前面或后面', () async {
    final red = await solid(const ui.Color(0xffff0000));
    final green = await solid(const ui.Color(0xff00ff00));
    Future<List<int>> sample({
      required bool afterImages,
      bool afterBlocker = false,
    }) async {
      final asset = FxAsset.parse({
        'version': 1,
        'name': 'layer_test',
        'duration': 1,
        'isLoop': true,
        if (afterImages) 'drawAfterImages': true,
        'drawAfterBlocker': afterBlocker,
        'emitters': [
          {
            'name': 'quad',
            'kind': 'mesh',
            'scale': [100, 100],
            'material': {'main': 'red.png', 'srcBlend': 5, 'dstBlend': 10},
          },
        ],
      }, base: Uri.parse('https://example.test/fx/'));
      final state = StageState()
        ..images.add(StageImage('color')..fit = 'fill')
        ..effects.add(
          StageEffect(FxSimulation(asset), group: 'bgeffect', layer: 0),
        );
      return pixel(
        state,
        textures: {
          catalog.image('color'): green,
          asset.textureUri('red.png'): red,
        },
      );
    }

    expect(await sample(afterImages: false), [0, 255, 0, 255]);
    expect(await sample(afterImages: true), [255, 0, 0, 255]);
    expect(await sample(afterImages: false, afterBlocker: true), [
      0,
      255,
      0,
      255,
    ]);
    expect(await sample(afterImages: true, afterBlocker: true), [
      255,
      0,
      0,
      255,
    ]);
  });

  test('背景失焦时背景特效与背景共用离屏层，保留叠加混合并同步模糊', () async {
    final darkBlue = await solid(const ui.Color(0xff102030));
    final addGreen = await solid(const ui.Color(0xff004000));
    final asset = FxAsset.parse({
      'version': 1,
      'name': 'bg_add_focus',
      'duration': 1,
      'isLoop': true,
      'emitters': [
        {
          'name': 'quad',
          'kind': 'mesh',
          'scale': [400, 400],
          'material': {'main': 'green.png', 'srcBlend': 5, 'dstBlend': 1},
        },
      ],
    }, base: Uri.parse('https://example.test/fx/'));
    final state = StageState()
      ..backgrounds.add(StageImage('bg')..fit = 'fill')
      ..focus['bg'] = 0.8
      ..effects.add(
        StageEffect(FxSimulation(asset), group: 'bgeffect', layer: 1),
      );
    final rgba = await pixel(
      state,
      textures: {
        catalog.image('bg'): darkBlue,
        asset.textureUri('green.png'): addGreen,
      },
    );
    // 同层 Additive 叠加应在原暗蓝背景 (16, 32, 48) 上增加绿色分量，而不是覆盖成纯绿。
    expect(rgba[0], closeTo(16, 2));
    expect(rgba[1], closeTo(96, 2));
    expect(rgba[2], closeTo(48, 2));
    expect(rgba[3], 255);
  });

  test('声明前景的刀光在完整黑幕上绘制，普通特效仍受遮罩覆盖', () async {
    final red = await solid(const ui.Color(0xffff0000));
    for (final foreground in [false, true]) {
      final asset = FxAsset.parse({
        'version': 1,
        'name': 'slash',
        'duration': 1,
        'isLoop': false,
        'drawAfterBlocker': foreground,
        'emitters': [
          {
            'name': 'quad',
            'kind': 'mesh',
            'scale': [100, 100],
            'material': {'main': 'red.png', 'srcBlend': 5, 'dstBlend': 10},
          },
        ],
      });
      final state = StageState()..blockerAlpha = 1;
      state.effects.add(
        StageEffect(FxSimulation(asset), group: 'effect', layer: 1),
      );
      expect(
        await pixel(state, textures: {asset.textureUri('red.png'): red}),
        foreground ? [255, 0, 0, 255] : [0, 0, 0, 255],
      );
    }
  });

  for (final focus in [false, true]) {
    test(
      '${focus ? "聚焦" : "镜头"}反色将 RGB(10,20,30) 转为 RGB(245,235,225)',
      () async {
        final state = StageState();
        if (focus) {
          state.focus['bg'] = 1;
          state.focusBlur = false;
          state.focusColor = 'Colorinverse';
        } else {
          state.inverse = 1;
        }
        state.backgrounds.add(StageImage('color')..fit = 'fill');
        final rgba = await pixel(
          state,
          textures: {
            catalog.image('color'): await solid(const ui.Color(0xff0a141e)),
          },
        );
        for (var i = 0; i < 3; i++) {
          expect(rgba[i], closeTo([245, 235, 225][i], 1));
        }
        expect(rgba[3], 255);
      },
    );
  }

  test('切入窗口绘制交叉淡化并缩放立绘位置', () async {
    final characters = <String, dynamic>{
      for (final name in ['a', 'b'])
        name: {
          'array': [
            {'image': name},
          ],
          'size': {'x': 20, 'y': 20},
          'pos': {'x': 0, 'y': 0},
        },
    };
    final media = MediaCatalog(
      variables: {},
      characters: characters,
      backgroundPpu: {},
    );
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
    final mixed = await pixel(
      state,
      mediaCatalog: media,
      textures: textures,
      x: 720,
    );
    expect(mixed[0], closeTo(98, 2));
    expect(mixed[1], closeTo(34, 2));
    expect(mixed[2], closeTo(162, 2));
    final background = await pixel(
      state,
      mediaCatalog: media,
      textures: textures,
      x: 680,
    );
    expect(background.take(3), [137, 137, 137]);
  });
  test('地点印章在 500ms 可见、4500ms 淡出、5000ms 消失', () async {
    final state = StageState();
    final stamp = LocationStamp(ui.Offset.zero, const ['', ''], '')
      ..elapsedMs = 500;
    state.stamps.add(stamp);
    final sprites = {
      'stamp_back_shadow': await solid(const ui.Color(0xffffffff)),
    };
    expect((await pixel(state, sprites: sprites))[0], 255);
    stamp.elapsedMs = 4500;
    expect((await pixel(state, sprites: sprites))[0], closeTo(128, 1));
    stamp.elapsedMs = 5000;
    expect((await pixel(state, sprites: sprites))[0], 0);
  });
  test('通讯窗口语音波形仅在对应角色发言时绘制', () async {
    final frame = InterludeFrame('terminal')
      ..maskId = 'group_interclude_square_common'
      ..size = const ui.Offset(300, 300)
      ..offset = const ui.Offset(-450, 125)
      ..charName = '伯塔尼'
      ..voiceActive = true;
    final state = StageState()..interludes['terminal'] = frame;
    final active = await pixel(state, x: 146, y: 407);
    frame.voiceActive = false;
    final inactive = await pixel(state, x: 595, y: 392);
    expect(active[0], greaterThan(inactive[0]));
  });
  test('通讯浮层按表情 faceRect 对齐头像并绘制表情层', () async {
    const imageKey = r'avg_4223_botany_1#1$1';
    final media = MediaCatalog(
      variables: const {},
      characters: {
        'avg_4223_botany_1': {
          'size': {'x': 1180, 'y': 1180},
          'pos': {'x': 30, 'y': 245},
          'groups': [
            {
              'mode': 'face_overlay',
              'base': r'avg_4223_botany_1/avg_4223_botany_1$1',
              'faceRect': {'x': 714, 'y': 326, 'w': 145, 'h': 203},
            },
          ],
          'array': [
            {
              'name': r'1$1',
              'alias': '',
              'group': 0,
              'face': r'avg_4223_botany_1/1$1',
              'body': 0,
              'index': 0,
            },
          ],
        },
      },
      backgroundPpu: const {},
    );
    final art = media.character(imageKey)!;
    expect(art.faceRect, const ui.Rect.fromLTWH(714, 326, 145, 203));

    final dependencies = media.dependencies(
      StoryScript.parse('[interlude(channel=3,type=3,name="$imageKey")]'),
      [],
    );
    expect(dependencies, containsAll(art.assets));

    final frame = InterludeFrame('terminal')
      ..maskId = 'group_interclude_square_common'
      ..type = 3
      ..size = const ui.Offset(300, 300)
      ..offset = const ui.Offset(-450, 125);
    frame.elements['avatar'] = InterludeElement('avatar')
      ..image = imageKey
      ..offset = const ui.Offset(-400, 50)
      ..visible = true
      ..alpha = 1;
    final body = await solid(
      const ui.Color(0xffb03030),
      width: 1740,
      height: 1740,
    );
    final face = await solid(const ui.Color(0xff37a654));
    final centerPixel = await pixel(
      StageState()..interludes['terminal'] = frame,
      mediaCatalog: media,
      textures: {art.body: body, art.face!: face},
      x: 190,
      y: 235,
    );
    final bodyPixel = await pixel(
      StageState()..interludes['terminal'] = frame,
      mediaCatalog: media,
      textures: {art.body: body, art.face!: face},
      x: 112,
      y: 235,
    );
    expect(centerPixel.take(3), [55, 166, 84]);
    expect(bodyPixel.take(3), [176, 48, 48]);

    const helaKey = r'avg_188_helage_1#1$1';
    final helaMedia = MediaCatalog(
      variables: const {},
      characters: {
        'avg_188_helage_1': {
          'size': {'x': 1135, 'y': 1135},
          'pos': {'x': 50, 'y': 150},
          'groups': [
            {
              'mode': 'face_overlay',
              'base': r'avg_188_helage_1/avg_188_helage_1$1',
              'faceRect': {'x': 725, 'y': 101, 'w': 115, 'h': 120},
            },
          ],
          'array': [
            {
              'name': r'1$1',
              'alias': '',
              'group': 0,
              'face': r'avg_188_helage_1/1$1',
              'body': 0,
              'index': 0,
            },
          ],
        },
      },
      backgroundPpu: const {},
    );
    final hela = helaMedia.character(helaKey)!;
    final helaFrame = InterludeFrame('terminal')
      ..maskId = 'group_interclude_square_common'
      ..type = 3
      ..size = const ui.Offset(300, 300)
      ..offset = const ui.Offset(450, 125);
    helaFrame.elements['avatar'] = InterludeElement('avatar')
      ..image = helaKey
      ..visible = true
      ..alpha = 1;
    final helaBody = await solid(
      const ui.Color(0xffb03030),
      width: 1620,
      height: 1620,
    );
    final helaFace = await solid(const ui.Color(0xff37a654));
    final helaCenter = await pixel(
      StageState()..interludes['terminal'] = helaFrame,
      mediaCatalog: helaMedia,
      textures: {hela.body: helaBody, hela.face!: helaFace},
      x: 1090,
      y: 235,
    );
    final helaBodyPixel = await pixel(
      StageState()..interludes['terminal'] = helaFrame,
      mediaCatalog: helaMedia,
      textures: {hela.body: helaBody, hela.face!: helaFace},
      x: 1015,
      y: 235,
    );
    expect(helaCenter.take(3), [55, 166, 84]);
    expect(helaBodyPixel.take(3), [176, 48, 48]);
  });
  test('通讯浮层按 Raid(i)an 脚本位置和立绘元数据裁入上半身', () async {
    const imageKey = r'avg_npc_1730_1#6$1';
    final media = MediaCatalog(
      variables: const {},
      characters: {
        'avg_npc_1730_1': {
          'size': {'x': 880, 'y': 880},
          'pos': {'x': -50, 'y': 150},
          'groups': const [],
          'array': [
            {
              'name': r'6$1',
              'alias': '',
              'group': -1,
              'image': r'avg_npc_1730_1/6$1',
              'body': 0,
              'index': 5,
            },
          ],
        },
      },
      backgroundPpu: const {},
    );
    final art = media.character(imageKey)!;
    final dependencies = media.dependencies(
      StoryScript.parse('[interlude(channel=4,type=3,name="$imageKey")]'),
      [],
    );
    expect(dependencies, contains(art.body));

    final frame = InterludeFrame('terminal')
      ..maskId = 'group_interclude_square_common'
      ..type = 3
      ..size = const ui.Offset(300, 300)
      ..offset = const ui.Offset(450, 125);
    frame.elements['avatar'] = InterludeElement('avatar')
      ..image = imageKey
      ..offset = const ui.Offset(450, -5)
      ..visible = true
      ..alpha = 1;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder)
      ..drawColor(const ui.Color(0xffb03030), ui.BlendMode.src);
    canvas.drawRect(
      const ui.Rect.fromLTWH(540, 100, 180, 160),
      ui.Paint()..color = const ui.Color(0xff37a654),
    );
    final picture = recorder.endRecording();
    addTearDown(picture.dispose);
    final portrait = await picture.toImage(1124, 1124);
    addTearDown(portrait.dispose);

    final center = await pixel(
      StageState()..interludes['terminal'] = frame,
      mediaCatalog: media,
      textures: {art.body: portrait},
      x: 1090,
      y: 235,
    );
    final lower = await pixel(
      StageState()..interludes['terminal'] = frame,
      mediaCatalog: media,
      textures: {art.body: portrait},
      x: 1090,
      y: 310,
    );
    expect(center.take(3), [55, 166, 84]);
    expect(lower.take(3), [176, 48, 48]);
  });
}
