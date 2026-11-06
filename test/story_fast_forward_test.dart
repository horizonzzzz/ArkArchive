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
    e.setFastForward(true);
    expect(e.state.revealed, 4);
    await tester.pump(const Duration(milliseconds: 160));
    expect(e.state.revealed, 12);
    e.setFastForward(false);
    expect(e.state.revealed, 12);
    await tester.pump(const Duration(milliseconds: 160));
    expect(e.state.revealed, 16);
    expect(e.autoMode, 'default');
    expect(e.speedLevel, 0);
  });

  testEngine('运行中的动画即时二倍速，恢复后继续原进度', (tester) async {
    final e = engineFor(tester, 'text');
    var progress = 0.0;
    unawaited(e.animate('probe', 1, (value) => progress = value));
    await tester.pump(const Duration(milliseconds: 192));
    expect(progress, closeTo(.192, .001));
    e.setFastForward(true);
    await tester.pump(const Duration(milliseconds: 192));
    expect(progress, closeTo(.576, .001));
    e.setFastForward(false);
    await tester.pump(const Duration(milliseconds: 192));
    expect(progress, closeTo(.768, .001));
  });

  testEngine('已经开始的剧情等待也按临时倍率推进', (tester) async {
    final e = engineFor(tester, '[delay(time=1)]\nnext');
    unawaited(e.start());
    await tester.pump(const Duration(milliseconds: 192));
    e.setFastForward(true);
    await tester.pump(const Duration(milliseconds: 288));
    expect(e.state.text, isEmpty);
    e.setFastForward(false);
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
    e.setFastForward(true);
    await tester.pump(const Duration(milliseconds: 288));
    expect(e.state.text, 'a');
    await tester.pump(const Duration(milliseconds: 32));
    expect(e.state.text, 'second');
    e.setFastForward(false);
    expect(e.autoMode, 'button_auto');
  });

  testEngine('字幕打字同样使用二倍剧情时钟', (tester) async {
    final e = engineFor(
      tester,
      '[subtitle(text="01234567890123456789",block=true)]\nnext',
    );
    await e.start();
    await tester.pump(const Duration(milliseconds: 160));
    expect(e.state.subtitle!.revealed, 4);
    e.setFastForward(true);
    await tester.pump(const Duration(milliseconds: 160));
    expect(e.state.subtitle!.revealed, 12);
    e.setFastForward(false);
    await tester.pump(const Duration(milliseconds: 160));
    expect(e.state.subtitle!.revealed, 16);
  });
}
