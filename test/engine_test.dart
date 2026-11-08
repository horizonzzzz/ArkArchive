import 'package:flutter_test/flutter_test.dart';
import 'package:arknights_story_player/story_player/script.dart';
import 'package:arknights_story_player/story_player/runtime/story_engine.dart';

void main() {
  test('播放设置作用于手动和普通自动速度', () {
    final engine = StoryEngine(
      StoryScript.parse('对白'),
      typingInterval: const Duration(milliseconds: 60),
      autoWaitSeconds: 3,
    );
    addTearDown(engine.dispose);
    expect(engine.currentSpeed.typingMs, 60);
    engine.setAutoMode('button_auto');
    expect(engine.currentSpeed.typingMs, 60);
    expect(engine.currentSpeed.autoWaitBase, 3);
    expect(engine.currentSpeed.autoWaitPerChar, 0);
    engine.setSpeedLevel(1);
    expect(engine.currentSpeed.typingMs, 15);
    expect(engine.currentSpeed.autoWaitBase, 1);
  });

  testWidgets('通讯窗口波形绑定当前发言角色并随暂停冻结', (tester) async {
    final initial = tester.binding.clock.now();
    final engine = StoryEngine(
      StoryScript.parse('''
[interlude(maskid="group_interclude_square_common", channel=3, char="伯塔尼")]
[interlude(channel=3, type=3, name="portrait")]
[name="伯塔尼"]报告正在推进
[name="其他角色"]收到
'''),
      elapsed: () => tester.binding.clock.now().difference(initial),
    );
    try {
      await engine.start();
      final frame = engine.state.interludes['3']!;
      expect(frame.voiceActive, isTrue);
      await tester.pump(const Duration(milliseconds: 64));
      expect(frame.voicePhase, greaterThan(0));
      await engine.setPaused(true);
      final pausedPhase = frame.voicePhase;
      await tester.pump(const Duration(milliseconds: 64));
      expect(frame.voicePhase, pausedPhase);
      await engine.setPaused(false);
      await engine.advance();
      await engine.advance();
      expect(engine.state.speaker, '其他角色');
      expect(frame.voiceActive, isFalse);
    } finally {
      engine.dispose();
    }
  });

  testWidgets('通讯窗口在角色切换时保持可见直到显式关闭', (tester) async {
    final engine = StoryEngine(
      StoryScript.parse('''
[interlude(maskid="group_interclude_square_common", channel=4, char="Raidian")]
[interlude(channel=4, type=3, name="portrait")]
[name="Raidian"]保持通讯
[interlude(channel=4, switch=false)]
[name="阿洛伊泽"]我还在通话
[interlude(channel=4, clear=true, tsduration=0)]
[name="阿洛伊泽"]通讯已关闭
'''),
    );
    try {
      await engine.start();
      final frame = engine.state.interludes['4']!;
      await engine.advance();
      await engine.advance();
      expect(engine.state.speaker, '阿洛伊泽');
      expect(frame.visible, isTrue);
      expect(engine.state.interludes['4'], same(frame));
      await engine.advance();
      await engine.advance();
      await tester.pump();
      expect(engine.state.speaker, '阿洛伊泽');
      expect(engine.state.interludes, isNot(contains('4')));
    } finally {
      engine.dispose();
    }
  });
  testWidgets('自动播放在逐字完成后等待配置时长', (tester) async {
    final initial = tester.binding.clock.now();
    final engine = StoryEngine(
      StoryScript.parse('[name="甲"]甲乙\n[name="甲"]第二句'),
      typingInterval: const Duration(milliseconds: 80),
      autoWaitSeconds: 2,
      elapsed: () => tester.binding.clock.now().difference(initial),
    );
    try {
      await engine.start();
      engine.setAutoMode('button_auto');
      await tester.pump(const Duration(milliseconds: 80));
      expect(engine.state.revealed, 1);
      await tester.pump(const Duration(milliseconds: 96));
      expect(engine.state.revealed, 2);
      await tester.pump(const Duration(milliseconds: 1900));
      expect(engine.state.text, '甲乙');
      await tester.pump(const Duration(milliseconds: 200));
      expect(engine.state.text, '第二句');
    } finally {
      engine.dispose();
    }
  });
  testWidgets('阻塞遮罩先完成；非阻塞背景动画与对白并行', (tester) async {
    final initial = tester.binding.clock.now();
    final engine = StoryEngine(
      StoryScript.parse('''
[Blocker(a=1, fadetime=0.1, block=true)]
[Background(image="snow", fadetime=1, block=false)]
[name="甲"]测试
'''),
      elapsed: () => tester.binding.clock.now().difference(initial),
    );
    try {
      final running = engine.start();
      await tester.pump(const Duration(milliseconds: 50));
      expect(engine.state.text, isEmpty);
      expect(engine.state.blockerAlpha, closeTo(.48, .001));
      await tester.pump(const Duration(milliseconds: 70));
      await running;
      expect(engine.state.text, '测试');
      expect(engine.state.blockerAlpha, 1);
      expect(engine.state.backgrounds.single.alpha, lessThan(1));
      await tester.pump(const Duration(milliseconds: 500));
      expect(engine.state.backgrounds.single.alpha, closeTo(.5, .03));
    } finally {
      engine.dispose();
    }
  });

  testWidgets('暂停冻结动画，重播取消旧的等待，不会串到新剧情', (tester) async {
    final initial = tester.binding.clock.now();
    final engine = StoryEngine(
      StoryScript.parse('[Delay(time=1)]\n[name="甲"]结束'),
      elapsed: () => tester.binding.clock.now().difference(initial),
    );
    try {
      final original = engine.start();
      await tester.pump(const Duration(milliseconds: 200));
      await engine.setPaused(true);
      await tester.pump(const Duration(seconds: 2));
      expect(engine.state.text, isEmpty);
      await engine.setPaused(false);
      final replay = engine.restart();
      await tester.pump();
      await original;
      expect(engine.state.history, isEmpty);
      await tester.pump(const Duration(milliseconds: 1100));
      await replay;
      expect(engine.state.history, hasLength(1));
      expect(engine.state.text, '结束');
    } finally {
      engine.dispose();
    }
  });

  test('分支只执行所选值，空 Predicate 恢复公共剧情', () async {
    final engine = StoryEngine(
      StoryScript.parse('''
[Decision(options="左;右",values="1;2")]
[Predicate(references="1")]
[name="甲"]左边
[Predicate(references="2")]
[name="乙"]右边
[Predicate]
共同结尾
'''),
      typingInterval: Duration.zero,
    );
    addTearDown(engine.dispose);
    await engine.start();
    expect(engine.state.choices, hasLength(2));
    await engine.choose('2');
    expect(engine.state.text, '右边');
    await engine.advance();
    await engine.advance();
    expect(engine.state.text, '共同结尾');
    expect(engine.state.history.any((l) => l.text == '左边'), isFalse);
  });

  test('可注册扩展处理器，未知指令诊断后继续', () async {
    final engine = StoryEngine(
      StoryScript.parse('[NewEffect]\n[Extension]\n旁白'),
    );
    addTearDown(engine.dispose);
    var called = false;
    engine.register('extension', (_) async {
      called = true;
    });
    await engine.start();
    expect(called, isTrue);
    expect(engine.state.text, '旁白');
    expect(engine.warnings.single, contains('neweffect'));
  });

  testWidgets('旧版 Character 与新式 charslot 共享槽位和焦点', (tester) async {
    final engine = StoryEngine(
      StoryScript.parse('''
[Character(name="a",name2="b",focus=1,fadetime=0)]
[name="甲"]对话
[charslot(slot="right", focus="n")]
旁白
'''),
    );
    try {
      await engine.start();
      expect(engine.state.characters.map((c) => c.slot), ['l', 'r']);
      expect(engine.state.characters.last.brightness, .5);
      await engine.advance();
      await engine.advance();
      expect(engine.state.characters.every((c) => c.brightness == .5), isTrue);
      expect(engine.state.speaker, isEmpty);
    } finally {
      engine.dispose();
    }
  });
  test('停顿点可索引，并在 seek 时重建默认分支状态', () async {
    final engine = StoryEngine(
      StoryScript.parse('''
[name="甲"]第一句
[Decision(options="左;&禁用;右",values="1;2;3")]
[Predicate(references="1")]
[name="乙"]左分支
[Predicate(references="3")]
[name="丙"]右分支
[Predicate]
[name="丁"]结尾
'''),
      typingInterval: Duration.zero,
    );
    addTearDown(engine.dispose);

    expect(engine.stopPoints.map((point) => point.kind), [
      'dialogue',
      'choice',
      'dialogue',
      'dialogue',
      'dialogue',
    ]);
    expect(engine.progress, 0);

    final reached = await engine.seekToStop(engine.stopPoints.last);

    expect(reached, isTrue);
    expect(engine.state.text, '结尾');
    expect(engine.state.history.map((line) => line.text), ['第一句', '左分支', '结尾']);
    expect(engine.state.choices, isEmpty);
    expect(engine.progress, closeTo(1, 1 / 8));
  });
  test('停顿点预扫描会随剧情推进更新背景与立绘', () {
    final engine = StoryEngine(
      StoryScript.parse('''
[Background(image="room_a")]
[Character(name="char_a")]
[name="甲"]第一句
[Background(image="room_b")]
[Character(name="char_b")]
[name="乙"]第二句
'''),
      typingInterval: Duration.zero,
    );
    addTearDown(engine.dispose);

    final points = engine.stopPoints;
    expect(points.map((point) => point.background), ['room_a', 'room_b']);
    expect(points.first.characters.single.name, 'char_a');
    expect(points.last.characters.single.name, 'char_b');
  });

  test('A1 回归：BackgroundTween 不清空缩影背景', () {
    final engine = StoryEngine(
      StoryScript.parse('''
[Background(image="room_a", screenadapt="showall")]
[name="甲"]第一句
[BackgroundTween(duration=1)]
[name="乙"]第二句
'''),
      typingInterval: Duration.zero,
    );
    addTearDown(engine.dispose);

    final points = engine.stopPoints;
    expect(points, hasLength(2));
    expect(points.last.background, 'room_a');
    expect(points.last.backgroundFit, 'showall');
  });

  test('A2 回归：default 模式可 seek 到 endtip 停顿点', () async {
    final engine = StoryEngine(
      StoryScript.parse('[name="甲"]正文\n[endtip]尾句'),
      typingInterval: Duration.zero,
    );
    addTearDown(engine.dispose);
    expect(engine.autoMode, 'default');

    final endtipPoint = engine.stopPoints.last;
    expect(endtipPoint.text, '尾句');
    expect(await engine.seekToStop(endtipPoint), isTrue);
    expect(engine.state.text, '尾句');
    expect(engine.state.dialogueVisible, isTrue);
  });

  test('A3 回归：seek 穿过 warp 回环时中止并返回 false', () async {
    final engine = StoryEngine(
      StoryScript.parse('''
[label(name="loop")]
[name="甲"]第一句
[warp(name="loop")]
[name="乙"]结束
'''),
      typingInterval: Duration.zero,
    );
    addTearDown(engine.dispose);

    final target = engine.stopPoints.last;
    expect(target.text, '结束');
    // 回跳型 warp 会让重放永不收敛；步数上限兜底，不挂死、如实失败。
    expect(await engine.seekToStop(target), isFalse);
  });

  test('seek 可回退到已读停顿点并重建历史', () async {
    final engine = StoryEngine(
      StoryScript.parse('[name="甲"]第一句\n[name="乙"]第二句\n[name="丙"]第三句'),
      typingInterval: Duration.zero,
    );
    addTearDown(engine.dispose);

    expect(await engine.seekToStop(engine.stopPoints.last), isTrue);
    expect(engine.state.text, '第三句');
    expect(await engine.seekToStop(engine.stopPoints.first), isTrue);
    expect(engine.state.text, '第一句');
    expect(engine.state.history.map((line) => line.text), ['第一句']);
    expect(engine.progress, closeTo(1 / 3, .01));
  });

  test('seek 后生成的断点可保存并沿 trace 往返恢复', () async {
    final script = StoryScript.parse(
      '[name="甲"]第一句\n[Decision(options="右;左",values="2;1")]\n[Predicate(references="2")]\n[name="乙"]右边\n[Predicate]\n[name="丙"]结尾',
    );
    final engine = StoryEngine(script, typingInterval: Duration.zero);
    final restored = StoryEngine(script, typingInterval: Duration.zero);
    addTearDown(engine.dispose);
    addTearDown(restored.dispose);

    expect(await engine.seekToStop(engine.stopPoints.last), isTrue);
    expect(engine.state.text, '结尾');
    final checkpoint = engine.checkpoint;
    expect(checkpoint, isNotNull);

    await restored.restore(checkpoint!);
    expect(restored.state.text, '结尾');
    expect(restored.state.history.map((line) => line.text), [
      '第一句',
      '右边',
      '结尾',
    ]);
  });

  test('重放路径上的全禁用 decision 使 seek 失败返回 false', () async {
    final engine = StoryEngine(
      StoryScript.parse('''
[name="甲"]第一句
[Decision(options="&锁甲;锁乙",values="1;2")]
[Predicate(references="1")]
[name="乙"]第二句
'''),
      typingInterval: Duration.zero,
    );
    addTearDown(engine.dispose);

    final target = engine.stopPoints.last;
    expect(target.text, '第二句');
    // 目标在 decision 之后，重放路径上没有可选分支，如实失败。
    expect(await engine.seekToStop(target), isFalse);
  });

  test('multiline 停顿点可 seek 并重放到首段', () async {
    final engine = StoryEngine(
      StoryScript.parse('''
[name="甲"]引导句
[multiline(name="甲")]多行第一段
[multiline(name="甲", end=true)]多行第二段
[name="甲"]收尾句
'''),
      typingInterval: Duration.zero,
    );
    addTearDown(engine.dispose);

    final multilinePoint = engine.stopPoints.firstWhere(
      (p) => p.kind == 'multiline',
    );
    expect(multilinePoint.text, '多行第一段');
    expect(await engine.seekToStop(multilinePoint), isTrue);
    expect(engine.state.text, '多行第一段');
    expect(engine.state.dialogueVisible, isTrue);
  });

  test('摘要记录黑幕标记、focus 压暗与序号', () {
    final engine = StoryEngine(
      StoryScript.parse('''
[Blocker(a=1)]
[name="甲"]黑幕中
[Blocker(a=0)]
[Character(name="a",name2="b",focus=1,fadetime=0)]
[name="乙"]聚光句
'''),
      typingInterval: Duration.zero,
    );
    addTearDown(engine.dispose);

    final points = engine.stopPoints;
    expect(points, hasLength(2));
    expect(points.first.blockerDark, isTrue);
    expect(points.last.blockerDark, isFalse);
    // focus=1：左亮右暗（旧版 Character 语义）。
    expect(points.last.characters.map((c) => '${c.slot}:${c.brightness}'), [
      'l:1.0',
      'r:0.5',
    ]);
    expect(points.first.ordinal, 1);
    expect(points.last.ordinal, 2);
  });
}
