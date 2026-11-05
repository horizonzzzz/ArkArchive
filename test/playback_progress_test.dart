import 'package:flutter_test/flutter_test.dart';
import 'package:arknights_story_player/story_player/story_player.dart';

class _RecordingAudio extends SilentStoryAudio {
  final commands = <StoryCommand>[];
  @override
  Future<void> execute(StoryCommand command) async => commands.add(command);
}

void main() {
  test('恢复当前对白、背景、分支和历史，并继续正确的后续剧情', () async {
    final script = StoryScript.parse('''
[background(image="start")]
[decision(options="左边;右边", values="1;2")]
[predicate(references="1")]
[name="甲"]左侧对白
[predicate(references="2")]
[background(image="right")]
[name="乙"]右侧对白
[predicate(references="")]
[name="丙"]后续对白
''');
    final original = StoryEngine(script);
    final restored = StoryEngine(script);
    addTearDown(original.dispose);
    addTearDown(restored.dispose);
    expect(original.checkpoint, isNull);
    await original.start();
    await original.choose('2');
    final saved = PlaybackCheckpoint.fromJson(original.checkpoint!.toJson());
    await restored.restore(saved);
    expect(restored.cursor, original.cursor);
    expect(restored.state.text, '右侧对白');
    expect(restored.state.speaker, '乙');
    expect(restored.state.revealed, 0);
    expect(restored.state.backgrounds.last.key, 'right');
    expect(restored.state.history.map((line) => line.text), ['右侧对白']);
    expect(restored.checkpoint!.toJson(), saved.toJson());
    await restored.advance();
    await restored.advance();
    expect(restored.state.text, '后续对白');
    await restored.advance();
    await restored.advance();
    expect(restored.finished, isTrue);
    expect(restored.checkpoint, isNull);
    await restored.restart();
    expect(restored.state.choices.map((c) => c.value), ['1', '2']);
    expect(restored.checkpoint!.trace, [0, 1]);
  });

  test('实际开始播放即产生起点断点，尚未到第一句也能再次继续', () async {
    final script = StoryScript.parse('[delay(time=0)]\n第一句');
    final original = StoryEngine(script);
    final restored = StoryEngine(script);
    addTearDown(original.dispose);
    addTearDown(restored.dispose);
    PlaybackCheckpoint? first;
    original.addListener(() { first ??= original.checkpoint; });
    expect(original.checkpoint, isNull);
    await original.start();
    expect(first!.cursor, 0);
    expect(first!.trace, isEmpty);
    final saved = PlaybackCheckpoint.fromJson(first!.toJson());
    await restored.restore(saved);
    expect(restored.state.text, '第一句');
  });
  test('停在选项处恢复时不代选，选择后仍能再次保存和恢复', () async {
    final script = StoryScript.parse('''
[decision(options="接受;拒绝", values="1;2")]
[predicate(references="1")]
接受的对白
[predicate(references="2")]
拒绝的对白
''');
    final original = StoryEngine(script);
    final restored = StoryEngine(script);
    final secondRestore = StoryEngine(script);
    addTearDown(original.dispose);
    addTearDown(restored.dispose);
    addTearDown(secondRestore.dispose);
    await original.start();
    await restored.restore(original.checkpoint!);
    expect(restored.state.choices.map((c) => c.label), ['接受', '拒绝']);
    await restored.choose('1');
    await secondRestore.restore(restored.checkpoint!);
    expect(secondRestore.state.text, '接受的对白');
    expect(secondRestore.state.choices, isEmpty);
  });

  test('恢复时直接完成转场与等待，不重放历史单次音效，只恢复有效循环音轨', () async {
    final script = StoryScript.parse('''
[playmusic(key="old")]
[playsound(key="once")]
[playmusic(key="current", delay=30)]
[musicvolume(volume=0.3)]
[playsound(key="wind", channel="ambience", loop=true)]
[playsound(key="stopped", channel="other", loop=true)]
[stopsound(channel="other")]
[delay(time=30)]
[camerashake(duration=30, block=true)]
[background(image="room", fadetime=30, block=true)]
[name="博士"]恢复这一句
''');
    final audio = _RecordingAudio();
    final engine = StoryEngine(script, audio: audio);
    addTearDown(engine.dispose);
    await engine.restore(PlaybackCheckpoint(
      cursor: script.commands.length,
      trace: List.generate(script.commands.length, (index) => index),
    )).timeout(const Duration(seconds: 2));
    expect(engine.state.text, '恢复这一句');
    expect(engine.state.backgrounds.single.key, 'room');
    expect(engine.state.backgrounds.single.alpha, 1);
    expect(audio.commands.map((c) => c.value('key')), ['current', 'wind']);
    expect(audio.commands.first.number('volume'), .3);
    expect(audio.commands.first.number('delay'), 0);
    expect(engine.finished, isFalse);
  });

  test('多行对白恢复保留前段文字的显示边界', () async {
    final script = StoryScript.parse('''
[multiline(name="博士")]前段
[multiline(name="博士", end=true)]后段
''');
    final original = StoryEngine(script);
    final restored = StoryEngine(script);
    addTearDown(original.dispose);
    addTearDown(restored.dispose);
    await original.start();
    await original.advance();
    await original.advance();
    await restored.restore(original.checkpoint!);
    expect(restored.state.text, '前段后段');
    expect(restored.state.revealed, '前段'.length);
  });

  test('跳过节点后恢复保留跳过后的当前对白，跳到结尾不再产生断点', () async {
    final script = StoryScript.parse('''
开头
[skipnode]
跳过后的对白
''');
    final original = StoryEngine(script);
    final restored = StoryEngine(script);
    addTearDown(original.dispose);
    addTearDown(restored.dispose);
    await original.start();
    await original.skipNode();
    await Future<void>.delayed(Duration.zero);
    expect(original.state.text, '跳过后的对白');
    await restored.restore(original.checkpoint!);
    expect(restored.state.text, '跳过后的对白');
    await restored.skipNode();
    expect(restored.finished, isTrue);
    expect(restored.checkpoint, isNull);
  });

  test('自动播放的结束提示可以恢复，手动模式忽略的提示不进入历史', () async {
    final script = StoryScript.parse('[endtip]自动结束提示\n后续正文');
    final original = StoryEngine(script);
    final restored = StoryEngine(script);
    final manual = StoryEngine(script);
    final manualRestore = StoryEngine(script);
    addTearDown(original.dispose);
    addTearDown(restored.dispose);
    addTearDown(manual.dispose);
    addTearDown(manualRestore.dispose);
    original.setAutoMode('button_auto');
    await original.start();
    await restored.restore(original.checkpoint!);
    expect(restored.state.text, '自动结束提示');
    await manual.start();
    await manualRestore.restore(manual.checkpoint!);
    expect(manualRestore.state.history.map((line) => line.text), ['后续正文']);
  });
  test('拒绝越界或选项无效的断点', () async {
    final script = StoryScript.parse('正文');
    final engine = StoryEngine(script);
    addTearDown(engine.dispose);
    await expectLater(engine.restore(PlaybackCheckpoint(cursor: 9, trace: [8])),
      throwsFormatException);
    await expectLater(engine.restore(PlaybackCheckpoint(cursor: 1, trace: [-2])),
      throwsFormatException);
    expect(() => PlaybackCheckpoint.fromJson({'cursor': 1, 'trace': ['0']}),
      throwsFormatException);
  });
}
