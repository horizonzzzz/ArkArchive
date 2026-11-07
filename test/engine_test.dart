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
}
