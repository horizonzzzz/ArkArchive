import '../story_player/script.dart';
import 'editor_project.dart';

typedef TrackAddress = ({int scene, int beat, int command});
typedef TrackSlot = ({TrackKind kind, String id});

enum TrackKind {
  dialogue('对白'),
  background('背景', FieldType.background),
  cg('CG', FieldType.cg),
  character('立绘', FieldType.character),
  subtitle('舞台文字'),
  music('BGM', FieldType.music),
  sound('音效'),
  effect('持续特效'),
  blocker('遮罩');

  const TrackKind(this.label, [this.media]);
  final String label;
  final FieldType? media;
}

String trackSlotLabel(TrackSlot slot) => slot.id.isEmpty
    ? slot.kind.label
    : '${slot.kind.label} ${slot.kind == TrackKind.character ? slot.id.toUpperCase() : slot.id}';

class TrackValue {
  const TrackValue(
    this.label,
    this.source,
    this.field,
    this.command, {
    this.previousMedia,
    this.fieldSources = const {},
  });
  final String label;
  final TrackAddress source;
  final String? field;
  final EditCommand command;
  final (TrackAddress, String)? previousMedia;
  final Map<String, TrackAddress> fieldSources;

  (TrackAddress, String)? get mediaOrigin =>
      field == null ? previousMedia : (source, field!);

  bool dependsOn(TrackAddress address) =>
      source == address ||
      mediaOrigin?.$1 == address ||
      fieldSources.containsValue(address);
}

class TrackSpan {
  TrackSpan(this.slot, this.start, this.initial);
  final TrackSlot slot;
  final int start;
  final TrackValue initial;
  final markers = <(int, TrackValue)>[];
  int end = 0;

  TrackValue at(int column) {
    var low = 0;
    var high = markers.length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (markers[mid].$1 <= column) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low == 0 ? initial : markers[low - 1].$2;
  }
}

class TrackTick {
  const TrackTick(this.column, this.label, this.speaker);
  final int column;
  final String label;
  final String speaker;
}

class TrackColumn {
  const TrackColumn(this.address, this.globalEnd);
  final TrackAddress address;
  // 与 StoryEngine.rebuildBefore 一样，排除该索引处的指令。
  final int globalEnd;
}

class EditorTimeline {
  EditorTimeline._(
    this.scene,
    this.globalStart,
    this.incoming,
    this._incomingFocus,
  );

  final int scene, globalStart;
  final Map<TrackSlot, TrackValue> incoming;
  final columns = <TrackColumn>[];
  final beats = <(int, int)>[];
  final ticks = <TrackTick>[];
  final tracks = <TrackSlot, List<TrackSpan>>{};
  final events = <TrackSlot, List<(int, TrackValue)>>{};
  final _outgoing = <TrackSlot, TrackValue>{};
  final String _incomingFocus;
  final _focusChanges = <(int, String)>[];
  int _globalEnd = 0;

  static final _sceneCache = Expando<EditorTimeline>();
  static final _projectCache = Expando<List<EditorTimeline>>();

  static EditorTimeline of(EditorProject project, int scene) {
    final timelines = _projectCache[project] ??= [];
    while (timelines.length <= scene) {
      final index = timelines.length;
      final data = project.scenes[index];
      final incoming = timelines.isEmpty
          ? const <TrackSlot, TrackValue>{}
          : timelines.last._outgoing;
      final start = timelines.isEmpty ? 0 : timelines.last._globalEnd;
      final focus = timelines.isEmpty
          ? 'all'
          : timelines.last._focusChanges.lastOrNull?.$2 ??
                timelines.last._incomingFocus;
      final cached = _sceneCache[data];
      final timeline =
          cached != null &&
              cached.scene == index &&
              cached.globalStart == start &&
              identical(cached.incoming, incoming) &&
              cached._incomingFocus == focus
          ? cached
          : (_sceneCache[data] = (EditorTimeline._(
              index,
              start,
              incoming,
              focus,
            ).._scan(data)));
      timelines.add(timeline);
    }
    return timelines[scene];
  }

  int columnOf(int beat, int command) {
    final (start, end) = beats[beat];
    return command < 0 ? end - 1 : (start + command).clamp(start, end - 1);
  }

  TrackAddress insertAfter(int column) {
    final address = columns[column].address;
    return (scene: scene, beat: address.beat, command: address.command + 1);
  }

  TrackSpan? spanAt(TrackSlot slot, int column) {
    final spans = tracks[slot];
    if (spans == null) return null;
    var low = 0;
    var high = spans.length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (spans[mid].start <= column) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    if (low == 0 || spans[low - 1].end <= column) return null;
    return spans[low - 1];
  }

  Set<int> affectedBeats(TrackAddress source) {
    final result = <int>{};
    void add(int start, int end) {
      if (start >= end) return;
      final first = columns[start].address.beat;
      final last = columns[end - 1].address.beat;
      for (var index = first; index <= last; index++) {
        result.add(index);
      }
    }

    for (final spans in tracks.values) {
      for (final span in spans) {
        if (span.initial.dependsOn(source)) {
          add(
            span.start,
            span.markers.isEmpty ? span.end : span.markers.first.$1,
          );
        }
        for (final (index, marker) in span.markers.indexed) {
          if (marker.$2.dependsOn(source)) {
            add(
              marker.$1,
              index + 1 < span.markers.length
                  ? span.markers[index + 1].$1
                  : span.end,
            );
          }
        }
      }
    }
    for (final row in events.values) {
      for (final (column, value) in row) {
        if (value.source == source) add(column, column + 1);
      }
    }
    return result;
  }

  Map<TrackSlot, TrackValue> stateBeforeBeat(int beat) {
    final column = beats[beat].$1 - 1;
    if (column < 0) return incoming;
    return {
      for (final slot in tracks.keys) slot: ?spanAt(slot, column)?.at(column),
    };
  }

  String focusAt(int column) {
    for (final (position, focus) in _focusChanges.reversed) {
      if (position <= column) return focus;
    }
    return _incomingFocus;
  }

  List<EditCommand> freeze(int column) {
    final state = {
      for (final slot in tracks.keys) slot: ?spanAt(slot, column)?.at(column),
    };
    return [
      for (final kind in [
        TrackKind.background,
        TrackKind.cg,
        TrackKind.subtitle,
        TrackKind.music,
        TrackKind.blocker,
      ])
        if (!state.containsKey((kind: kind, id: '')))
          clearTrack((kind: kind, id: ''))!,
      const EditCommand('charslot'),
      const EditCommand('stopsound'),
      const EditCommand('bgeffect'),
      for (final value in state.values)
        if (value.command.tag == 'charslot')
          settledTrackCommand(value.command)
              .withArgs({'focus': focusAt(column)})
        else
          settledTrackCommand(value.command),
    ];
  }

  void _scan(EditorScene data) {
    const characters = ['l', 'm', 'r'];
    final active = <TrackSlot, TrackSpan>{};
    var column = 0;
    var global = globalStart;
    for (final entry in incoming.entries) {
      active[entry.key] = TrackSpan(entry.key, 0, entry.value);
    }
    for (final (beatIndex, beat) in data.beats.indexed) {
      final start = column;
      if (beat.commands.isEmpty) {
        columns.add(
          TrackColumn((scene: scene, beat: beatIndex, command: -1), global),
        );
        column++;
      }
      for (final (index, edit) in beat.commands.indexed) {
        final address = (scene: scene, beat: beatIndex, command: index);
        columns.add(TrackColumn(address, ++global));
        final command = edit.raw == null
            ? StoryCommand(edit.tag, edit.args, edit.value('text'), 0, '')
            : edit.parsedRaw;
        if (command == null) {
          column++;
          continue;
        }
        final c = command;
        final normalized = EditCommand(c.tag, c.args);
        TrackValue value(String label, [String? field, EditCommand? state]) =>
            TrackValue(label, address, field, state ?? normalized);
        TrackValue update(TrackValue previous, Map<String, String> changes) =>
            TrackValue(
              previous.label,
              address,
              null,
              previous.command.withArgs(changes),
              previousMedia: previous.mediaOrigin,
              fieldSources: {
                ...previous.fieldSources,
                for (final key in changes.keys) key: address,
              },
            );
        TrackValue? current(TrackSlot slot) => active[slot]?.at(column);
        void close(TrackSlot slot) {
          final previous = active.remove(slot);
          final row = tracks.putIfAbsent(slot, () => []);
          if (previous != null && previous.start < column) {
            row.add(previous..end = column);
          }
        }

        void set(
          TrackKind kind,
          String label, {
          String id = '',
          String? field,
          EditCommand? state,
          TrackValue? updated,
        }) {
          final slot = (kind: kind, id: id);
          close(slot);
          if (label.isNotEmpty) {
            active[slot] = TrackSpan(
              slot,
              column,
              updated ?? value(label, field, state),
            );
          }
        }

        void clearKind(TrackKind kind) {
          for (final slot
              in active.keys.where((s) => s.kind == kind).toList()) {
            close(slot);
          }
        }

        switch (c.tag) {
          case 'background':
          case 'image':
            set(
              c.tag == 'background' ? TrackKind.background : TrackKind.cg,
              c.value('image'),
              field: 'image',
            );
          case 'backgroundtween':
          case 'imagetween':
            final kind = c.tag == 'backgroundtween'
                ? TrackKind.background
                : TrackKind.cg;
            final previous = current((kind: kind, id: ''));
            if (previous != null) {
              set(
                kind,
                previous.label,
                updated: update(previous, {
                  for (final key in ['x', 'y', 'xscale', 'yscale'])
                    if (c.args.containsKey('${key}to') ||
                        c.args.containsKey('${key}from'))
                      key: c.flag('loop')
                          ? c.value('${key}from', previous.command.value(key))
                          : c.value('${key}to', c.value('${key}from')),
                }),
              );
            }
          case 'charslot':
            final rawSlot = c.value('slot').trim().toLowerCase();
            final id = switch (rawSlot) {
              'left' || 'l' || 'char_left' => 'l',
              'middle' || 'm' || 'center' || 'c' || 'char_middle' => 'm',
              'right' || 'r' || 'char_right' => 'r',
              _ => '',
            };
            final name = c.value('name');
            if (rawSlot.isEmpty) {
              clearKind(TrackKind.character);
            } else if (id.isNotEmpty) {
              _focusChanges.add((column, c.value('focus', 'all')));
              final slot = (kind: TrackKind.character, id: id);
              final previous = current(slot);
              if (name == 'char_empty') {
                close(slot);
              } else if (name.isNotEmpty || previous != null) {
                final label = name.isEmpty ? previous!.label : name;
                final state = EditCommand('charslot', {
                  if (name.isEmpty) ...previous!.command.args,
                  ...c.args,
                  'slot': id,
                  'name': label,
                  if (c.args.containsKey('posfrom') &&
                      !c.args.containsKey('posto'))
                    'posto': '0,0',
                });
                final next = name.isEmpty
                    ? update(previous!, state.args)
                    : value(label, 'name', state);
                if (previous != null &&
                    characterTrackBase(previous.label) ==
                        characterTrackBase(label) &&
                    (name.isEmpty ||
                        previous.label != label ||
                        c.args.containsKey('posto') ||
                        c.args.containsKey('posfrom'))) {
                  active[slot]!.markers.add((column, next));
                } else {
                  set(
                    TrackKind.character,
                    label,
                    id: id,
                    field: 'name',
                    state: state,
                  );
                }
              }
            }
          case 'character':
            final first = c.value('name');
            final second = c.value('name2');
            final focus = switch (c.number('focus').toInt()) {
              0 => 'all',
              <= 1 => second.isEmpty ? 'm' : 'l',
              2 => 'r',
              _ => 'none',
            };
            _focusChanges.add((column, focus));
            for (final id in characters) {
              final field = id == 'r' ? 'name2' : 'name';
              final label = id == 'r'
                  ? second
                  : id == (second.isEmpty ? 'm' : 'l')
                  ? first
                  : '';
              set(
                TrackKind.character,
                label,
                id: id,
                field: field,
                state: EditCommand('charslot', {
                  'slot': id,
                  'name': label,
                  'bstart': c.value(
                    id == 'r' ? 'blackstart2' : 'blackstart',
                    '-1',
                  ),
                  'bend': c.value(id == 'r' ? 'blackend2' : 'blackend', '-1'),
                  'focus': focus,
                }),
              );
            }
          case 'playmusic':
            if (c.value('key').isNotEmpty) {
              set(TrackKind.music, c.value('key'), field: 'key');
            }
          case 'stopmusic':
            events.putIfAbsent((kind: TrackKind.music, id: ''), () => []).add((
              column,
              value('停止 BGM'),
            ));
            set(TrackKind.music, '');
          case 'musicvolume':
          case 'soundvolume':
            final channel = c.tag == 'musicvolume'
                ? 'music'
                : c.value('channel', c.value('key'));
            final slot = channel == 'music'
                ? (kind: TrackKind.music, id: '')
                : (kind: TrackKind.sound, id: channel);
            final previous = current(slot);
            if (previous != null) {
              set(
                slot.kind,
                previous.label,
                id: slot.id,
                updated: update(previous, {'volume': c.value('volume', '1')}),
              );
            }
          case 'playsound':
            final key = c.value('key');
            if (key.isEmpty) break;
            final channel = c.value('channel', key);
            if (channel == 'music') {
              set(TrackKind.music, key, field: 'key');
            } else if (c.flag('loop')) {
              set(TrackKind.sound, key, id: channel, field: 'key');
            } else {
              close((kind: TrackKind.sound, id: channel));
              events
                  .putIfAbsent((kind: TrackKind.sound, id: channel), () => [])
                  .add((column, value(key, 'key')));
            }
          case 'stopsound':
            final channel = c.value('channel', c.value('key'));
            if (channel.isEmpty) {
              events.putIfAbsent((kind: TrackKind.sound, id: ''), () => []).add(
                (column, value('停止全部音效')),
              );
              clearKind(TrackKind.sound);
            } else if (channel == 'music') {
              events.putIfAbsent((kind: TrackKind.music, id: ''), () => []).add(
                (column, value('停止 BGM')),
              );
              set(TrackKind.music, '');
            } else {
              final slot = (kind: TrackKind.sound, id: channel);
              events.putIfAbsent(slot, () => []).add((column, value('停止音效')));
              close(slot);
            }
          case 'bgeffect':
            final name = c.value('name');
            if (name.isEmpty && c.value('layer').trim().isEmpty) {
              clearKind(TrackKind.effect);
            } else {
              set(
                TrackKind.effect,
                name,
                id: '${c.number('layer').toInt()}',
                field: 'name',
              );
            }
          case 'blocker':
            final alpha = c.number('a', 1).clamp(0, 1);
            set(
              TrackKind.blocker,
              alpha > 0 ? '不透明度 ${(alpha * 100).round()}%' : '',
            );
          case 'subtitle':
            final label = c.value('text');
            final x = c.number('x'), y = c.number('y');
            if (label.isEmpty || (x >= 0 && x <= 1280 && y >= 0 && y <= 720)) {
              set(TrackKind.subtitle, label);
            }
          case 'dialogue':
          case 'dialog':
          case 'aside':
          case 'multiline':
          case 'endtip':
          case 'decision':
          case 'delay':
            ticks.add(
              TrackTick(
                column,
                switch (c.tag) {
                  'decision' => '选项 ${c.value('options')}',
                  'delay' => '等待 ${c.number('time')} 秒',
                  'endtip' => c.text.isEmpty ? '结束提示' : c.text,
                  _ => c.text.isEmpty ? '清除对白框' : c.text,
                },
                switch (c.tag) {
                  'dialogue' || 'dialog' || 'multiline' => c.value('name'),
                  _ => '',
                },
              ),
            );
        }
        column++;
      }
      beats.add((start, column));
    }
    for (final span in active.values) {
      _outgoing[span.slot] = span.at(column);
      if (span.start < column) {
        tracks.putIfAbsent(span.slot, () => []).add(span..end = column);
      }
    }
    _globalEnd = global;
  }
}

EditCommand settledTrackCommand(EditCommand command) {
  final args = {...command.args};
  for (final key in [
    'fadetime',
    'crossfade',
    'delay',
    'duration',
    'isblock',
    'block',
    'posfrom',
  ]) {
    args.remove(key);
  }
  if (command.tag == 'character') args['fadetime'] = '0';
  if (command.tag == 'charslot' && args['action'] != 'zoom') {
    args.remove('action');
  }
  return EditCommand(command.tag, args);
}

String characterTrackBase(String value) =>
    value.split(RegExp(r'[#@$]')).first.toLowerCase();

EditCommand? clearTrack(TrackSlot slot) => switch (slot.kind) {
  TrackKind.background => const EditCommand('background', {'image': ''}),
  TrackKind.cg => const EditCommand('image', {'image': ''}),
  TrackKind.character => EditCommand('charslot', {
    'slot': slot.id,
    'name': 'char_empty',
  }),
  TrackKind.subtitle => const EditCommand('subtitle', {'text': ''}),
  TrackKind.music => const EditCommand('stopmusic'),
  TrackKind.sound when slot.id.isNotEmpty => EditCommand('stopsound', {
    'channel': slot.id,
  }),
  TrackKind.effect => EditCommand('bgeffect', {'layer': slot.id, 'name': ''}),
  TrackKind.blocker => const EditCommand('blocker', {'a': '0'}),
  _ => null,
};

EditCommand? trackMaterialCommand(TrackSlot slot, String key) =>
    switch (slot.kind) {
      TrackKind.background => EditCommand('background', {'image': key}),
      TrackKind.cg => EditCommand('image', {'image': key}),
      TrackKind.character => EditCommand('charslot', {
        'slot': slot.id,
        'name': key,
      }),
      TrackKind.music => EditCommand('playmusic', {'key': key}),
      _ => null,
    };
