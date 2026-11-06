import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:arknights_story_player/story_player/runtime/story_engine.dart';
import 'package:arknights_story_player/story_player/script.dart';

void main() {
  final engines = <StoryEngine>[];

  void testEngine(String description, WidgetTesterCallback body) {
    testWidgets(description, (tester) async {
      try {
        await body(tester);
      } finally {
        for (final engine in engines) {
          engine.dispose();
        }
        engines.clear();
      }
    });
  }

  StoryEngine engineFor(WidgetTester tester, String source) {
    final initial = tester.binding.clock.now();
    final engine = StoryEngine(
      StoryScript.parse(source),
      elapsed: () => tester.binding.clock.now().difference(initial),
      autoWaitSeconds: 1,
    );
    engines.add(engine);
    return engine;
  }

  testEngine('临时二倍速只加速后续打字，松手不倒退且保留手动模式', (tester) async {
    final e = engineFor(tester, '0123456789' * 10);
    await e.start();
    await tester.pump(const Duration(milliseconds: 160));
    expect(e.state.revealed, 4);
    e.setFastForward(2);
    expect(e.state.revealed, 4);
    await tester.pump(const Duration(milliseconds: 160));
    expect(e.state.revealed, 12);
    e.setFastForward(0);
    expect(e.state.revealed, 12);
    await tester.pump(const Duration(milliseconds: 160));
    expect(e.state.revealed, 16);
    expect(e.autoMode, 'default');
    expect(e.speedLevel, 0);
  });

  testEngine('8/16 倍速档位同步加速打字，松手不倒退', (tester) async {
    final e = engineFor(tester, '0123456789' * 10);
    await e.start();
    await tester.pump(const Duration(milliseconds: 160));
    expect(e.state.revealed, 4);
    e.setFastForward(8);
    await tester.pump(const Duration(milliseconds: 160));
    expect(e.state.revealed, 36);
    e.setFastForward(16);
    await tester.pump(const Duration(milliseconds: 160));
    expect(e.state.revealed, 100);
    e.setFastForward(0);
    await tester.pump(const Duration(milliseconds: 160));
    expect(e.state.revealed, 100);
    expect(e.fastForwarding, isFalse);
  });

  testEngine('运行中的动画即时二倍速，恢复后继续原进度', (tester) async {
    final e = engineFor(tester, 'text');
    var progress = 0.0;
    unawaited(e.animate('probe', 1, (value) => progress = value));
    await tester.pump(const Duration(milliseconds: 192));
    expect(progress, closeTo(.192, .001));
    e.setFastForward(2);
    await tester.pump(const Duration(milliseconds: 192));
    expect(progress, closeTo(.576, .001));
    e.setFastForward(0);
    await tester.pump(const Duration(milliseconds: 192));
    expect(progress, closeTo(.768, .001));
  });

  testEngine('运行中的动画即时四倍速完成', (tester) async {
    final e = engineFor(tester, 'text');
    var progress = 0.0;
    unawaited(e.animate('probe', 1, (value) => progress = value));
    await tester.pump(const Duration(milliseconds: 192));
    expect(progress, closeTo(.192, .001));
    e.setFastForward(4);
    await tester.pump(const Duration(milliseconds: 192));
    expect(progress, closeTo(.96, .001));
    e.setFastForward(0);
    await tester.pump(const Duration(milliseconds: 192));
    expect(progress, closeTo(1, .001));
  });

  testEngine('已经开始的剧情等待也按临时倍率推进', (tester) async {
    final e = engineFor(tester, '[delay(time=1)]\nnext');
    unawaited(e.start());
    await tester.pump(const Duration(milliseconds: 192));
    e.setFastForward(2);
    await tester.pump(const Duration(milliseconds: 288));
    expect(e.state.text, isEmpty);
    e.setFastForward(0);
    await tester.pump(const Duration(milliseconds: 240));
    expect(e.state.text, 'next');
  });

  testEngine('自动播放剩余等待随二倍速推进，不重置完整等待', (tester) async {
    final e = engineFor(tester, '[header(is_autoable=true)]\na\nsecond');
    e.setAutoMode('button_auto');
    await e.start();
    await e.advance();
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 400));
    e.setFastForward(2);
    await tester.pump(const Duration(milliseconds: 288));
    expect(e.state.text, 'a');
    await tester.pump(const Duration(milliseconds: 32));
    expect(e.state.text, 'second');
    e.setFastForward(0);
    expect(e.autoMode, 'button_auto');
  });

  testEngine('手动模式长按快进会自动推进对白，松手停止且保持手动', (tester) async {
    final e = engineFor(tester, 'a\nsecond');
    await e.start();
    await tester.pump(const Duration(milliseconds: 200));
    e.setFastForward(2);
    expect(e.autoMode, 'default');
    await tester.pump(const Duration(milliseconds: 1000));
    expect(e.state.text, 'second');
    expect(e.state.history, hasLength(2));
    e.setFastForward(0);
    await tester.pump(const Duration(milliseconds: 1000));
    expect(e.state.text, 'second');
    expect(e.state.revealed, 6);
    expect(e.finished, isFalse);
    expect(e.autoMode, 'default');
    expect(e.speedLevel, 0);
  });

  testEngine('长按快进中途换挡不重置剩余等待', (tester) async {
    final e = engineFor(tester, 'a\nsecond');
    await e.start();
    await tester.pump(const Duration(milliseconds: 200));
    e.setFastForward(2);
    await tester.pump(const Duration(milliseconds: 400));
    expect(e.state.text, 'a');
    e.setFastForward(8);
    await tester.pump(const Duration(milliseconds: 200));
    expect(e.state.text, 'second');
    e.setFastForward(0);
    expect(e.autoMode, 'default');
  });

  testEngine('长按快进在选项处停止自动推进，松手后可手动选择', (tester) async {
    final e = engineFor(tester, 'a\n[decision(options=x;y,values=1;2)]\nb');
    await e.start();
    await tester.pump(const Duration(milliseconds: 200));
    e.setFastForward(2);
    await tester.pump(const Duration(milliseconds: 1200));
    expect(e.state.choices, hasLength(2));
    await tester.pump(const Duration(milliseconds: 800));
    expect(e.state.choices, hasLength(2));
    expect(e.state.text, 'a');
    e.setFastForward(0);
    expect(e.autoMode, 'default');
    await e.choose(e.state.choices.first.value);
    expect(e.state.text, 'b');
  });

  testEngine('字幕打字同样使用二倍剧情时钟', (tester) async {
    final e = engineFor(
      tester,
      '[subtitle(text="01234567890123456789",block=true)]\nnext',
    );
    await e.start();
    await tester.pump(const Duration(milliseconds: 160));
    expect(e.state.subtitle!.revealed, 4);
    e.setFastForward(2);
    await tester.pump(const Duration(milliseconds: 160));
    expect(e.state.subtitle!.revealed, 12);
    e.setFastForward(0);
    await tester.pump(const Duration(milliseconds: 160));
    expect(e.state.subtitle!.revealed, 16);
  });
}
