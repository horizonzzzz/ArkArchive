import 'dart:convert';
import 'dart:typed_data';

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
  test('三维发射投影保留局部 Z 运动、落尘反射和横向风沙', () {
    for (final basis in [
      [
        [1, 0],
        [0, 0],
        [0, -1],
      ],
      [
        [0, 0],
        [0, 1],
        [-1, 0],
      ],
      [
        [1, 0],
        [0, -1],
        [0, 0],
      ],
    ]) {
      final raw = fixture(loop: false);
      final emitter = (raw['emitters'] as List).single as Map<String, dynamic>;
      emitter['emissionBasis'] = basis;
      emitter['shape'] = {
        'scale': [1, 1, 1],
      };
      emitter['speed'] = {'scalar': 0};
      emitter['velocity'] = {
        'enabled': true,
        'y': {'scalar': 1},
        'z': {'scalar': 2},
      };
      final simulation = FxSimulation(FxAsset.parse(raw))..advance(.05);
      final velocity = simulation.emitters.single.particles.first.velocity;
      expect(velocity.dx, basis[1][0] * 100 + basis[2][0] * 200);
      expect(velocity.dy, basis[1][1] * 100 + basis[2][1] * 200);
    }
  });

  test('三维发射投影拒绝非数值轴和缺失的形状维度', () {
    for (final malformedBasis in [
      [
        [1, 0],
        [0, 'bad'],
        [0, -1],
      ],
      [
        [1, 0],
        [0, 1],
      ],
    ]) {
      final raw = fixture();
      final emitter = (raw['emitters'] as List).single as Map;
      emitter['emissionBasis'] = malformedBasis;
      emitter['shape'] = {
        'scale': [1, 1, 1],
      };
      expect(() => FxAsset.parse(raw), throwsFormatException);
    }
    final raw = fixture();
    final emitter = (raw['emitters'] as List).single as Map;
    emitter['emissionBasis'] = [
      [1, 0],
      [0, 0],
      [0, -1],
    ];
    emitter['shape'] = {
      'scale': [1, 1],
    };
    expect(() => FxAsset.parse(raw), throwsFormatException);
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

  test('拉伸粒子方向跟随噪声扰动后的运动速度', () {
    final raw = fixture(loop: false);
    final emitter = (raw['emitters'] as List).single as Map<String, dynamic>;
    emitter['rate'] = {'scalar': 0};
    emitter['bursts'] = [
      {
        'time': 0,
        'count': {'scalar': 1},
      },
    ];
    emitter['noise'] = {
      'state': 1,
      'scalar': 1,
      'curve': [
        [0, 1],
        [1, 1],
      ],
    };

    final simulation = FxSimulation(FxAsset.parse(raw), seed: 1)..advance(.05);
    final particle = simulation.emitters.single.particles.single;
    final cross =
        (particle.direction.dx * particle.velocity.dy -
                particle.direction.dy * particle.velocity.dx)
            .abs();

    expect(cross, greaterThan(.01));
  });

  testWidgets('bgeffect 将 flip 轴标志传给演出实例', (tester) async {
    final engine = StoryEngine(
      StoryScript.parse('[bgeffect(name="test_fx", flip=2, layer=1)]\n正文'),
      effectAssets: {'test_fx': FxAsset.parse(fixture())},
    );
    engine.start();
    await tester.pump();
    expect(engine.state.effects.single.flip, 2);
    engine.dispose();
  });

  testWidgets('bgeffect 同层切换到缺失或非法资源时清除旧特效', (tester) async {
    final engine = StoryEngine(
      StoryScript.parse('''
[bgeffect(name="test_fx", layer=1)]
[bgeffect(name="missing_fx", layer=1)]
[bgeffect(name="../invalid", layer=1)]
正文
'''),
      effectAssets: {'test_fx': FxAsset.parse(fixture())},
    );
    engine.start();
    await tester.pump();
    expect(engine.state.effects, isEmpty);
    engine.dispose();
  });

  testWidgets('三维特效仅按旋转投影一次，不额外用余弦压扁', (tester) async {
    final raw = fixture();
    ((raw['emitters'] as List).single as Map)['transform3D'] = [
      [0, 0, 0],
      [1, 0, 0],
      [0, 1, 0],
    ];
    final engine = StoryEngine(
      StoryScript.parse('[effect(name="test_fx", rox=90, roy=90)]\n正文'),
      effectAssets: {'test_fx': FxAsset.parse(raw)},
    );
    engine.start();
    await tester.pump();
    expect(engine.state.effects.single.scale, const ui.Offset(1, 1));
    engine.dispose();
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
    expect(resolveFxName(r'$TEST_FX', {'test_fx': 'TEST_FX'}), 'test_fx');
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
  testWidgets('bgeffect 空图层参数清除全部持续特效', (tester) async {
    final engine = StoryEngine(
      StoryScript.parse('''
[bgeffect(name="test_fx", layer=1)]
[bgeffect(name="test_fx", layer=2)]
[bgeffect(layer="")]
[name="甲"]完成
'''),
      effectAssets: {'test_fx': FxAsset.parse(fixture())},
    );
    // addTearDown 晚于 testWidgets 的 pending timer 校验，
    // 引擎的 16ms 周期 ticker 必须在测试体内 dispose（同文件其他用例）。
    await engine.start();
    expect(engine.state.effects, isEmpty);
    expect(engine.state.text, '完成');
    engine.dispose();
  });
  testWidgets('特效 delay 错开粒子启动并允许清除待启动实例', (tester) async {
    final start = tester.binding.clock.now();
    final engine = StoryEngine(
      StoryScript.parse('''
[effect(name="test_fx", layer=1, delay=.01)]
[effect(name="test_fx", layer=2, delay=.1)]
[effect(name="test_fx", layer=3, delay=.25)]
第一句
[effect(layer=3)]
第二句
'''),
      effectAssets: {'test_fx': FxAsset.parse(fixture())},
      elapsed: () => tester.binding.clock.now().difference(start),
    );
    try {
      await engine.start();
      expect(engine.state.text, '第一句');
      final effects = {
        for (final effect in engine.state.effects) effect.layer: effect,
      };
      expect(effects, hasLength(3));

      await tester.pump(const Duration(milliseconds: 64));
      expect(effects[1]!.simulation.elapsed, greaterThan(0));
      expect(effects[2]!.simulation.elapsed, 0);
      expect(effects[3]!.simulation.elapsed, 0);

      await tester.pump(const Duration(milliseconds: 80));
      expect(effects[2]!.simulation.elapsed, greaterThan(0));
      expect(effects[3]!.simulation.elapsed, 0);

      await engine.advance();
      expect(engine.state.text, '第二句');
      expect(
        engine.state.effects.map((effect) => effect.layer),
        containsAll([1, 2]),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(engine.state.effects.any((effect) => effect.layer == 3), isFalse);
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
      'frames': <String, dynamic>{
        'count': 2,
        'columns': 2,
        'width': 8,
        'height': 8,
        'fps': 10,
      },
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
    (asset.emitters.single.material['frames'] as Map)['loop'] = true;
    sim.advance(.1);
    expect(await center(), [64, 128, 255, 255]);
    (asset.emitters.single.material['frames'] as Map)['loop'] = false;
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
    Future<List<int>> center([
      StageEffect? selected,
      int x = 640,
      bool foreground = false,
    ]) async {
      final rec = ui.PictureRecorder();
      paintEffects(
        ui.Canvas(rec),
        [selected ?? effect],
        {
          (selected ?? effect).simulation.asset.textureUri('white.png'):
              texture,
        },
        'effect',
        afterBlocker: foreground,
      );
      final p = rec.endRecording();
      final image = await p.toImage(1280, 720);
      final bytes = (await image.toByteData())!.buffer.asUint8List();
      final pixel = bytes.sublist(
        (360 * 1280 + x) * 4,
        (360 * 1280 + x) * 4 + 4,
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
    raw['drawAfterBlocker'] = true;
    spec['animation'] = {
      'fps': 10,
      'frames': [
        [0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 1, 1, 1, 1],
        [100, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 1, 1, 1, .5],
      ],
    };
    final animated = StageEffect(
      FxSimulation(FxAsset.parse(raw)),
      group: 'effect',
      layer: 1,
    );
    expect(await center(animated), [0, 0, 0, 0]);
    expect(await center(animated, 640, true), [255, 0, 0, 255]);
    animated.simulation.advance(.15);
    expect(await center(animated, 640, true), [0, 0, 0, 0]);
    final moved = await center(animated, 740, true);
    expect(moved[1], closeTo(128, 1));
    expect(moved[3], closeTo(128, 1));
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
  test('打包资源可从通用分类目录加载合成特效', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final requested = <String>[];
    messenger.setMockMessageHandler('flutter/assets', (message) async {
      final key = utf8.decode(message!.buffer.asUint8List());
      requested.add(key);
      if (key != 'assets/fx-runtime/baked/test_fx/fx.json') return null;
      return ByteData.sublistView(
        Uint8List.fromList(utf8.encode(jsonEncode(fixture()))),
      );
    });
    addTearDown(() => messenger.setMockMessageHandler('flutter/assets', null));
    final store = AssetStore();
    addTearDown(store.close);

    final asset = await FxLoader(
      'asset:///assets/fx-runtime/',
      store,
    ).load('test_fx');

    expect(asset.name, 'test_fx');
    expect(requested, [
      'assets/fx-runtime/particle/test_fx/fx.json',
      'assets/fx-runtime/baked/test_fx/fx.json',
    ]);
  });
  test('五组雪效资源可从打包目录加载，停用的窗口雪幕不生成粒子', () async {
    final store = AssetStore();
    addTearDown(store.close);
    final loader = FxLoader('asset:///assets/fx-runtime/', store);
    const names = [
      'avg_snowstorm_01',
      'avg_snow_02',
      'avg_058_snow_01',
      'avg_snow_01',
      'avg_072_snow',
    ];
    for (final name in names) {
      final asset = await loader.load(name);
      expect(asset.emitters, isNotEmpty, reason: name);
      if (name == 'avg_snow_02') {
        expect(asset.emitters.map((emitter) => emitter.name), [
          'xuehua',
          'chenai',
        ]);
      }
      for (final emitter in asset.emitters) {
        final tint = emitter.material['tint'] as List;
        expect(
          tint.take(3),
          everyElement(1.0),
          reason: '$name/${emitter.name}',
        );
      }
      for (final texture in asset.textures) {
        final codec = await ui.instantiateImageCodec(
          await loader.bytes(asset.textureUri(texture)),
        );
        final frame = await codec.getNextFrame();
        expect(frame.image.width, greaterThan(0), reason: '$name/$texture');
        frame.image.dispose();
        codec.dispose();
      }
    }

    final lightsnow = await loader.load('avg_snow_02');
    final lightSimulation = FxSimulation(lightsnow, seed: 17);
    final lightYs =
        lightSimulation.emitters.first.particles
            .map((particle) => particle.position.dy)
            .toList()
          ..sort();
    expect(lightYs.last - lightYs.first, greaterThan(500));

    final snowpowder = await loader.load('avg_058_snow_01');
    final powderSimulation = FxSimulation(snowpowder, seed: 17);
    powderSimulation.advance(1);
    final powderXs =
        powderSimulation.emitters
            .expand((emitter) => emitter.particles)
            .map((particle) => particle.position.dx)
            .toList()
          ..sort();
    expect(powderXs.last - powderXs.first, greaterThan(800));
    final snow = await loader.load('avg_snow_01');
    expect(
      snow.emitters.where(
        (emitter) => emitter.mesh && emitter.geometry == null,
      ),
      isEmpty,
    );

    final simulation = FxSimulation(await loader.load('avg_072_snow'));
    simulation.advance(.05);
    expect(simulation.emitters.single.particles, isEmpty);
    expect(simulation.active, isFalse);
  });

  test('P2 七种第一人称视效资源均可离线加载', () async {
    final store = AssetStore();
    addTearDown(store.close);
    final loader = FxLoader('asset:///assets/fx-runtime/', store);
    const expected = {
      'avg_signalinterference_01': '',
      'avg_056_tvnoise_01': '',
      'avg_mohu_zhengyan_01': 'open',
      'avg_mohu_biyan_01': 'close',
      'avg_suduxian': '',
      'avg_062_white_01': '',
      'avg_062_black_01': '',
    };
    for (final entry in expected.entries) {
      final asset = await loader.load(entry.key);
      expect(asset.name, entry.key);
      expect(asset.screenEffect['direction'] ?? '', entry.value);
      for (final texture in asset.textures) {
        expect(await loader.bytes(asset.textureUri(texture)), isNotEmpty);
      }
    }
  });

  test('屏幕遮罩拒绝缺失或无效的 RGBA', () {
    for (final config in [
      {'type': 'overlay'},
      {
        'type': 'overlay',
        'tint': [0, 0, 0, 1.1],
      },
    ]) {
      expect(
        () => FxAsset.parse({...fixture(), 'screenEffect': config}),
        throwsFormatException,
      );
    }
  });

  test('三维圆锥 90 度外圈发射沿 360 度径向扩散，并保留旧二维圆锥兼容', () {
    final raw3d = fixture(loop: false, max: 120);
    final e3d = (raw3d['emitters'] as List).single as Map<String, dynamic>;
    e3d
      ..['emissionBasis'] = [
        [1, 0],
        [0, 1],
        [0, 0],
      ]
      ..['rate'] = {'scalar': 0}
      ..['bursts'] = [
        {
          'time': 0,
          'count': {'scalar': 80},
        },
      ]
      ..['speed'] = {'scalar': 10}
      ..['shape'] = {
        'enabled': true,
        'type': 4,
        'radius': 3.0,
        'thickness': 0.0,
        'angle': 90.0,
        'scale': [1, 1, 1],
      };
    final sim3d = FxSimulation(FxAsset.parse(raw3d), seed: 7)..advance(.05);
    final particles = sim3d.emitters.single.particles;
    expect(particles, hasLength(80));
    expect(particles.any((p) => p.direction.dx > .7), isTrue);
    expect(particles.any((p) => p.direction.dx < -.7), isTrue);
    expect(particles.any((p) => p.direction.dy > .7), isTrue);
    expect(particles.any((p) => p.direction.dy < -.7), isTrue);
    for (final p in particles) {
      // 位置应沿径向位于初始半径 300px 外侧。
      expect(p.position.distance, greaterThan(310));
      final dot =
          (p.position.dx * p.direction.dx + p.position.dy * p.direction.dy) /
          p.position.distance;
      expect(dot, closeTo(1.0, 1e-4));
    }

    // 无 emissionBasis 的旧配置继续保持向上扇形发射，不破坏历史资源。
    final raw2d = fixture(loop: false, max: 40);
    final e2d = (raw2d['emitters'] as List).single as Map<String, dynamic>;
    e2d
      ..['rate'] = {'scalar': 0}
      ..['bursts'] = [
        {
          'time': 0,
          'count': {'scalar': 20},
        },
      ]
      ..['shape'] = {
        'enabled': true,
        'type': 4,
        'radius': 1.0,
        'thickness': 0.0,
        'angle': 30.0,
        'scale': [1, 1],
      };
    final sim2d = FxSimulation(FxAsset.parse(raw2d), seed: 7)..advance(.02);
    expect(
      sim2d.emitters.single.particles.every((p) => p.direction.dy > .9),
      isTrue,
    );
  });

  test('limitVelocity 按阻尼衰减超限速度并校验非法阻尼参数', () {
    final raw = fixture(loop: false, max: 1);
    final emitter = (raw['emitters'] as List).single as Map<String, dynamic>;
    emitter
      ..['rate'] = {'scalar': 0}
      ..['bursts'] = [
        {
          'time': 0,
          'count': {'scalar': 1},
        },
      ]
      ..['lifetime'] = {'scalar': 1}
      ..['speed'] = {'scalar': 30}
      ..['limitVelocity'] = {
        'magnitude': {'scalar': 4},
        'dampen': .2,
      };
    final sim = FxSimulation(FxAsset.parse(raw), seed: 3)..advance(.02);
    final initialSpeed = sim.emitters.single.particles.single.velocity.distance;
    sim.advance(.3);
    final dampedSpeed = sim.emitters.single.particles.single.velocity.distance;
    expect(initialSpeed, greaterThan(1500));
    expect(dampedSpeed, lessThan(500));
    expect(dampedSpeed, greaterThanOrEqualTo(399));

    emitter['limitVelocity'] = {
      'magnitude': {'scalar': 4},
      'dampen': 1.5,
    };
    expect(() => FxAsset.parse(raw), throwsFormatException);
  });

  test('stretchAlignU 沿运动方向拉伸贴图 U 轴并区分正负 lengthScale 与 pivot', () async {
    // 构造左半红、右半蓝的 16×16 贴图，以像素颜色检验 U 轴方向与拉伸轴。
    final rec = ui.PictureRecorder();
    final c = ui.Canvas(rec);
    c.drawRect(
      const ui.Rect.fromLTWH(0, 0, 8, 16),
      ui.Paint()..color = const ui.Color(0xffff0000),
    );
    c.drawRect(
      const ui.Rect.fromLTWH(8, 0, 8, 16),
      ui.Paint()..color = const ui.Color(0xff0000ff),
    );
    final pic = rec.endRecording();
    final tex = await pic.toImage(16, 16);
    pic.dispose();
    addTearDown(tex.dispose);

    Future<List<int>> samplePixel(
      double lengthScale,
      double pivotY,
      int x,
      int y,
    ) async {
      final raw = fixture(loop: false, max: 1);
      final emitter = (raw['emitters'] as List).single as Map<String, dynamic>;
      emitter
        ..['rate'] = {'scalar': 0}
        ..['bursts'] = [
          {
            'time': 0,
            'count': {'scalar': 1},
          },
        ]
        ..['speed'] = {'scalar': 0}
        ..['velocity'] = {
          'enabled': true,
          'x': {'scalar': 1},
          'y': {'scalar': 0},
        }
        ..['size'] = {'scalar': .2}
        ..['sizeY'] = {'scalar': .2}
        ..['material'] = {'main': 'white.png', 'tint': [1, 1, 1, 1]}
        ..['stretch'] = true
        ..['stretchAlignU'] = true
        ..['lengthScale'] = lengthScale
        ..['pivot'] = [0.0, pivotY];
      final asset = FxAsset.parse(raw);
      final sim = FxSimulation(asset, seed: 1)..advance(.01);
      // 将粒子放回中心，仅检验朝 +X 速度下的拉伸朝向和长度。
      sim.emitters.single.particles.single.position = ui.Offset.zero;
      final effect = StageEffect(sim, group: 'bgeffect', layer: 0);
      final prec = ui.PictureRecorder();
      paintEffects(
        ui.Canvas(prec),
        [effect],
        {asset.textureUri('white.png'): tex},
        'bgeffect',
      );
      final p = prec.endRecording();
      final img = await p.toImage(1280, 720);
      final bytes = (await img.toByteData())!.buffer.asUint8List();
      final offset = (y * 1280 + x) * 4;
      final px = bytes.sublist(offset, offset + 4);
      img.dispose();
      p.dispose();
      return px;
    }

    // 速度沿 +X，size=20，lengthScale=6 => 宽 120、高 20，U=0 朝右(+X 速度头)为红，U=1 朝左(-X 拖尾)为蓝。
    expect(await samplePixel(6, 0, 680, 360), [255, 0, 0, 255]);
    expect(await samplePixel(6, 0, 600, 360), [0, 0, 255, 255]);
    // 垂直方向超过 thickness/2=10 应透明，证明确实沿 X 轴而非 Y 轴拉伸。
    expect(await samplePixel(6, 0, 640, 330), [0, 0, 0, 0]);

    // 负 lengthScale=-6 且 pivotY=0.25：U=0 朝左(红)，U=1 朝右(蓝)，中心向右偏移 +30px。
    expect(await samplePixel(-6, 0.25, 710, 360), [0, 0, 255, 255]);
    expect(await samplePixel(-6, 0.25, 630, 360), [255, 0, 0, 255]);
  });

  test('avg_suduxian 打包资源以叠加混合与径向拉伸正确模拟双层速度线', () async {
    final store = AssetStore();
    addTearDown(store.close);
    final loader = FxLoader('asset:///assets/fx-runtime/', store);
    final asset = await loader.load('avg_suduxian');
    expect(asset.emitters.map((e) => e.name), ['lizisha3_dm', 'lizisha_dm']);
    for (final emitter in asset.emitters) {
      expect(emitter.additive, isTrue, reason: emitter.name);
      expect(emitter.stretch, isTrue, reason: emitter.name);
      expect(emitter.stretchAlignU, isTrue, reason: emitter.name);
      expect(emitter.emissionBasis, isNotNull, reason: emitter.name);
    }
    expect(asset.emitters[0].limitVelocity, isNull);
    expect(asset.emitters[1].limitVelocity, isNotNull);
    expect(asset.emitters[1].limitVelocity!.dampen, closeTo(.2, 1e-4));

    final sim = FxSimulation(asset, seed: 42);
    for (var i = 0; i < 45; i++) {
      sim.advance(1 / 30);
    }
    final allParticles = [
      for (final e in sim.emitters) ...e.particles,
    ];
    expect(allParticles.length, greaterThan(25));
    // 粒子从圆环半径 330px 向 360° 外侧扩散，四个象限均有覆盖且中心留空。
    expect(allParticles.any((p) => p.position.dx > 250 && p.position.dy > 50), isTrue);
    expect(allParticles.any((p) => p.position.dx < -250 && p.position.dy > 50), isTrue);
    expect(allParticles.any((p) => p.position.dx > 250 && p.position.dy < -50), isTrue);
    expect(allParticles.any((p) => p.position.dx < -250 && p.position.dy < -50), isTrue);
    for (final e in sim.emitters) {
      for (final p in e.particles) {
        expect((p.position - e.spec.position).distance, greaterThan(320));
      }
    }
  });
}
