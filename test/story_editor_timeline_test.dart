import 'package:arknights_story_player/story_editor/editor_project.dart';
import 'package:arknights_story_player/story_editor/editor_timeline.dart';
import 'package:arknights_story_player/story_player/script.dart';
import 'package:flutter_test/flutter_test.dart';

const _background = (kind: TrackKind.background, id: '');
const _music = (kind: TrackKind.music, id: '');
const _left = (kind: TrackKind.character, id: 'l');
const _sound = (kind: TrackKind.sound, id: 'weather');
const _effect = (kind: TrackKind.effect, id: '2');

void main() {
  test('官方格式导入按指令列还原背景、BGM、差分、分支和等待', () {
    final project = EditorProject.fromScript(
      '轨道',
      StoryScript.parse('''
[Background(image="scene_a", x=4)]
[PlayMusic(key="theme_a")]
[CharSlot(slot="l", name="actor#1")]
[name="甲"]出发。
[CharSlot(slot="l", name="actor#2", posto="30,0")]
[BackgroundTween(xto=12)]
[Delay(time=1)]
[Decision(options="前进;停留", values="1;2")]
[StopMusic(fadetime=2)]
[Background(image="scene_b")]
[name="乙"]到了。
'''),
    );
    final timeline = EditorTimeline.of(project, 0);
    final compiled = project.compile();
    expect(
      timeline.columns.map((column) => column.globalEnd),
      List.generate(11, (i) => i + 1),
    );
    for (final column in timeline.columns) {
      final address = column.address;
      expect(
        column.globalEnd,
        compiled.ranges[(address.scene, address.beat)]!.$1 +
            address.command +
            1,
      );
    }
    expect(
      timeline.tracks[_background]!.map(
        (span) => (span.start, span.end, span.initial.label),
      ),
      [(0, 5, 'scene_a'), (5, 9, 'scene_a'), (9, 11, 'scene_b')],
    );
    expect(timeline.spanAt(_background, 6)!.at(6).command.value('x'), '12');
    expect(timeline.tracks[_music]!.map((span) => (span.start, span.end)), [
      (1, 8),
    ]);
    expect(timeline.tracks[_left]!.single.markers.single.$1, 4);
    expect(timeline.spanAt(_left, 4)!.at(4).label, 'actor#2');
    expect(timeline.ticks.map((tick) => tick.column), [3, 6, 7, 10]);
    expect(timeline.ticks.first.speaker, '甲');
    expect(identical(timeline, EditorTimeline.of(project, 0)), isTrue);
  });

  test('导入的旁白、多段对白、结束提示和对白框清除均有刻度', () {
    final project = EditorProject.fromScript(
      '轨道',
      StoryScript.parse('''
[Aside]旁白
[Multiline(name="甲", end=true)]多段对白
[EndTip]结束提示内容
[Dialog(name="乙")]对白
[Dialog]
'''),
    );
    final timeline = EditorTimeline.of(project, 0);
    expect(
      timeline.ticks.map((tick) => (tick.column, tick.label, tick.speaker)),
      [
        (0, '旁白', ''),
        (1, '多段对白', '甲'),
        (2, '结束提示内容', ''),
        (3, '对白', '乙'),
        (4, '清除对白框', ''),
      ],
    );
  });
  test('跨幕继承、空分镜、按通道/图层清除和固化', () {
    final project = EditorProject.create('轨道').copyWith(
      scenes: const [
        EditorScene('前幕', [
          StoryBeat('建立状态', [
            EditCommand('background', {'image': 'scene_a'}),
            EditCommand('playmusic', {'key': 'theme_a'}),
            EditCommand('playsound', {
              'key': 'wind',
              'channel': 'weather',
              'loop': 'true',
            }),
            EditCommand('bgeffect', {'name': 'rain', 'layer': '2'}),
          ]),
        ]),
        EditorScene('当前幕', [
          StoryBeat('空镜'),
          StoryBeat('更新状态', [
            EditCommand('playsound', {'key': 'rumble', 'channel': 'weather'}),
            EditCommand('bgeffect', {'layer': '2'}),
            EditCommand('background', {'image': 'scene_b'}),
          ]),
        ]),
      ],
    );
    final timeline = EditorTimeline.of(project, 1);
    const source = (scene: 0, beat: 0, command: 0);
    expect(timeline.columns.first.globalEnd, 4);
    expect(timeline.insertAfter(0), (scene: 1, beat: 0, command: 0));
    expect(timeline.incoming[_background]!.source, source);
    expect(timeline.stateBeforeBeat(1)[_background]!.source, source);
    expect(timeline.affectedBeats(source), {0, 1});
    expect(timeline.spanAt(_sound, 0)!.initial.label, 'wind');
    expect(timeline.spanAt(_sound, 1), isNull);
    expect(timeline.events[_sound]!.single.$2.label, 'rumble');
    expect(timeline.spanAt(_effect, 2), isNull);
    expect(timeline.spanAt(_music, 3)!.initial.label, 'theme_a');
    expect(clearTrack(_effect)!.args, {'layer': '2', 'name': ''});

    final frozen = timeline.freeze(0);
    final updated = project.copyWith(
      scenes: [
        project.scenes[0],
        EditorScene('当前幕', [
          StoryBeat('空镜', frozen),
          project.scenes[1].beats[1],
        ]),
      ],
    );
    final rebuilt = EditorTimeline.of(updated, 1);
    final column = rebuilt.columnOf(0, -1);
    for (final slot in [_background, _music, _sound, _effect]) {
      expect(
        rebuilt.spanAt(slot, column)!.at(column).label,
        timeline.incoming[slot]!.label,
      );
      expect(rebuilt.spanAt(slot, column)!.at(column).source.scene, 1);
    }
  });

  test('固化跨幕立绘时保留聚焦和位置', () {
    final project = EditorProject.create('立绘').copyWith(
      scenes: const [
        EditorScene('前幕', [
          StoryBeat('入场', [
            EditCommand('character', {'name': 'actor_a', 'name2': 'actor_b'}),
            EditCommand('charslot', {
              'slot': 'l',
              'posto': '40,20',
              'focus': 'l',
            }),
            EditCommand('charslot', {'slot': 'r', 'focus': 'r'}),
          ]),
        ]),
        EditorScene('当前幕', [StoryBeat('继承')]),
      ],
    );
    final timeline = EditorTimeline.of(project, 1);
    final frozen = timeline.freeze(0);
    final characters = frozen.where(
      (c) => c.tag == 'charslot' && c.value('name').isNotEmpty,
    );
    expect(
      characters.map(
        (c) => (
          c.value('slot'),
          c.value('name'),
          c.value('posto'),
          c.value('focus'),
        ),
      ),
      [('l', 'actor_a', '40,20', 'r'), ('r', 'actor_b', '', 'r')],
    );
  });
}
