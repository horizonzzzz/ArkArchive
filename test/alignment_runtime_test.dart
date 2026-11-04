import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:arknights_story_player/story_player/runtime/story_engine.dart';
import 'package:arknights_story_player/story_player/script.dart';

void main() {
  final engines = <StoryEngine>[];
  void testEngine(String name, WidgetTesterCallback body) {
    testWidgets(name, (tester) async {
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
    );
    engines.add(engine);
    return engine;
  }

  testEngine('40ms 打字机按字推进，点击补全后不会倒退', (tester) async {
    final e = engineFor(tester, '0123456789\nnext');
    await e.start();
    await tester.pump(const Duration(milliseconds: 16));
    expect(e.state.revealed, 0);
    await tester.pump(const Duration(milliseconds: 64));
    expect(e.state.revealed, 2);
    await e.advance();
    await tester.pump(const Duration(milliseconds: 16));
    expect(e.state.revealed, 10);
  });

  testEngine('自动播放在文字完成后按秒等待', (tester) async {
    final e = engineFor(tester, 'first\nsecond');
    e.setAutoMode('button_auto');
    await e.start();
    await tester.pump(const Duration(milliseconds: 208));
    expect(e.state.revealed, 5);
    await tester.pump(const Duration(milliseconds: 1500));
    expect(e.state.text, 'first');
    await tester.pump(const Duration(milliseconds: 180));
    expect(e.state.text, 'second');
  });

  for (final command in [
    '[subtitle(text="0123456789")]',
    '[sticker(id="s",text="0123456789",block=true)]',
  ]) {
    testEngine('$command 保留等待状态并可自动继续', (tester) async {
      final e = engineFor(tester, '$command\nnext');
      e.setAutoMode('button_auto');
      await e.start();
      expect(e.waitingInput, isTrue);
      await tester.pump(const Duration(milliseconds: 16));
      final overlay = e.state.subtitle ?? e.state.stickers['s']!;
      expect(overlay.revealed, 0);
      await tester.pump(const Duration(milliseconds: 384));
      expect(overlay.revealed, 10);
      await tester.pump(const Duration(seconds: 2));
      expect(e.state.text, 'next');
    });
  }


  for (final command in ['[name=""]', '[dialog]', '[aside]']) {
    testEngine('$command 隐藏对白并继续播放字幕', (tester) async {
      final e = engineFor(tester, 'before\n$command\n[subtitle(text="center")]\n[subtitle]\nafter');
      await e.start();
      await e.advance();
      await e.advance();
      expect(e.state.dialogueVisible, isFalse);
      expect(e.state.subtitle?.text, 'center');
      expect(e.waitingInput, isTrue);
      expect(e.state.history.map((line) => line.text), ['before', 'center']);
      expect(e.warnings, isEmpty);
      await e.advance();
      await e.advance();
      expect(e.state.subtitle, isNull);
      expect(e.state.dialogueVisible, isTrue);
      expect(e.state.text, 'after');
    });
  }

  testEngine('字幕不会隐式隐藏对白', (tester) async {
    final e = engineFor(tester, 'before\n[subtitle(text="center")]');
    await e.start();
    await e.advance();
    await e.advance();
    expect(e.state.dialogueVisible, isTrue);
    expect(e.state.subtitle?.text, 'center');
  });
  testEngine('旧版角色坐标仅在入场方向和完整坐标同时存在时设置起点', (tester) async {
    final e = engineFor(tester, 'line');
    await e.start();
    await e.handlers['character']!(StoryScript.parse(
      '[character(name="a",name2="b",enter="left",enter2="up",xpos1=123.9,ypos1=-45.8,xpos2=8,fadetime=1)]',
    ).commands.single);
    final left = e.state.characters.firstWhere((c) => c.slot == 'l');
    final right = e.state.characters.firstWhere((c) => c.slot == 'r');
    expect(left.actionX, 123);
    expect(left.actionY, -45);
    expect(right.actionX, 0);
    expect(right.actionY, 1072);
    await tester.pump(const Duration(milliseconds: 512));
    expect(left.actionX, closeTo(123 * (1 - .512 * (3 - .512 * (3 - .512))), .01));
    await tester.pump(const Duration(milliseconds: 512));
    expect(left.actionX, 0);
    expect(left.actionY, 0);
    await e.handlers['character']!(StoryScript.parse(
      '[character(name="c",xpos1=50,ypos1=60,fadetime=0)]',
    ).commands.single);
    final middle = e.state.characters.lastWhere((c) => c.slot == 'm');
    expect(middle.actionX, 0);
    expect(middle.actionY, 0);
  });

  testEngine('切入窗口交叉淡化并线性过渡参数，未指定参数保持原值', (tester) async {
    final e = engineFor(tester, 'line');
    await e.start();
    Future<void> cutin(String args) => e.handlers['charactercutin']!(
      StoryScript.parse('[charactercutin(widgetid="w",$args)]').commands.single,
    );
    await cutin('name="a",fadetime=0,offsetx=20,offsety=10,povx=10,povy=20,zoom=1,width=200');
    final window = e.state.cutins['w']!;
    await cutin('name="b",fadetime=1,offsetx=120,offsety=110,povx=30,povy=60,zoom=2,width=400');
    expect(window.characters.map((c) => c.alpha), [1, 0]);
    await tester.pump(const Duration(milliseconds: 512));
    expect(window.rootX, closeTo(711.2, .01));
    expect(window.rootY, closeTo(298.8, .01));
    expect(window.contentX, closeTo(-20.24, .01));
    expect(window.contentY, closeTo(40.48, .01));
    expect(window.zoom, closeTo(1.512, .001));
    expect(window.maskW, closeTo(302.4, .01));
    expect(window.characters[0].alpha, closeTo(.488, .001));
    expect(window.characters[1].alpha, closeTo(.512, .001));
    await tester.pump(const Duration(milliseconds: 512));
    expect(window.characters.map((c) => c.name), ['b']);
    expect(window.rootX, 760);
    await cutin('name="b",fadetime=0');
    expect(window.rootX, 760);
    expect(window.contentX, -30);
    expect(window.zoom, 2);
    expect(window.characters.map((c) => c.name), ['b']);
  });

  testEngine('切入窗口更新可中断替换和隐藏，零时长立即生效', (tester) async {
    final e = engineFor(tester, 'line');
    await e.start();
    Future<void> cutin(String args) => e.handlers['charactercutin']!(
      StoryScript.parse('[charactercutin(widgetid="w",$args)]').commands.single,
    );
    await cutin('name="a",fadetime=0');
    await cutin('name="b",fadetime=1');
    await tester.pump(const Duration(milliseconds: 320));
    await cutin('name="c",fadetime=0,offsetx=50');
    await tester.pump();
    final window = e.state.cutins['w']!;
    expect(window.characters.map((c) => c.name), ['c']);
    expect(window.rootX, 690);
    await cutin('fadetime=1');
    await tester.pump(const Duration(milliseconds: 320));
    await cutin('name="d",fadetime=0');
    await tester.pump(const Duration(seconds: 2));
    expect(e.state.cutins['w'], same(window));
    expect(window.characters.map((c) => c.name), ['d']);
    expect(window.alpha, 1);
  });
  testEngine('命名缓动用于中间帧', (tester) async {
    final e = engineFor(tester, '');
    var value = 0.0;
    unawaited(e.animate('probe', 1, (t) => value = t, ease: 'OutQuad'));
    await tester.pump(const Duration(milliseconds: 512));
    expect(value, closeTo(.761856, .001));
  });

  for (final tag in ['imagetween', 'backgroundtween']) {
    testEngine('$tag 读取数值坐标，零时长 loop 不会自旋', (tester) async {
      final image = tag == 'imagetween' ? 'image' : 'background';
      final e = engineFor(
        tester,
        '[$image(image="a")]\n[$tag(xfrom=100,xto=200,yfrom=30,yto=60,duration=0,loop=true)]\nline',
      );
      await e.start();
      final layer = tag == 'imagetween'
          ? e.state.images.single
          : e.state.backgrounds.single;
      expect(layer.x, 200);
      expect(layer.y, 60);
      await tester.pump(const Duration(seconds: 1));
      expect(layer.x, 200);
    });
  }

  testEngine('循环补间重播取消旧对象，替换补间后不再重启', (tester) async {
    final e = engineFor(
      tester,
      '[delay(time=0.1)]\n[image(image="a")]\n'
      '[imagetween(xscalefrom=1,xscaleto=2,duration=1,loop=true)]\nline',
    );
    final start = e.start();
    await tester.pump(const Duration(milliseconds: 112));
    await start;
    final old = e.state.images.single;
    final replay = e.restart();
    await tester.pump(const Duration(milliseconds: 112));
    await replay;
    final oldScale = old.scaleX;
    await tester.pump(const Duration(milliseconds: 256));
    expect(old.scaleX, oldScale);
    final layer = e.state.images.single;
    await e.handlers['imagetween']!(
      StoryScript.parse('[imagetween(xscaleto=3,duration=0)]').commands.single,
    );
    await tester.pump(const Duration(seconds: 3));
    expect(layer.scaleX, 3);
  });

  testEngine('CG 通道延迟先保持初值，再并行动画，block 等到全部完成', (tester) async {
    final e = engineFor(
      tester,
      '[cgitem(image="a",pfrom="0,0",pto="100,0",pduration=1,pdelay=1,'
      'sfrom=1,sto=2,sduration=1,sdelay=0.5,afrom=0,ato=1,aduration=1,adelay=1,block=true)]\nline',
    );
    final start = e.start();
    await tester.pump(const Duration(milliseconds: 512));
    final item = e.state.cgItems.values.single;
    expect(item.x, 0);
    expect(item.alpha, 0);
    expect(item.scale, closeTo(1.012, .001));
    expect(e.state.text, isEmpty);
    await e.setPaused(true);
    await tester.pump(const Duration(seconds: 2));
    expect(item.x, 0);
    await e.setPaused(false);
    await tester.pump(const Duration(milliseconds: 1008));
    expect(item.x, closeTo(52, .001));
    expect(item.alpha, closeTo(.52, .001));
    expect(item.scale, 2);
    expect(e.state.text, isEmpty);
    await tester.pump(const Duration(milliseconds: 496));
    await start;
    expect(item.x, 100);
    expect(e.state.text, 'line');
  });

  testEngine('CG 颜色延迟和零时长保持各自语义', (tester) async {
    final e = engineFor(
      tester,
      '[cgitem(image="a",cfrom="1,0,0,1",cto="0,1,0,1",aduration=1,adelay=1)]\nline',
    );
    await e.start();
    final item = e.state.cgItems.values.single;
    await tester.pump(const Duration(milliseconds: 512));
    expect(item.tint!.r, 1);
    await tester.pump(const Duration(milliseconds: 1008));
    expect(item.tint!.g, closeTo(.52, .001));
    await e.handlers['cgitem']!(
      StoryScript.parse(
        '[cgitem(image="b",pfrom="0,0",pto="100,0",pduration=0,pdelay=10,block=true)]',
      ).commands.single,
    );
    expect(e.state.cgItems['b']!.x, 100);
  });

  testEngine('CG 延迟可由重播取消，不会在旧对象上继续动画', (tester) async {
    final e = engineFor(
      tester,
      '[cgitem(image="a",pfrom="0,0",pto="100,0",pduration=1,pdelay=1,block=true)]\nline',
    );
    final start = e.start();
    await tester.pump(const Duration(milliseconds: 256));
    final old = e.state.cgItems['a']!;
    final replay = e.restart();
    await tester.pump();
    await start;
    await tester.pump(const Duration(milliseconds: 2200));
    await replay;
    expect(old.x, 0);
    expect(e.state.cgItems['a']!.x, 100);
    expect(e.state.history, hasLength(1));
  });
  testEngine('串行贴纸补间不会被尚未开始的步骤覆盖，join 可并行', (tester) async {
    final e = engineFor(
      tester,
      '[sticker(id="s",text="x",block=false)]\n'
      '[stickertween(id="s",pfrom="0,0",pto="100,0",pduration=1)]\n'
      '[stickertween(id="s",pfrom="100,0",pto="200,0",pduration=1)]\n'
      '[stickertween(id="s",rfrom=0,rto=90,rduration=1,join=true,isend=true)]\nline',
    );
    await e.start();
    final sticker = e.state.stickers['s']!;
    await tester.pump(const Duration(milliseconds: 512));
    expect(sticker.x, closeTo(51.2, .001));
    expect(sticker.rotation, 0);
    await tester.pump(const Duration(milliseconds: 1008));
    expect(sticker.x, closeTo(152, .001));
    expect(sticker.rotation, closeTo(46.8, .001));
    await tester.pump(const Duration(milliseconds: 496));
    expect(sticker.x, 200);
    expect(sticker.rotation, 90);
  });

  for (final mask in ['interlude_dialog_left', 'interlude_sq']) {
    testEngine('$mask 更新使在途 clear 失效并恢复可见', (tester) async {
      final e = engineFor(
        tester,
        '[interlude(channel="a",maskid="$mask",type=2,name="old")]\nline',
      );
      await e.start();
      final handler = e.handlers['interlude']!;
      await handler(
        StoryScript.parse(
          '[interlude(channel="a",clear=true,aduration=1,tsduration=1)]',
        ).commands.single,
      );
      await tester.pump(const Duration(milliseconds: 512));
      await handler(
        StoryScript.parse('[interlude(channel="a",type=2,name="new")]')
            .commands
            .single,
      );
      await tester.pump(const Duration(seconds: 2));
      final frame = e.state.interludes['a']!;
      expect(frame.name, 'new');
      expect(frame.alpha, 1);
      expect(frame.templateScale.dx, 1);
      expect(frame.templateScale.dy, 1);
    });
  }

  for (final tag in ['gridbg', 'verticalbg', 'largebg', 'largeimg']) {
    testEngine('$tag 淡出期间保留图层，结束后移除', (tester) async {
      final params = switch (tag) {
        'gridbg' =>
          'imagegroup="a/b/c/d",solidwidth="100/100",solidheight="100/100"',
        'verticalbg' =>
          'imagegroup="a/b",solidwidth="100",solidheight="100/100"',
        _ => 'imagegroup="a/b",solidwidth="100/100",solidheight=100',
      };
      final e = engineFor(tester, '[$tag($params,fadetime=0)]\nline');
      await e.start();
      final layers = tag == 'largeimg'
          ? e.state.largeImages
          : e.state.largeScenes;
      final old = layers.single;
      await e.handlers[tag]!(
        StoryScript.parse('[$tag(fadetime=1)]').commands.single,
      );
      expect(layers, contains(old));
      await tester.pump(const Duration(milliseconds: 512));
      expect(old.alpha, closeTo(.488, .001));
      expect(layers, contains(old));
      await tester.pump(const Duration(milliseconds: 512));
      expect(layers, isEmpty);
    });
  }

  testEngine('header 禁止自动播放时，自动及快速模式均不能启用', (tester) async {
    final e = engineFor(tester, '[header(is_autoable=false)]\nfirst\nsecond');
    await e.start();
    e.setAutoMode('button_auto');
    expect(e.autoMode, 'default');
    e.setAutoMode('quick_play');
    expect(e.autoMode, 'default');
    await tester.pump(const Duration(seconds: 5));
    expect(e.state.text, 'first');
  });
  for (final tag in ['imagetween', 'backgroundtween', 'largebgtween', 'largeimgtween']) {
    testEngine('$tag 从起点重复且可替换，不做往返或阻塞', (tester) async {
      final imageTag = switch (tag) {
        'imagetween' => 'image',
        'backgroundtween' => 'background',
        'largebgtween' => 'largebg',
        _ => 'largeimg',
      };
      final params = tag.startsWith('large')
          ? 'imagegroup="a/b",solidwidth="100/100",solidheight=100'
          : 'image="a"';
      final e = engineFor(tester,
        '[$imageTag($params,fadetime=0)]\n[$tag(xfrom=0,xto=100,duration=1,loop=true,block=true)]\nline');
      await e.start();
      double x() => switch (tag) {
        'imagetween' => e.state.images.single.x,
        'backgroundtween' => e.state.backgrounds.single.x,
        'largebgtween' => e.state.largeScenes.single.x,
        _ => e.state.largeImages.single.x,
      };
      expect(e.state.text, 'line');
      await tester.pump(const Duration(milliseconds: 512));
      expect(x(), closeTo(51.2, .001));
      await tester.pump(const Duration(milliseconds: 752));
      expect(x(), closeTo(26.4, .001));
      await e.handlers[tag]!(StoryScript.parse('[$tag(xto=300,duration=0)]').commands.single);
      await tester.pump(const Duration(seconds: 2));
      expect(x(), 300);
    });
  }

  testEngine('subtitle multi 仅合并历史，显示文本与坐标逐条替换', (tester) async {
    final e = engineFor(tester,
      '[subtitle(text="甲",multi=true,x=10)]\n'
      '[subtitle(text="乙",multi=true,x=20)]\n'
      '[subtitle(text="丙",multi=false)]\n'
      '[subtitle(text="丁",multi=true,hidelog=true)]\n'
      '[subtitle(text="戊",multi=true)]\nline');
    await e.start();
    await e.advance();
    await e.advance();
    expect(e.state.subtitle!.text, '乙');
    expect(e.state.subtitle!.x, 20);
    expect(e.state.history.map((l) => l.text), ['甲乙']);
    await e.advance();
    await e.advance();
    expect(e.state.history.map((l) => l.text), ['甲乙', '丙']);
    await e.advance();
    await e.advance();
    expect(e.state.subtitle!.text, '丁');
    expect(e.state.history.map((l) => l.text), ['甲乙', '丙']);
    await e.advance();
    await e.advance();
    expect(e.state.history.map((l) => l.text), ['甲乙', '丙', '戊']);
  });

  testEngine('sticker multi 续接时旧字符不倒退，历史按来源合并', (tester) async {
    final e = engineFor(tester,
      '[sticker(id="s",text="甲",multi=true)]\n'
      '[sticker(id="s",text="乙",multi=true,block=true)]\nline');
    await e.start();
    await e.advance();
    await e.advance();
    final sticker = e.state.stickers['s']!;
    expect(sticker.text, '甲乙');
    expect(sticker.revealed, 1);
    await tester.pump(const Duration(milliseconds: 16));
    expect(sticker.revealed, 1);
    await tester.pump(const Duration(milliseconds: 32));
    expect(sticker.revealed, 2);
    expect(e.state.history.map((l) => l.text), ['甲乙']);
  });
}
