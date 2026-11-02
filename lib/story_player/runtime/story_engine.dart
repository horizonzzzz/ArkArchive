import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';

import '../script.dart';
import '../stage_state.dart';
import 'story_audio.dart';

typedef CommandHandler = Future<void> Function(StoryCommand command);

class _Animation {
  _Animation(this.duration, this.update);
  final double duration;
  final void Function(double) update;
  double elapsed = 0;
  final done = Completer<void>();
}

/// 指令和可见状态分离；所有等待都能由重播或 dispose 取消。
class StoryEngine extends ChangeNotifier {
  StoryEngine(
    this.script, {
    StoryAudio? audio,
    this.elapsed,
    this.variables = const {},
    this.typingInterval = const Duration(milliseconds: 40),
  }) : audio = audio ?? SilentStoryAudio() {
    _registerBuiltins();
    _clock.start();
    _ticker = Timer.periodic(const Duration(milliseconds: 16), (_) => _tick());
  }
  final StoryScript script;
  final StoryAudio audio;
  final Map<String, dynamic> variables;
  final Duration typingInterval;
  final Duration Function()? elapsed;
  final Map<String, CommandHandler> handlers = {};
  final List<String> warnings = [];
  final Map<String, _Animation> _animations = {};
  final Stopwatch _clock = Stopwatch();
  late final Timer _ticker;
  StageState state = StageState();
  int cursor = 0, _epoch = 0, _lastTick = 0;
  double _typingTime = 0, _autoTime = 0;
  bool running = false,
      finished = false,
      paused = false,
      autoPlay = false,
      _disposed = false;
  String _selection = '';
  Set<String> _predicates = {};
  int get totalCharacters => plainText(state.text).runes.length;
  bool get typing => state.dialogueVisible && state.revealed < totalCharacters;

  String translate(String text) => text.replaceAllMapped(
    RegExp(r'\{@([^}]+)\}'),
    (m) => m[1] == 'nickname' ? '博士' : variables[m[1]]?.toString() ?? m[0]!,
  );
  static String plainText(String text) => text
      .replaceAll(
        RegExp(r'</?(?:color|b|i|size)(?:=[^>]*)?>', caseSensitive: false),
        '',
      )
      .replaceAll(r'\n', '\n');

  void register(String tag, CommandHandler handler) =>
      handlers[tag.toLowerCase()] = handler;
  void warn(String text) {
    if (!warnings.contains(text)) warnings.add(text);
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  void _tick() {
    final now = elapsed?.call().inMicroseconds ?? _clock.elapsedMicroseconds;
    final dt = (now - _lastTick) / 1000;
    _lastTick = now;
    if (paused || _disposed) return;
    var changed = false;
    for (final entry in _animations.entries.toList()) {
      final a = entry.value;
      a.elapsed += dt;
      final t = (a.elapsed / a.duration).clamp(0.0, 1.0);
      a.update(t);
      changed = true;
      if (t >= 1 && identical(_animations[entry.key], a)) {
        _animations.remove(entry.key);
        if (!a.done.isCompleted) a.done.complete();
      }
    }
    if (typing) {
      _typingTime += dt;
      final count = typingInterval.inMicroseconds <= 0
          ? totalCharacters
          : (_typingTime * 1000 / typingInterval.inMicroseconds).floor();
      if (count != state.revealed) {
        state.revealed = math.min(count, totalCharacters);
        changed = true;
      }
    }
    if (autoPlay && !typing && !running && !finished && state.choices.isEmpty) {
      _autoTime += dt;
      if (_autoTime >= 1000 + totalCharacters * 20) {
        _autoTime = 0;
        unawaited(advance());
      }
    }
    if (changed) _changed();
  }

  Future<void> animate(
    String key,
    double seconds,
    void Function(double) update,
  ) {
    final previous = _animations.remove(key);
    if (previous != null && !previous.done.isCompleted) {
      previous.done.complete();
    }
    if (seconds <= 0) {
      update(1);
      _changed();
      return Future.value();
    }
    final a = _Animation(seconds * 1000, update);
    _animations[key] = a;
    update(0);
    _changed();
    return a.done.future;
  }

  void _cancelAnimations() {
    for (final a in _animations.values) {
      if (!a.done.isCompleted) a.done.complete();
    }
    _animations.clear();
  }

  Future<void> _transition(
    StoryCommand c,
    String key,
    double seconds,
    void Function(double) update, {
    String blockKey = 'block',
  }) async {
    final future = animate(key, seconds, update);
    if (c.flag(blockKey)) await future;
  }

  Future<void> start() => advance();
  Future<void> advance() async {
    if (_disposed || paused || running || finished || state.choices.isNotEmpty) {
      return;
    }
    if (typing) {
      state.revealed = totalCharacters;
      _changed();
      return;
    }
    if (cursor >= script.commands.length) {
      finished = true;
      state.dialogueVisible = false;
      _changed();
      return;
    }
    running = true;
    final epoch = _epoch;
    _autoTime = 0;
    _changed();
    try {
      while (!_disposed && epoch == _epoch && cursor < script.commands.length) {
        final c = script.commands[cursor++];
        if (c.tag != 'predicate' &&
            _predicates.isNotEmpty &&
            !_predicates.contains(_selection)) {
          continue;
        }
        if (c.tag == 'dialogue' ||
            (['dialog', 'aside', 'endtip'].contains(c.tag) &&
                c.text.isNotEmpty)) {
          state.speaker = translate(c.value('name'));
          state.text = translate(c.text).replaceAll(r'\n', '\n');
          state.revealed = 0;
          state.dialogueVisible = true;
          _typingTime = 0;
          state.history.add(DialogueLine(state.speaker, state.text, c.line));
          break;
        }
        final handler = handlers[c.tag];
        if (handler == null) {
          warn('第 ${c.line} 行：暂不支持 [${c.tag}]');
        } else {
          try {
            await handler(c);
          } catch (e) {
            warn('第 ${c.line} 行 [${c.tag}]：$e');
          }
        }
        if (epoch != _epoch || _disposed || state.choices.isNotEmpty) break;
      }
      if (epoch == _epoch &&
          cursor >= script.commands.length &&
          state.choices.isEmpty &&
          !state.dialogueVisible) {
        finished = true;
      }
    } finally {
      if (epoch == _epoch) {
        running = false;
        _changed();
      }
    }
  }

  Future<void> choose(String value) async {
    if (!state.choices.any((c) => c.value == value)) return;
    _selection = value;
    state.choices = [];
    await advance();
  }

  Future<void> restart() async {
    _epoch++;
    _cancelAnimations();
    state = StageState();
    cursor = 0;
    running = false;
    finished = false;
    _selection = '';
    _predicates = {};
    await audio.stop();
    if (!_disposed) {
      _changed();
      await advance();
    }
  }

  Future<void> setPaused(bool value) async {
    paused = value;
    if (value) {
      await audio.pause();
    } else {
      await audio.resume();
    }
    _changed();
  }

  void setAutoPlay(bool value) {
    autoPlay = value;
    _autoTime = 0;
    _changed();
  }

  String _slot(String value) => switch (value.trim().toLowerCase()) {
    'left' || 'l' || 'char_left' => 'l',
    'right' || 'r' || 'char_right' => 'r',
    'm' || 'middle' || 'center' || 'c' || 'char_middle' => 'm',
    _ => '',
  };
  Offset _point(String text, [Offset fallback = Offset.zero]) {
    final parts = text.split(',');
    if (parts.length != 2) return fallback;
    final x = double.tryParse(parts[0]), y = double.tryParse(parts[1]);
    return x != null && y != null && x.isFinite && y.isFinite
        ? Offset(x, y)
        : fallback;
  }

  double _lerp(double a, double b, double t) => a + (b - a) * t;

  void _registerBuiltins() {
    register('header', (_) async {});
    register('endtip', (_) async {
      state.dialogueVisible = false;
      finished = true;
    });
    for (final tag in ['dialog', 'aside']) {
      register(tag, (_) async {
        state.dialogueVisible = false;
      });
    }
    register('delay', (c) => animate('delay', c.number('time'), (_) {}));
    for (final tag in ['background', 'image']) {
      register(tag, _image);
    }
    for (final tag in ['backgroundtween', 'imagetween']) {
      register(tag, _imageTween);
    }
    register('blocker', _blocker);
    register('curtain', (c) async {
      if (!c.args.containsKey('direction')) {
        state.curtains.clear();
        return;
      }
      final direction = c.number('direction').toInt();
      final from = c.number('fillfrom', state.curtains[direction] ?? 1),
          to = c.number('fillto');
      await _transition(
        c,
        'curtain:$direction',
        c.number('fadetime', .4),
        (t) => state.curtains[direction] = _lerp(from, to, t),
      );
    });
    register('charslot', _characterSlot);
    register('character', _legacyCharacter);
    register('camerashake', (c) async {
      final xs = c.number('xstrength'), ys = c.number('ystrength');
      final vibration = c.number('vibrato', 10);
      await _transition(c, 'shake', c.number('duration'), (t) {
        final damping = c.flag('fadeout') ? 1 - t : 1.0;
        state.shake = t >= 1
            ? Offset.zero
            : Offset(
                    math.sin(t * vibration * math.pi * 2) * xs,
                    math.cos(t * vibration * math.pi * 2) * ys,
                  ) *
                  damping;
      });
    });
    for (final tag in [
      'playmusic',
      'stopmusic',
      'musicvolume',
      'playsound',
      'stopsound',
      'soundvolume',
    ]) {
      register(tag, audio.execute);
    }
    register('decision', (c) async {
      final options = c.value('options').split(';'),
          values = c.value('values').split(';');
      if (options.length != values.length || options.any((s) => s.isEmpty)) {
        throw const FormatException('选项和 values 数量不一致');
      }
      state.choices = List.generate(
        options.length,
        (i) => Choice(translate(options[i]), values[i]),
      );
    });
    register('predicate', (c) async {
      _predicates = c
          .value('references')
          .split(';')
          .where((s) => s.isNotEmpty)
          .toSet();
    });
    register('label', (_) async {});
    register('gotostage', (_) async {});
    register('warp', (c) async {
      final target = script.commands.indexWhere(
        (x) => x.tag == 'label' && x.value('name') == c.value('name'),
      );
      if (target < 0 || target < cursor) {
        warn('跳转目标不存在或形成循环：${c.value('name')}');
        return;
      }
      cursor = target + 1;
    });
    register('focusout', (c) async {
      final type = c.value('type');
      if (!['char', 'bg', 'cg'].contains(type)) {
        warn('未支持的 focusout 类型：$type');
        return;
      }
      final from = c.number('from', state.focus[type] ?? 0),
          to = c.number('to');
      await _transition(
        c,
        'focusout:$type',
        c.number('duration'),
        (t) => state.focus[type] = _lerp(from, to, t),
      );
    });
    register('interlude', _interlude);
    register('hidecgitem', (_) async {});
  }

  Future<void> _image(StoryCommand c) async {
    final layers = c.tag == 'image' ? state.images : state.backgrounds;
    final old = layers.toList();
    final key = c.value('image');
    final seconds = c.number('fadetime');
    final image = key.isEmpty
        ? null
        : StageImage(
            key,
            cg: c.tag == 'image',
            fit: c.value('screenadapt', 'coverall'),
          );
    if (image != null) {
      image.x = c.number('x');
      image.y = c.number('y');
      image.scaleX = c.number('xscale', 1);
      image.scaleY = c.number('yscale', 1);
      layers.add(image);
    }
    final epoch = _epoch;
    final future =
        animate(c.tag, seconds, (t) {
          if (image != null) {
            image.alpha = t;
          } else {
            for (final previous in old) {
              previous.alpha = 1 - t;
            }
          }
        }).then((_) {
          if (epoch == _epoch) {
            layers.removeWhere(old.contains);
            _changed();
          }
        });
    if (c.flag('block')) await future;
  }

  Future<void> _imageTween(StoryCommand c) async {
    final layers = c.tag == 'imagetween' ? state.images : state.backgrounds;
    if (layers.isEmpty) return;
    final image = layers.last;
    final xf = c.number('xfrom', image.x), yf = c.number('yfrom', image.y);
    final xt = c.number('xto', xf), yt = c.number('yto', yf);
    final sxf = c.number('xscalefrom', image.scaleX),
        syf = c.number('yscalefrom', image.scaleY);
    final sxt = c.number('xscaleto', sxf), syt = c.number('yscaleto', syf);
    await _transition(c, c.tag, c.number('duration'), (t) {
      image.x = _lerp(xf, xt, t);
      image.y = _lerp(yf, yt, t);
      image.scaleX = _lerp(sxf, sxt, t);
      image.scaleY = _lerp(syf, syt, t);
    });
    if (c.flag('loop')) warn('第 ${c.line} 行：尚未支持图片缓动 loop');
  }

  Future<void> _blocker(StoryCommand c) async {
    double color(String key) {
      final v = c.number(key);
      return (v > 1 ? v / 255 : v).clamp(0, 1);
    }

    state.blockerColor = Color.from(
      alpha: 1,
      red: color('r'),
      green: color('g'),
      blue: color('b'),
    );
    state.blockerStyle = c.value('style');
    state.blockerInverse = c.flag('inverse');
    final from = state.blockerAlpha, to = c.number('a').clamp(0.0, 1.0);
    await _transition(
      c,
      'blocker',
      c.number('fadetime'),
      (t) => state.blockerAlpha = _lerp(from, to, t),
    );
  }

  Future<void> _characterSlot(StoryCommand c) async {
    final slot = _slot(c.value('slot'));
    final seconds = c.number('duration');
    if (c.value('slot').isEmpty) {
      final old = state.characters.toList();
      final epoch = _epoch;
      final future =
          animate('clearCharacters', seconds, (t) {
            for (final node in old) {
              node.alpha = 1 - t;
            }
          }).then((_) {
            if (epoch == _epoch) state.characters.removeWhere(old.contains);
          });
      if (c.flag('isblock')) await future;
      return;
    }
    if (slot.isEmpty) {
      warn('第 ${c.line} 行：未知立绘槽位 ${c.value('slot')}');
      return;
    }
    final focus = c.value('focus', 'all');
    final focusSlots = focus == 'all'
        ? {'l', 'm', 'r'}
        : focus.split(',').map(_slot).toSet();
    for (final node in state.characters) {
      node.brightness = focusSlots.contains(node.slot) ? 1 : .5;
    }
    var nodes = state.characters.where((n) => n.slot == slot).toList();
    var node = nodes.isEmpty ? null : nodes.last;
    final name = c.value('name');
    if (name == 'char_empty') {
      state.characters.removeWhere((n) => n.slot == slot);
      return;
    }
    if (name.isNotEmpty) {
      final old = nodes;
      node = StageCharacter(slot, name)
        ..brightness = focusSlots.contains(slot) ? 1 : .5;
      state.characters.add(node);
      final next = node;
      final epoch = _epoch;
      final fade =
          animate('character:$slot', seconds, (t) {
            next.alpha = t;
            for (final previous in old) {
              previous.alpha = 1 - t;
            }
          }).then((_) {
            if (epoch == _epoch) state.characters.removeWhere(old.contains);
          });
      if (c.flag('isblock') && c.value('end') != 'false') await fade;
    }
    if (node == null) return;
    final target = node;
    final from = _point(c.value('posfrom'), Offset(node.x, node.y)),
        to = _point(c.value('posto'), from);
    final sx = c.number('xscale', c.number('scale', node.scaleX)),
        sy = c.number('yscale', c.number('scale', node.scaleY));
    final oldX = node.scaleX, oldY = node.scaleY;
    final alphaFrom = c.number('afrom', node.alpha),
        alphaTo = c.number('ato', alphaFrom);
    if (c.args.keys.any(
      [
        'posfrom',
        'posto',
        'scale',
        'xscale',
        'yscale',
        'afrom',
        'ato',
        'angle',
      ].contains,
    )) {
      await _transition(
        c,
        'characterMotion:$slot',
        c.value('action') == 'setpos' ? 0 : seconds,
        (t) {
          target.x = _lerp(from.dx, to.dx, t);
          target.y = _lerp(from.dy, to.dy, t);
          target.scaleX = _lerp(oldX, sx, t);
          target.scaleY = _lerp(oldY, sy, t);
          if (c.args.containsKey('ato')) {
            target.alpha = _lerp(alphaFrom, alphaTo, t);
          }
          if (c.args.containsKey('angle')) {
            target.angle = c.number('angle') * math.pi / 180 * t;
          }
        },
        blockKey: 'isblock',
      );
    }
  }

  Future<void> _legacyCharacter(StoryCommand c) async {
    final first = c.value('name'), second = c.value('name2');
    if (first.isEmpty && second.isEmpty) {
      await _characterSlot(
        StoryCommand(
          'charslot',
          {'duration': c.value('fadetime', '0.15')},
          '',
          c.line,
          c.raw,
        ),
      );
      return;
    }
    state.characters.removeWhere(
      (n) => second.isEmpty ? n.slot != 'm' : n.slot == 'm',
    );
    final focus = c.number('focus').toInt();
    for (final entry in [(second.isEmpty ? 'm' : 'l', first), ('r', second)]) {
      if (entry.$2.isEmpty) {
        continue;
      }
      await _characterSlot(
        StoryCommand(
          'charslot',
          {
            'slot': entry.$1,
            'name': entry.$2,
            'duration': c.value('fadetime', '0.15'),
          },
          '',
          c.line,
          c.raw,
        ),
      );
    }
    for (final node in state.characters) {
      node.brightness =
          focus == 0 ||
              (focus == 1 && node.slot != 'r') ||
              (focus == 2 && node.slot == 'r')
          ? 1
          : .5;
    }
  }

  Future<void> _interlude(StoryCommand c) async {
    final clear = c.flag('clear');
    final channel = c.value('channel', '0');
    final frame = state.interludes.putIfAbsent(
      channel,
      () => InterludeFrame(channel),
    );
    final size = _point(
      c.value('size'),
      Offset(frame.size.width, frame.size.height),
    );
    frame.size = Size(size.dx, size.dy);
    frame.offset = _point(c.value('offset'), frame.offset);
    if (c.value('name').isNotEmpty) frame.avatar = c.value('name');
    if (c.args.containsKey('switch')) frame.visible = c.flag('switch');
    final from = _point(c.value('tsfrom'), frame.scale),
        to = _point(c.value('tsto'), from);
    await _transition(
      c,
      'interlude:$channel',
      c.number('tsduration', c.number('duration')),
      (t) {
        frame.scale = Offset.lerp(from, to, t)!;
      },
    );
    if (clear) state.interludes.remove(channel);
    warn('interlude 的遮罩边缘与角色裁切仍待游戏画面对齐');
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    _ticker.cancel();
    _cancelAnimations();
    _clock.stop();
    unawaited(audio.dispose());
    super.dispose();
  }
}
