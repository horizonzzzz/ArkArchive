import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:arknights_story_player/story_player/data/asset_store.dart';
import 'package:arknights_story_player/story_player/fx/fx_asset.dart';
import 'package:arknights_story_player/story_player/fx/fx_loader.dart';
import 'package:arknights_story_player/story_player/fx/fx_painter.dart';
import 'package:arknights_story_player/story_player/fx/fx_simulation.dart';
import 'package:arknights_story_player/story_player/runtime/story_engine.dart';
import 'package:arknights_story_player/story_player/script.dart';

Map<String, dynamic> fixture({bool loop = true, int max = 20}) => {
  'version': 1,
  'name': 'test_fx',
  'duration': .3,
  'isLoop': loop,
  'emitters': [
    {
      'name': 'synthetic',
      'kind': 'particle',
      'duration': .3,
      'loop': loop,
      'position': [0, 0],
      'scale': [1, 1],
      'maxParticles': max,
      'material': {
        'main': 'white.png',
        'tint': [1, .5, 0, 1],
      },
      'rate': {'scalar': 100},
      'lifetime': {'scalar': .5},
      'speed': {'scalar': 1},
      'size': {'scalar': .2},
      'sizeY': {'scalar': .2},
    },
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('FxSimulation 可将循环资源覆盖为一次性播放', () {
    final simulation = FxSimulation(FxAsset.parse(fixture()), loop: false);
    for (var i = 0; i < 4; i++) {
      simulation.advance(.25);
    }
    expect(simulation.active, isFalse);
  });
  test('瞬时发射在零时刻和重复时间各触发一次，停止发射后仍推进存活粒子', () {
    final raw = fixture(loop: false);
    final spec = (raw['emitters'] as List).single as Map;
    spec['rate'] = {'scalar': 0};
    spec['bursts'] = [
      {
        'time': 0,
        'count': {'scalar': 2},
        'cycles': 2,
        'interval': .1,
        'probability': 1,
      },
    ];
    final sim = FxSimulation(FxAsset.parse(raw));
    sim.advance(.05);
    expect(sim.emitters.single.particles, hasLength(2));
    sim.advance(.1);
    expect(sim.emitters.single.particles, hasLength(4));
    sim.advance(.05);
    expect(sim.emitters.single.particles, hasLength(4));
    for (var i = 0; i < 5; i++) {
      sim.advance(.2);
    }
    expect(sim.active, isFalse);
  });

  testWidgets('同层连续 Effect 叠加且独立淡入，清层可清除全部实例', (tester) async {
    final start = tester.binding.clock.now();
    final engine = StoryEngine(
      StoryScript.parse('''
[effect(name="test_fx", layer=1, fade=true, fadetime=.2)]
[effect(name="test_fx", layer=1, fade=true, fadetime=.2)]
第一句
[effect(layer=1, fade=true, fadetime=.2, block=true)]
第二句
'''),
      effectAssets: {'test_fx': FxAsset.parse(fixture())},
      elapsed: () => tester.binding.clock.now().difference(start),
    );
    engine.start();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(engine.state.effects, hasLength(2));
    for (final effect in engine.state.effects) {
      expect(effect.alpha, greaterThan(0));
      expect(effect.alpha, lessThan(1));
    }
    engine.advance();
    engine.advance();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();
    expect(engine.state.effects, isEmpty);
    expect(engine.state.text, '第二句');
    engine.dispose();
  });
  test('seek 重建时不重播前景 Effect，并按目标时刻还原 bgeffect', () async {
    final elapsed = Stopwatch()..start();
    final engine = StoryEngine(
      StoryScript.parse('''
[effect(name="test_fx")]
[bgeffect(name="test_fx")]
第一句
[bgeffect]
第二句
'''),
      effectAssets: {'test_fx': FxAsset.parse(fixture())},
      elapsed: () => elapsed.elapsed,
    );
    addTearDown(engine.dispose);

    expect(await engine.seekToStop(engine.stopPoints.first), isTrue);
    expect(engine.state.effects.map((effect) => effect.group), ['bgeffect']);
    expect(await engine.seekToStop(engine.stopPoints.last), isTrue);
    expect(engine.state.effects, isEmpty);
  });

  test('默认随应用打包的火焰和烟雾可离线加载并解码全部贴图', () async {
    final store = AssetStore(
      client: MockClient((request) async {
        fail('打包特效不应发起网络请求：${request.url}');
      }),
    );
    addTearDown(store.close);
    final loader = FxLoader(storyFxRoot, store);
    expect(loader.root.scheme, 'asset');
    for (final name in [
      'avg_fire_01',
      'avg_048_smoke_01',
      'avg_042_fire_01',
      'avg_036_daoguang_01',
      'avg_061_glow_01',
      'avg_062_smoke_01',
      'avg_072_speech',
      'avg_079_daoguang01',
    ]) {
      final asset = await loader.load(name);
      expect(asset.name, name);
      expect(asset.emitters, isNotEmpty);
      if (name == 'avg_079_daoguang01') {
        final blades = asset.emitters.where((e) => e.geometry != null).toList();
        expect(blades, hasLength(6));
        for (final blade in blades) {
          expect(blade.material['frames']['fps'], 60);
          expect(blade.geometry!.positions, isNotEmpty);
        }
      }
      if (name == 'avg_072_speech') {
        expect(asset.drawAfterImages, isTrue);
        final ring = asset.emitters.firstWhere((e) => e.name == '2');
        final animation = ring.animation!;
        expect(animation.at(0)[12], 0);
        expect(animation.at(3)[12], greaterThan(0));
        expect(animation.at(12)[12], 0);
      }
      for (final texture in asset.textures) {
        final codec = await ui.instantiateImageCodec(
          await loader.bytes(asset.textureUri(texture)),
        );
        try {
          final image = (await codec.getNextFrame()).image;
          expect(image.width, greaterThan(0));
          expect(image.height, greaterThan(0));
          image.dispose();
        } finally {
          codec.dispose();
        }
      }
    }
  });
  test('发射器动画按时间插值并在结束后保持最后一帧', () {
    final animation = FxEmitterAnimation({
      'fps': 2,
      'frames': [List.filled(13, 0), List.filled(13, 1)],
    });
    expect(animation.at(0), everyElement(0));
    expect(animation.at(.25), everyElement(.5));
    expect(animation.at(10), everyElement(1));
    expect(
      () => FxEmitterAnimation({
        'fps': 30,
        'frames': [List.filled(12, 0)],
      }),
      throwsFormatException,
    );
  });
  test('曲线保留 Hermite 切线，随机区间以固定种子插值', () {
    final curve = FxRange.parse({
      'state': 1,
      'scalar': 2,
      'curve': [
        [0, 0, 0, 0],
        [1, 1, 0, 0],
      ],
    });
    expect(curve.at(.25), closeTo(.3125, 1e-8));
    final range = FxRange.parse({'state': 3, 'min': 2, 'scalar': 6});
    expect(range.at(0, .25), 3);
    expect(range.at(1, .25), 3);
  });

  test('发射数有上限，非循环粒子在寿命结束后退出', () {
    final sim = FxSimulation(FxAsset.parse(fixture(loop: false, max: 7)));
    sim.advance(.1);
    expect(sim.emitters.single.particles, hasLength(7));
    final y = sim.emitters.single.particles.first.position.dy;
    sim.advance(.1);
    expect(sim.emitters.single.particles.first.position.dy, greaterThan(y));
    for (var i = 0; i < 12; i++) {
      sim.advance(.1);
    }
    expect(sim.active, isFalse);
    expect(sim.emitters.single.particles, isEmpty);
  });

  test('保留导出位置并按 100 像素每单位换算粒子运动，并保留 sorting', () {
    final raw = fixture(max: 1);
    final emitter = (raw['emitters'] as List).single as Map<String, dynamic>;
    emitter
      ..['position'] = [1, 2]
      ..['sorting'] = 7;
    final asset = FxAsset.parse(raw);
    expect(asset.emitters.single.sorting, 7);
    final sim = FxSimulation(asset)..advance(.1);
    expect(sim.emitters.single.particles.single.position.dx, closeTo(1, 1e-6));
    expect(sim.emitters.single.particles.single.position.dy, greaterThan(2));
  });

  test('外部目录和变量解析拒绝目录穿越', () {
    expect(
      resolveFxName(r'$eb_burn', {'eb_burn': 'AVG_fire_01'}),
      'avg_fire_01',
    );
    expect(() => resolveFxName('../secret', {}), throwsFormatException);
    expect(FxLoader.directory(r'D:\Work\fx').toString(), 'file:///D:/Work/fx/');
    expect(
      FxLoader.directory('https://example.test/fx').toString(),
      'https://example.test/fx/',
    );
    expect(() => FxLoader.directory('relative/fx'), throwsFormatException);
    final raw = fixture();
    (raw['emitters'] as List).single['material']['main'] = '../other.png';
    expect(() => FxAsset.parse(raw), throwsFormatException);
  });

  testWidgets('背景与前景分别分层，暂停冻结，按层清除，重播清空旧实例', (tester) async {
    final start = tester.binding.clock.now();
    final asset = FxAsset.parse(fixture());
    final engine = StoryEngine(
      StoryScript.parse(r'''
[bgeffect(name="$burn", layer=1)]
[bgeffect(name="test_fx", layer=2)]
[effect(name="test_fx", layer=1)]
第一句
[bgeffect(layer=1)]
第二句
[bgeffect]
第三句
'''),
      variables: {'burn': 'test_fx'},
      effectAssets: {'test_fx': asset},
      elapsed: () => tester.binding.clock.now().difference(start),
    );
    try {
      await engine.start();
      expect(engine.state.effects, hasLength(3));
      final first = engine.state.effects.first;
      await tester.pump(const Duration(milliseconds: 100));
      expect(first.simulation.elapsed, greaterThan(0));
      await engine.setPaused(true);
      final elapsed = first.simulation.elapsed;
      await tester.pump(const Duration(milliseconds: 100));
      expect(first.simulation.elapsed, elapsed);
      await engine.setPaused(false);
      await engine.advance();
      await engine.advance();
      expect(
        engine.state.effects.where((e) => e.group == 'bgeffect').single.layer,
        2,
      );
      await engine.advance();
      await engine.advance();
      expect(engine.state.effects.single.group, 'effect');
      await engine.restart();
      expect(engine.state.effects, hasLength(3));
      expect(engine.state.effects.contains(first), isFalse);
      expect(engine.warnings, isEmpty);
    } finally {
      engine.dispose();
    }
  });

  testWidgets('阻塞淡出结束后清除，资源缺失不阻断对白', (tester) async {
    final start = tester.binding.clock.now();
    final engine = StoryEngine(
      StoryScript.parse('''
[bgeffect(name="test_fx")]
[bgeffect(fade=true, fadetime=.1, block=true)]
[bgeffect(name="missing")]
后续对白
'''),
      effectAssets: {'test_fx': FxAsset.parse(fixture())},
      elapsed: () => tester.binding.clock.now().difference(start),
    );
    try {
      final done = engine.start();
      await tester.pump();
      expect(engine.state.effects, hasLength(1));
      await tester.pump(const Duration(milliseconds: 64));
      expect(engine.state.effects.single.alpha, inExclusiveRange(0, 1));
      await tester.pump(const Duration(milliseconds: 100));
      await done;
      expect(engine.state.effects, isEmpty);
      expect(engine.state.text, '后续对白');
      expect(engine.warnings.single, contains('missing'));
    } finally {
      engine.dispose();
    }
  });

  test('贴图粒子能画出颜色、随时间移动，并服从透明度', () async {
    final r = ui.PictureRecorder();
    ui.Canvas(r).drawColor(const ui.Color(0xffffffff), ui.BlendMode.src);
    final picture = r.endRecording();
    final texture = await picture.toImage(16, 16);
    picture.dispose();
    final asset = FxAsset.parse(
      fixture(),
      base: Uri.parse('https://example.test/'),
    );
    final sim = FxSimulation(asset)..advance(.1);
    final effect = StageEffect(sim, group: 'bgeffect', layer: 0);
    Future<List<int>> pixels() async {
      final rec = ui.PictureRecorder();
      final canvas = ui.Canvas(rec);
      paintEffects(
        canvas,
        [effect],
        {asset.textureUri('white.png'): texture},
        'bgeffect',
      );
      final p = rec.endRecording();
      final image = await p.toImage(1280, 720);
      p.dispose();
      final data = (await image.toByteData())!.buffer.asUint8List().toList();
      image.dispose();
      return data;
    }

    final before = await pixels();
    expect(before.any((b) => b > 0), isTrue);
    sim.advance(.2);
    expect(await pixels(), isNot(equals(before)));
    effect.alpha = 0;
    expect((await pixels()).every((b) => b == 0), isTrue);
    texture.dispose();
  });

  test('粒子材质图集保留贴图网格并按时间切帧和调整颜色', () async {
    final raw = fixture(loop: false);
    final spec = (raw['emitters'] as List).single as Map;
    spec['rate'] = {'scalar': 0};
    spec['bursts'] = [
      {
        'time': 0,
        'count': {'scalar': 1},
      },
    ];
    spec['speed'] = {'scalar': 0};
    spec['lifetime'] = {'scalar': 1};
    spec['uv'] = {
      'enabled': true,
      'tiles': [2, 1],
      'start': {'scalar': .5},
    };
    spec['material'] = {
      'main': 'white.png',
      'tint': [.25, .5, 1, 1],
      'colorMultiplier': 2,
      'frames': {'count': 2, 'columns': 2, 'width': 8, 'height': 8, 'fps': 10},
    };
    final asset = FxAsset.parse(raw);
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    for (final (x, color) in [
      (0.0, const ui.Color(0xffff0000)),
      (4.0, const ui.Color(0x80808080)),
      (8.0, const ui.Color(0xff0000ff)),
      (12.0, const ui.Color(0xff00ff00)),
    ]) {
      canvas.drawRect(ui.Rect.fromLTWH(x, 0, 4, 8), ui.Paint()..color = color);
    }
    final picture = recorder.endRecording();
    final texture = await picture.toImage(16, 8);
    picture.dispose();
    final sim = FxSimulation(asset)..advance(.05);
    final effect = StageEffect(sim, group: 'bgeffect', layer: 0);
    Future<List<int>> center() async {
      final rec = ui.PictureRecorder();
      paintEffects(
        ui.Canvas(rec),
        [effect],
        {asset.textureUri('white.png'): texture},
        'bgeffect',
      );
      final p = rec.endRecording();
      final image = await p.toImage(1280, 720);
      final bytes = (await image.toByteData())!.buffer.asUint8List();
      final offset = (360 * 1280 + 640) * 4;
      final pixel = bytes.sublist(offset, offset + 4);
      image.dispose();
      p.dispose();
      return pixel;
    }

    expect(await center(), [64, 128, 255, 255]);
    sim.advance(.1);
    expect(await center(), [0, 255, 0, 255]);
    effect.alpha = 0;
    expect(await center(), [0, 0, 0, 0]);
    texture.dispose();
  });

  test('动画网格按图集切帧、三维投影并服从透明度', () async {
    final raw = fixture(loop: false);
    final spec = (raw['emitters'] as List).single as Map;
    spec['kind'] = 'mesh';
    spec['geometry'] = {
      'positions': [
        [-20, -20, 0],
        [20, -20, 0],
        [0, 20, 0],
      ],
      'uv': [
        [0, 0],
        [1, 0],
        [.5, 1],
      ],
      'colors': [
        [255, 255, 255, 255],
        [255, 255, 255, 255],
        [255, 255, 255, 255],
      ],
      'indices': [0, 1, 2],
    };
    spec['material'] = {
      'main': 'white.png',
      'frames': {'count': 2, 'columns': 2, 'width': 8, 'height': 8, 'fps': 10},
    };
    final asset = FxAsset.parse(raw);
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawRect(
      const ui.Rect.fromLTWH(0, 0, 8, 8),
      ui.Paint()..color = const ui.Color(0xffff0000),
    );
    canvas.drawRect(
      const ui.Rect.fromLTWH(8, 0, 8, 8),
      ui.Paint()..color = const ui.Color(0xff00ff00),
    );
    final picture = recorder.endRecording();
    final texture = await picture.toImage(16, 8);
    picture.dispose();
    final sim = FxSimulation(asset);
    final effect = StageEffect(
      sim,
      group: 'effect',
      layer: 0,
      rotation3D: const ui.Offset(.4, .6),
    );
    Future<List<int>> center() async {
      final rec = ui.PictureRecorder();
      paintEffects(
        ui.Canvas(rec),
        [effect],
        {asset.textureUri('white.png'): texture},
        'effect',
      );
      final p = rec.endRecording();
      final image = await p.toImage(1280, 720);
      final bytes = (await image.toByteData())!.buffer.asUint8List();
      final pixel = bytes.sublist(
        (360 * 1280 + 640) * 4,
        (360 * 1280 + 640) * 4 + 4,
      );
      image.dispose();
      p.dispose();
      return pixel;
    }

    expect(await center(), [255, 0, 0, 255]);
    sim.advance(.15);
    expect(await center(), [0, 255, 0, 255]);
    effect.alpha = 0;
    expect(await center(), [0, 0, 0, 0]);
    texture.dispose();
    (spec['geometry'] as Map)['indices'] = [0, 1, 99];
    expect(() => FxAsset.parse(raw), throwsFormatException);
  });

  test('HTTP 特效描述通过 AssetStore 加载', () async {
    final requested = <Uri>[];
    final store = AssetStore(
      client: MockClient((request) async {
        requested.add(request.url);
        return http.Response(
          jsonEncode(fixture()),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    addTearDown(store.close);
    final asset = await FxLoader(
      'https://example.test/fx',
      store,
    ).load('test_fx');
    expect(requested.single.path, '/fx/test_fx/fx.json');
    expect(asset.textureUri('white.png').path, '/fx/test_fx/white.png');
  });
}
