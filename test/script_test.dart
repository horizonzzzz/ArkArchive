import 'package:flutter_test/flutter_test.dart';
import 'package:arknights_story_player/story_player/script.dart';

void main() {
  test('解析真实语法：命令大小写、带逗号和方括号的引号参数、纯旁白', () {
    final script = StoryScript.parse(r'''
// 注释
[Background(image="snow", screenadapt="coverall")]
[charslot(slot = "left", name = "actor#2$1", duration=0.5, posfrom="0,10")]
[name="甲,乙"]<b>对白</b>
旁白
[FutureEffect(value="a]b)", escaped="say \"yes\"")]
''');
    expect(script.commands.map((c) => c.tag), [
      'background',
      'charslot',
      'dialogue',
      'dialogue',
      'futureeffect',
    ]);
    expect(script.commands[1].value('posfrom'), '0,10');
    expect(script.commands[2].value('name'), '甲,乙');
    expect(script.commands[3].value('name'), isEmpty);
    expect(script.commands.last.value('value'), 'a]b)');
    expect(script.commands.last.value('escaped'), 'say "yes"');
    expect(script.commands.last.line, 6);
  });
  test('续行保留第一行行号，未知命令仍保留', () {
    final script = StoryScript.parse(
      '[Background(image="a",\\\n fadetime=1)]\n[Unrecognized]',
    );
    expect(script.commands.first.value('fadetime'), '1');
    expect(script.commands.first.line, 1);
    expect(script.commands.last.tag, 'unrecognized');
  });
  test('损坏命令提供行号，数值 NaN 不传播', () {
    expect(
      () => StoryScript.parse('[Background(image="x")'),
      throwsFormatException,
    );
    final command = StoryScript.parse('[Delay(time=NaN)]').commands.single;
    expect(command.number('time', 3), 3);
  });
}
