import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/foundation.dart';

import '../script.dart';
import '../stage_state.dart';
import 'story_audio.dart';

typedef CommandHandler = Future<void> Function(StoryCommand command);

/// 播放速度档位；数值与参考端 button_auto / quick_play 的档位逐项一致。
class PlaySpeed {
  const PlaySpeed({
    required this.typingMs,
    required this.animateRatio,
    required this.autoWaitBase,
    required this.autoWaitPerChar,
  });
  final double typingMs;
  final double animateRatio;
  final double autoWaitBase;
  final double autoWaitPerChar;
}

const buttonSpeeds = [
  PlaySpeed(typingMs: 40, animateRatio: 1, autoWaitBase: 1.5, autoWaitPerChar: .03),
  PlaySpeed(typingMs: 10, animateRatio: 1, autoWaitBase: .5, autoWaitPerChar: .015),
  PlaySpeed(typingMs: 10, animateRatio: 1, autoWaitBase: .25, autoWaitPerChar: .01),
];

const quickSpeeds = [
  PlaySpeed(typingMs: 10, animateRatio: 0, autoWaitBase: .2, autoWaitPerChar: 0),
  PlaySpeed(typingMs: 5, animateRatio: 0, autoWaitBase: .1, autoWaitPerChar: 0),
  PlaySpeed(typingMs: 2.5, animateRatio: 0, autoWaitBase: .05, autoWaitPerChar: 0),
  PlaySpeed(typingMs: 1.25, animateRatio: 0, autoWaitBase: .025, autoWaitPerChar: 0),
];

/// 默认打字间隔（毫秒），参考端以 40ms 为基准换算贴纸与 multiline 的 delay 参数。
const baseTypingMs = 40.0;

class _Animation {
  _Animation(this.durationMs, this.update, {this.loop = false, double delayMs = 0})
      : elapsed = -delayMs;
  final double durationMs;
  final void Function(double) update;
  final bool loop;
  double elapsed;
  final done = Completer<void>();
}

/// 镜头或立绘震动的随机折线；复刻参考端 hr/gr 的分段算法。
class ShakePath {
  ShakePath(this.segments);
  final List<({double ratio, double x, double y})> segments;

  Offset at(double t) {
    final c = t.clamp(0.0, 1.0);
    var start = 0.0, x = 0.0, y = 0.0;
    for (final seg in segments) {
      final end = start + seg.ratio;
      if (c <= end || identical(seg, segments.last)) {
        final local = seg.ratio > 0 ? ((c - start) / seg.ratio).clamp(0.0, 1.0) : 1.0;
        return Offset(x + (seg.x - x) * local, y + (seg.y - y) * local);
      }
      start = end;
      x = seg.x;
      y = seg.y;
    }
    return Offset.zero;
  }
}

ShakePath buildShakePath({
  required double durationMs,
  required double vibrato,
  required double randomness,
  required double xStrength,
  required double yStrength,
  required bool fadeOut,
  bool vectorBased = true,
  math.Random? random,
}) {
  final rng = random ?? math.Random();
  final seconds = math.max(0, durationMs) / 1000;
  final count = math.max(2, (math.max(0, vibrato) * seconds).truncate());
  final rand = math.max(0.0, randomness);
  double rr(double a, double b) => a + (b - a) * rng.nextDouble();
  final strengths = List.generate(count, (i) => fadeOut ? i + 1.0 : 1.0);
  final total = strengths.fold<double>(0, (a, b) => a + b);
  var angle = rr(0, 360);
  Offset clamp3(Offset v, double max) {
    final n = v.distance;
    if (n <= max || n <= 1e-5) return v;
    return v / n * max;
  }

  final segments = <({double ratio, double x, double y})>[];
  for (var r = 0; r < count; r++) {
    final weight = strengths[r];
    if (r == count - 1) {
      segments.add((ratio: weight / total, x: 0, y: 0));
      continue;
    }
    if (r > 0) angle = angle - 180 + rr(-rand, rand);
    final theta = angle * math.pi / 180;
    final phi = rr(-rand, rand) * math.pi / 180;
    final d = math.cos(theta);
    final f = Offset(d * xStrength * math.cos(phi), math.sin(theta) * xStrength);
    final damp = fadeOut ? 1 - r / count : 1.0;
    if (!vectorBased) {
      segments.add((ratio: weight / total, x: f.dx * damp, y: f.dy * damp));
      continue;
    }
    final m = clamp3(f, xStrength);
    final h = clamp3(Offset(m.dx, f.dy), yStrength);
    final n = Offset(m.dx, h.dy).distance;
    final dir = n <= 1e-5 ? Offset.zero : Offset(m.dx / n, h.dy / n);
    segments.add((ratio: weight / total, x: dir.dx * xStrength * damp, y: dir.dy * xStrength * damp));
  }
  return ShakePath(segments);
}

/// 命名缓动，与参考端 V 目录同名同式；未知名字回退 OutQuad。
double applyEase(String? name, double t) {
  final x = t.clamp(0.0, 1.0);
  double i;
  switch (name?.trim()) {
    case null:
    case '':
    case 'Linear':
      i = x;
    case 'OutQuad':
      i = 1 - (1 - x) * (1 - x);
    case 'InQuad':
      i = x * x;
    case 'InOutQuad':
      i = x < .5 ? 2 * x * x : 1 - (-2 * x + 2) * (-2 * x + 2) / 2;
    case 'InCubic':
      i = x * x * x;
    case 'OutCubic':
      i = 1 - (1 - x) * (1 - x) * (1 - x);
    case 'InOutCubic':
      i = x < .5 ? 4 * x * x * x : 1 - (-2 * x + 2) * (-2 * x + 2) * (-2 * x + 2) / 2;
    case 'InSine':
      i = 1 - math.cos(x * math.pi / 2);
    case 'OutSine':
      i = math.sin(x * math.pi / 2);
    case 'InOutSine':
      i = -(math.cos(math.pi * x) - 1) / 2;
    case 'InQuart':
      i = x * x * x * x;
    case 'OutQuart':
      i = 1 - (1 - x) * (1 - x) * (1 - x) * (1 - x);
    case 'InOutQuart':
      i = x < .5 ? 8 * x * x * x * x : 1 - (-2 * x + 2) * (-2 * x + 2) * (-2 * x + 2) * (-2 * x + 2) / 2;
    case 'InQuint':
      i = x * x * x * x * x;
    case 'OutQuint':
      i = 1 - (1 - x) * (1 - x) * (1 - x) * (1 - x) * (1 - x);
    case 'InOutQuint':
      i = x < .5
          ? 16 * x * x * x * x * x
          : 1 - (-2 * x + 2) * (-2 * x + 2) * (-2 * x + 2) * (-2 * x + 2) * (-2 * x + 2) / 2;
    case 'InExpo':
      i = x == 0 ? 0 : math.pow(2, 10 * x - 10).toDouble();
    case 'OutExpo':
      i = x == 1 ? 1 : 1 - math.pow(2, -10 * x).toDouble();
    case 'InOutExpo':
      i = x == 0
          ? 0
          : x == 1
          ? 1
          : x < .5
          ? math.pow(2, 20 * x - 10) / 2
          : (2 - math.pow(2, -20 * x + 10)) / 2;
    case 'InCirc':
      i = 1 - math.sqrt(1 - x * x);
    case 'OutCirc':
      i = math.sqrt(1 - (x - 1) * (x - 1));
    case 'InOutCirc':
      i = x < .5
          ? (1 - math.sqrt(1 - (2 * x) * (2 * x))) / 2
          : (math.sqrt(1 - (-2 * x + 2) * (-2 * x + 2)) + 1) / 2;
    case 'InBounce':
      i = 1 - _outBounce(1 - x);
    case 'OutBounce':
      i = _outBounce(x);
    case 'InOutBounce':
      i = x < .5 ? (1 - _outBounce(1 - 2 * x)) / 2 : (1 + _outBounce(2 * x - 1)) / 2;
    case 'InBack':
      i = 2.70158 * x * x * x - 1.70158 * x * x;
    case 'OutBack':
      i = 1 + 2.70158 * (x - 1) * (x - 1) * (x - 1) + 1.70158 * (x - 1) * (x - 1);
    case 'Flash':
      i = x;
    case 'InFlash':
      i = x * x;
    case 'OutFlash':
      i = -x * (x - 2);
    case 'InOutFlash':
      i = x < .5 ? 2 * x * x : 1 - (-2 * x + 2) * (-2 * x + 2) / 2;
    default:
      i = 1 - (1 - x) * (1 - x);
  }
  return i.clamp(0.0, 1.0);
}

double _outBounce(double x) {
  const n = 2.75;
  if (x < 1 / n) return 7.5625 * x * x;
  if (x < 2 / n) {
    final e = x - 1.5 / n;
    return 7.5625 * e * e + .75;
  }
  if (x < 2.5 / n) {
    final e = x - 2.25 / n;
    return 7.5625 * e * e + .9375;
  }
  final e = x - 2.625 / n;
  return 7.5625 * e * e + .984375;
}

double _lerp(double a, double b, double t) => a + (b - a) * t;
double _easeOutCubic(double t) => 1 - (1 - t) * (1 - t) * (1 - t);
double _easeOutQuad(double t) => 1 - (1 - t) * (1 - t);
double _smoothstep(double t) => t * t * (3 - 2 * t);

class _Motion {
  ShakePath? shake;
  double shakeStartUs = -1, shakeDurationMs = 0;
  double jumpStartUs = -1, jumpPower = 0, jumpCycle = 1, jumpDurationMs = 0;
}

class _StickerStep {
  _StickerStep(this.kind, this.durationMs, this.join, this.fromPos, this.toPos, {this.from = 0, this.to = 0});
  final String kind; // position | rotation | alpha
  final double durationMs;
  final bool join;
  final Offset? fromPos, toPos;
  final double from, to;
}

/// 指令与可见状态分离；所有等待都能由重播或 dispose 取消。
/// 指令语义对齐 PRTS 生产播放器 StoryPlayer.DH9HUkmm.js（2026-11-03 审计版）。
class StoryEngine extends ChangeNotifier {
  StoryEngine(
    this.script, {
    StoryAudio? audio,
    this.elapsed,
    this.variables = const {},
    this.typingInterval = const Duration(milliseconds: 40),
    this.autoWaitSeconds,
    this.firstRead = true,
    this.characterArtSize,
    this.imageNaturalWidth,
  }) : audio = audio ?? SilentStoryAudio() {
    defaultSpeed = PlaySpeed(
      typingMs: typingInterval.inMicroseconds / 1000,
      animateRatio: 1,
      autoWaitBase: 1.5,
      autoWaitPerChar: .03,
    );
    _parseHeader();
    _collectSkipNodes();
    _registerBuiltins();
    _clock.start();
    _ticker = Timer.periodic(const Duration(milliseconds: 16), (_) => _tick());
  }

  final StoryScript script;
  final StoryAudio audio;
  final Map<String, dynamic> variables;
  final Duration typingInterval;
  final double? autoWaitSeconds;
  final Duration Function()? elapsed;
  final bool firstRead;
  /// 从 character.json 读取立绘标称尺寸，供 zoom 轴心位移计算。
  final Offset? Function(String name)? characterArtSize;
  /// 图片原始宽度（像素），供 showitem cutin 窗口缺省宽度计算（参考端回退 100）。
  final double? Function(String image)? imageNaturalWidth;
  final Map<String, CommandHandler> handlers = {};
  final List<String> warnings = [];
  final Map<String, _Animation> _animations = {};
  final Stopwatch _clock = Stopwatch();
  late final Timer _ticker;
  late final PlaySpeed defaultSpeed;
  final math.Random _random = math.Random();
  final Map<String, _Motion> _motions = {};
  final Map<String, List<_StickerStep>> _stickerTweens = {};
  final Map<String, double> _slotDeadlines = {};

  StageState state = StageState();
  int cursor = 0, _epoch = 0;
  double _lastTick = 0, _typingTime = 0, _typingScale = 1, _autoClickAt = -1;
  bool running = false,
      finished = false,
      paused = false,
      _disposed = false,
      _waitingInput = false;
  String autoMode = 'default';
  int speedLevel = 0;
  bool theaterMode = false;
  String _theaterRestore = 'default';
  int _theaterRestoreLevel = 0;

  // 分支状态：selectedValue 为 0（未选择）时放行全部行。
  int _selectedValue = 0;
  Set<int>? _predicates;
  List<int> _decisionValues = const [];

  // multiline 续接状态。
  String? _overlayLogSource;
  String _multilineName = '', _multilineText = '';
  bool _multilineEnd = false, _multilineLogged = false;
  int _multilineShownChars = 0;

  // 跳过节点。
  final List<({int index, String mode})> _skipNodes = [];
  int _skipNodeIndex = 0;
  String _currentSkipMode = 'skip';
  int _skipToIndex = -1;

  // 镜头震动。
  ShakePath? _shakePath;
  double _shakeStartUs = 0, _shakeDurationMs = 0;
  bool _shakeInfinite = false;
  Completer<void>? _shakeWaiter;
  bool _itemSlotInUse = false;

  int get totalCharacters => plainText(state.text).runes.length;
  bool get typing => state.dialogueVisible && state.revealed < totalCharacters;
  bool get waitingInput => _waitingInput;

  PlaySpeed get currentSpeed => switch (autoMode) {
    'button_auto' when autoWaitSeconds != null => PlaySpeed(
      typingMs: typingInterval.inMicroseconds / 1000 * buttonSpeeds[math.min(speedLevel, buttonSpeeds.length - 1)].typingMs / 40,
      animateRatio: 1,
      autoWaitBase: autoWaitSeconds! * buttonSpeeds[math.min(speedLevel, buttonSpeeds.length - 1)].autoWaitBase / 1.5,
      autoWaitPerChar: 0,
    ),
    'button_auto' => buttonSpeeds[math.min(speedLevel, buttonSpeeds.length - 1)],
    'quick_play' => quickSpeeds[math.min(speedLevel, quickSpeeds.length - 1)],
    _ => defaultSpeed,
  };

  double _nowUs() => (elapsed?.call().inMicroseconds ?? _clock.elapsedMicroseconds) + .0;
  double scaled(double seconds) => seconds * currentSpeed.animateRatio;

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

  String _slot(String value) => switch (value.trim().toLowerCase()) {
    'left' || 'l' || 'char_left' => 'l',
    'right' || 'r' || 'char_right' => 'r',
    'm' || 'middle' || 'center' || 'c' || 'char_middle' => 'm',
    _ => '',
  };

  Offset _point(String text, [Offset? fallback]) {
    final parts = text.split(',');
    if (parts.length != 2) return fallback ?? Offset.zero;
    final x = double.tryParse(parts[0].trim()), y = double.tryParse(parts[1].trim());
    return x != null && y != null && x.isFinite && y.isFinite ? Offset(x, y) : fallback ?? Offset.zero;
  }

  bool _hasPoint(String text) {
    final parts = text.split(',');
    if (parts.length != 2) return false;
    return double.tryParse(parts[0].trim()) != null && double.tryParse(parts[1].trim()) != null;
  }

  List<double> _numbers(String text) => text
      .split('/')
      .map((s) => double.tryParse(s.trim().replaceAll(',', '')))
      .whereType<double>()
      .toList();

  /// 解析 "r,g,b,a"（0~1 浮点），与参考端 ha 一致。
  (double, double, double, double)? _color(String text) {
    final parts = text.split(',');
    if (parts.length != 4) return null;
    final values = parts.map((s) => double.tryParse(s.trim()) ?? 1).toList();
    return (values[0], values[1], values[2], values[3]);
  }

  void _parseHeader() {
    for (final c in script.commands) {
      if (c.tag != 'header') continue;
      const fitModes = {0: 'DEFAULT', 1: 'BLACK_MASK'};
      var fit = c.value('fit_mode', 'DEFAULT').toUpperCase();
      final numeric = int.tryParse(fit);
      if (numeric != null && fitModes.containsKey(numeric)) fit = fitModes[numeric]!;
      final tutorial = c.flag('is_tutorial');
      final videoOnly = c.flag('is_video_only');
      final skippableArg = c.args['is_skippable'];
      final autoableArg = c.args['is_autoable'];
      state.metadata = HeaderMeta(
        fitMode: fit == 'BLACK_MASK' ? 'BLACK_MASK' : 'DEFAULT',
        title: c.text,
        isTutorial: tutorial,
        isVideoOnly: videoOnly,
        isSkippable: skippableArg == null ? !tutorial : c.flag('is_skippable', true),
        isAutoable: autoableArg == null ? !tutorial && !videoOnly : c.flag('is_autoable', true),
      );
      break;
    }
  }

  void _collectSkipNodes() {
    for (var i = 0; i < script.commands.length; i++) {
      final c = script.commands[i];
      if (c.tag == 'skipnode') {
        _skipNodes.add((index: i, mode: c.value('mode') == 'nofirstskip' ? 'nofirstskip' : 'skip'));
      } else if (c.tag == 'skiptothis' && _skipToIndex < 0) {
        _skipToIndex = i;
      }
    }
  }

  bool get canSkipNode {
    final active = !finished;
    final hasNode = _skipToIndex >= 0 || _skipNodes.isNotEmpty;
    final beforeTarget = _skipToIndex < 0 || cursor <= _skipToIndex;
    final allowed = state.metadata.isSkippable && (_currentSkipMode != 'nofirstskip' || firstRead);
    return active && hasNode && beforeTarget && allowed;
  }

  void _tick() {
    final now = _nowUs();
    final dt = (now - _lastTick) / 1000;
    _lastTick = now;
    if (paused || _disposed) return;
    var changed = false;
    for (final entry in _animations.entries.toList()) {
      final a = entry.value;
      a.elapsed += dt;
      if (a.elapsed < 0) continue;
      final progress = a.elapsed / a.durationMs;
      final t = a.loop ? progress % 1 : progress.clamp(0.0, 1.0);
      a.update(t);
      changed = true;
      if (!a.loop && t >= 1 && identical(_animations[entry.key], a)) {
        _animations.remove(entry.key);
        if (!a.done.isCompleted) a.done.complete();
      }
    }
    if (typing) {
      _typingTime += dt;
      final interval = math.max(0, currentSpeed.typingMs * _typingScale);
      final count = interval <= 0 ? totalCharacters : (_typingTime / interval).floor();
      if (count != state.revealed) {
        state.revealed = math.min(count, totalCharacters);
        changed = true;
      }
    }
    final overlays = [state.subtitle, ...state.stickers.values];
    for (final overlay in overlays) {
      if (overlay == null || !overlay.visible) continue;
      final total = plainText(overlay.text).runes.length;
      if (overlay.revealed >= total) continue;
      overlay.typingTime += dt;
      final count = overlay.typingMs <= 0 ? total : (overlay.typingTime / overlay.typingMs).floor();
      final revealed = math.min(count, total);
      if (revealed != overlay.revealed) {
        overlay.revealed = revealed;
        changed = true;
      }
    }
    final timer = state.timer;
    if (timer != null && timer.visible && timer.startMicros >= 0) {
      final seconds = ((now - timer.startMicros) / 1e6).floor();
      final clamped = timer.limitSeconds >= 0 ? math.min(seconds, timer.limitSeconds) : seconds;
      if (clamped != timer.elapsedSeconds) {
        timer.elapsedSeconds = clamped;
        changed = true;
      }
    }
    for (final stamp in state.stamps) {
      if (stamp.elapsedMs < 5000) {
        stamp.elapsedMs += dt;
        changed = true;
      }
    }
    if (_shakePath != null) {
      final raw = _shakeDurationMs <= 0 ? 1.0 : (now - _shakeStartUs) / 1000 / _shakeDurationMs;
      state.shake = _shakePath!.at(_shakeInfinite ? raw % 1.0 : raw.clamp(0.0, 1.0));
      changed = true;
      if (!_shakeInfinite && (now - _shakeStartUs) / 1000 >= _shakeDurationMs) {
        state.shake = Offset.zero;
        _shakePath = null;
        _shakeWaiter?.complete();
        _shakeWaiter = null;
      }
    }
    if (_tickMotions(now)) changed = true;
    if (_waitingInput &&
        !typing &&
        !overlays.any((o) => o != null && o.visible && o.revealed < plainText(o.text).runes.length) &&
        !running &&
        !finished &&
        state.choices.isEmpty &&
        autoMode != 'default') {
      if (_autoClickAt < 0) {
        _autoClickAt =
            now + (currentSpeed.autoWaitBase + plainText(state.text).length * currentSpeed.autoWaitPerChar) * 1e6;
      } else if (now >= _autoClickAt) {
        _autoClickAt = -1;
        unawaited(advance());
      }
    } else {
      _autoClickAt = -1;
    }
    if (changed) _changed();
  }

  /// 立绘跳跃与抖动按各自轨迹推进；返回是否有可见变化。
  bool _tickMotions(double nowUs) {
    var changed = false;
    for (final entry in _motions.entries.toList()) {
      final slot = entry.key;
      final motion = entry.value;
      final node = state.characters.lastWhereOrNull((n) => n.slot == slot);
      if (node == null) {
        _motions.remove(slot);
        continue;
      }
      final shake = motion.shake;
      if (shake != null) {
        final t = motion.shakeDurationMs <= 0 ? 1.0 : (nowUs - motion.shakeStartUs) / 1000 / motion.shakeDurationMs;
        if (t >= 1) {
          node.shakeOffsetX = 0;
          node.shakeOffsetY = 0;
          motion.shake = null;
        } else {
          final o = shake.at(t);
          node.shakeOffsetX = o.dx;
          node.shakeOffsetY = -o.dy;
        }
        changed = true;
      }
      if (motion.jumpStartUs >= 0) {
        final t = motion.jumpDurationMs <= 0 ? 1.0 : (nowUs - motion.jumpStartUs) / 1000 / motion.jumpDurationMs;
        if (t >= 1) {
          node.jumpOffsetY = 0;
          motion.jumpStartUs = -1;
        } else {
          final r = math.min(_easeOutCubic(t), 1) / motion.jumpCycle;
          final o = r.floorToDouble();
          final s = r - o;
          node.jumpOffsetY = motion.jumpPower * (o % 2 == 0 ? _easeOutQuad(s) : _easeOutQuad(1 - s));
        }
        changed = true;
      }
    }
    return changed;
  }

  void _startShake(String slot, double durationMs, double power, double times, double randomness, {bool stop = false}) {
    final node = state.characters.lastWhereOrNull((n) => n.slot == slot);
    final motion = _motions[slot] ??= _Motion();
    if (stop || node == null) {
      motion.shake = null;
      if (node != null) {
        node.shakeOffsetX = 0;
        node.shakeOffsetY = 0;
      }
      return;
    }
    motion.shake = buildShakePath(
      durationMs: durationMs,
      vibrato: times,
      randomness: randomness,
      xStrength: power,
      yStrength: power,
      fadeOut: true,
      vectorBased: false,
      random: _random,
    );
    motion.shakeStartUs = _nowUs();
    motion.shakeDurationMs = durationMs;
  }

  void _startJump(String slot, double power, double times, double durationMs) {
    final node = state.characters.lastWhereOrNull((n) => n.slot == slot);
    final motion = _motions[slot] ??= _Motion();
    if (node == null) return;
    node.jumpOffsetY = 0;
    if (durationMs <= 0) return;
    motion.jumpStartUs = _nowUs();
    motion.jumpPower = power;
    motion.jumpCycle = 1 / (math.max(1, times) * 2);
    motion.jumpDurationMs = durationMs;
  }

  void _resetMotions() {
    _motions.clear();
    for (final node in state.characters) {
      node.shakeOffsetX = 0;
      node.shakeOffsetY = 0;
      node.jumpOffsetY = 0;
    }
  }

  Future<void> animate(
    String key, double seconds, void Function(double) update, {
    String? ease, bool loop = false, double delay = 0,
  }) {
    final previous = _animations.remove(key);
    if (previous != null && !previous.done.isCompleted) previous.done.complete();
    if (_disposed) return Future.value();
    if (seconds <= 0) {
      update(applyEase(ease, 1));
      _changed();
      return Future.value();
    }
    final a = _Animation(seconds * 1000, (t) => update(applyEase(ease, t)),
        loop: loop, delayMs: math.max(0, delay) * 1000);
    _animations[key] = a;
    update(applyEase(ease, 0));
    _changed();
    return a.done.future;
  }

  void _cancelAnimation(String key) {
    final animation = _animations.remove(key);
    if (animation != null && !animation.done.isCompleted) animation.done.complete();
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
    String? ease,
  }) async {
    final future = animate(key, seconds, update, ease: ease);
    if (c.flag(blockKey)) await future;
  }

  Future<void> start() async {
    if (state.metadata.isVideoOnly) {
      finished = true;
      _waitingInput = false;
      _changed();
      return;
    }
    await advance();
  }

  Future<void> advance() async {
    if (_disposed || paused || running || finished || state.choices.isNotEmpty) {
      return;
    }
    if (typing) {
      state.revealed = totalCharacters;
      if (_multilineEnd) _resetMultiline();
      _autoClickAt = -1;
      _changed();
      return;
    }
    if (_completeOverlayTyping()) {
      _autoClickAt = -1;
      _changed();
      return;
    }
    if (cursor >= script.commands.length) {
      _finishCleanup();
      finished = true;
      state.dialogueVisible = false;
      _waitingInput = false;
      _changed();
      return;
    }
    running = true;
    _waitingInput = false;
    final epoch = _epoch;
    _autoClickAt = -1;
    _changed();
    try {
      while (!_disposed && epoch == _epoch && cursor < script.commands.length) {
        final c = script.commands[cursor++];
        if (c.tag != 'predicate' && !_predicateActive()) {
          continue;
        }
        if (c.tag == 'multiline') {
          _runMultiline(c);
          if (_waitingInput) break;
          continue;
        }
        if (c.tag == 'dialogue' || c.tag == 'dialog' || c.tag == 'aside') {
          if (c.text.isEmpty) {
            state.dialogueVisible = false;
            continue;
          }
          _flushMultiline();
          _showDialogue(
            c.tag == 'aside' ? '' : c.value('name'),
            c.text,
            line: c.line,
          );
          _resetMultiline();
          break;
        }
        if (c.tag == 'endtip') {
          if (autoMode != 'default' && !state.metadata.isVideoOnly && c.text.isNotEmpty) {
            _flushMultiline();
            _showDialogue('', c.text, line: c.line);
            _resetMultiline();
            break;
          }
          continue;
        }
        if (c.tag == 'header') continue;
        if (c.tag == 'subtitle' || c.tag == 'sticker') _logOverlay(c);
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
        if (_waitingInput) break;
      }
      if (epoch == _epoch &&
          cursor >= script.commands.length &&
          state.choices.isEmpty &&
          !state.dialogueVisible &&
          !_waitingInput) {
        _finishCleanup();
        finished = true;
        _waitingInput = false;
      }
    } finally {
      if (epoch == _epoch) {
        running = false;
        _changed();
      }
    }
  }

  bool _predicateActive() =>
      _selectedValue == 0 || _predicates == null || _predicates!.isEmpty || _predicates!.contains(_selectedValue);

  void _showDialogue(String speaker, String text, {int line = 0, int startIndex = 0, bool log = true}) {
    _overlayLogSource = null;
    state.speaker = translate(speaker);
    state.text = translate(text).replaceAll(r'\n', '\n');
    final total = totalCharacters;
    state.revealed = startIndex.clamp(0, total);
    _typingTime = currentSpeed.typingMs <= 0
        ? 0
        : state.revealed * _typingScale * currentSpeed.typingMs;
    state.dialogueVisible = true;
    if (log) state.history.add(DialogueLine(state.speaker, state.text, line));
    _waitingInput = true;
    _changed();
  }

  void _runMultiline(StoryCommand c) {
    final text = translate(c.text).replaceAll(r'\n', '\n');
    if (text.isEmpty) {
      state.dialogueVisible = false;
      return;
    }
    if (_multilineText.isEmpty) _multilineName = c.value('name');
    _multilineText += text;
    _multilineEnd = c.flag('end');
    final delayArg = double.tryParse(c.value('delay'));
    _typingScale = delayArg == null
        ? 1
        : delayArg / (baseTypingMs / 1000);
    _showDialogue(
      _multilineName,
      _multilineText,
      line: c.line,
      startIndex: _multilineShownChars,
      log: false,
    );
    _multilineShownChars = totalCharacters;
    if (_multilineEnd) {
      state.history.add(DialogueLine(translate(_multilineName), _multilineText, c.line));
      _resetMultiline();
    }
  }

  void _flushMultiline() {
    if (_multilineText.isEmpty || _multilineLogged) return;
    _multilineLogged = true;
    state.history.add(DialogueLine(translate(_multilineName), _multilineText, cursor));
  }

  void _resetMultiline() {
    _multilineName = '';
    _multilineText = '';
    _multilineEnd = false;
    _multilineShownChars = 0;
    _multilineLogged = false;
    _typingScale = 1;
  }

  bool _completeOverlayTyping() {
    var result = false;
    final s = state.subtitle;
    if (s != null && s.visible && s.revealed < plainText(s.text).runes.length) {
      s.revealed = plainText(s.text).runes.length;
      result = true;
    }
    for (final sticker in state.stickers.values) {
      if (sticker.visible && sticker.revealed < plainText(sticker.text).runes.length) {
        sticker.revealed = plainText(sticker.text).runes.length;
        result = true;
      }
    }
    return result;
  }

  Future<void> choose(String value) async {
    final index = state.choices.indexWhere((c) => c.value == value && !c.disabled);
    if (index < 0) return;
    _selectedValue = index < _decisionValues.length ? _decisionValues[index] : 0;
    _predicates = null;
    state.choices = [];
    _changed();
    await advance();
  }

  Future<void> skipNode() async {
    if (!canSkipNode || autoMode == 'quick_play') return;
    if (_skipToIndex >= 0 && cursor <= _skipToIndex) {
      cursor = _skipToIndex + 1;
      theaterMode = false;
      setAutoMode('default');
      _skipNodeIndex = _skipNodes.length;
      _currentSkipMode = 'skip';
    } else if (_skipToIndex >= 0) {
      return;
    } else if (_skipNodeIndex < _skipNodes.length) {
      final node = _skipNodes[_skipNodeIndex++];
      _currentSkipMode = node.mode;
      final allowed = state.metadata.isSkippable && (_currentSkipMode != 'nofirstskip' || firstRead);
      cursor = allowed ? node.index + 1 : script.commands.length;
    } else {
      cursor = script.commands.length;
    }
    if (cursor >= script.commands.length) {
      // 参考端 resetItemSlot：跳到结尾时立即清除 showitem 槽位。
      _itemSlotInUse = false;
      state.showItems.clear();
    }
    _epoch++;
    _cancelAnimations();
    _cancelShake();
    _resetMultiline();
    _resetMotions();
    clearOverlays();
    running = false;
    _waitingInput = false;
    _autoClickAt = -1;
    state.dialogueVisible = false;
    _changed();
    if (cursor < script.commands.length) {
      unawaited(advance());
    } else {
      finished = true;
      _waitingInput = false;
      _changed();
    }
  }

  void _cancelShake() {
    _shakePath = null;
    state.shake = Offset.zero;
    _shakeWaiter?.complete();
    _shakeWaiter = null;
  }

  /// 播放结束清理：参考端 finishPlayback 清 animtext/avgdisplay 并重置 showitem 槽位。
  void _finishCleanup() {
    state.stamps.clear();
    state.avgDisplays.clear();
    _itemSlotInUse = false;
    state.showItems.clear();
  }

  /// 清理所有浮层（跳过节点与重播时使用），与参考端行为一致。
  void clearOverlays() {
    state.subtitle = null;
    state.stickers.clear();
    state.timer = null;
    state.stamps.clear();
    state.cutins.clear();
    state.interludes.clear();
    _stickerTweens.clear();
  }

  Future<void> restart() async {
    _epoch++;
    _cancelAnimations();
    _cancelShake();
    _resetMotions();
    clearOverlays();
    final metadata = state.metadata;
    _overlayLogSource = null;
    state = StageState()..metadata = metadata;
    cursor = 0;
    running = false;
    finished = false;
    _waitingInput = false;
    _selectedValue = 0;
    _predicates = null;
    _decisionValues = const [];
    _skipNodeIndex = 0;
    _currentSkipMode = 'skip';
    _slotDeadlines.clear();
    _itemSlotInUse = false;
    _resetMultiline();
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

  void setAutoPlay(bool value) => setAutoMode(value ? 'button_auto' : 'default');

  /// 自动播放模式：default（手动）/ button_auto（自动）/ quick_play（快速）。
  void setAutoMode(String mode) {
    if (mode != 'default' && !state.metadata.isAutoable && !theaterMode) return;
    autoMode = mode;
    _autoClickAt = -1;
    _changed();
  }

  void setSpeedLevel(int level) {
    speedLevel = math.max(0, level);
    _autoClickAt = -1;
    _changed();
  }

  void _registerBuiltins() {
    register('header', (_) async {});
    register('delay', (c) async {
      await animate('delay', scaled(c.number('time')), (_) {});
    });
    register('decision', (c) async {
      _overlayLogSource = null;
      _flushMultiline();
      _resetMultiline();
      final rawOptions = c.value('options');
      if (rawOptions.isEmpty) {
        _selectedValue = 0;
        _predicates = null;
        warn('第 ${c.line} 行：decision 缺少 options 参数');
        return;
      }
      final options = rawOptions.split(';');
      final values = c.value('values').split(';').map((s) => int.tryParse(s.trim()) ?? 0).toList();
      state.choices = [
        for (var i = 0; i < options.length; i++)
          Choice(
            translate(options[i].startsWith('&') ? options[i].substring(1) : options[i]),
            i < values.length ? values[i].toString() : '0',
            disabled: options[i].startsWith('&'),
          ),
      ];
      _decisionValues = values;
      if (options.length > 4) warn('第 ${c.line} 行：decision 选项超过 4 个');
    });
    register('predicate', (c) async {
      // 参考端：references 缺省/为空表示放行全部。
      final raw = c.value('references');
      _predicates = raw.isEmpty
          ? <int>{}
          : raw.split(';').map((s) => int.tryParse(s.trim()) ?? 0).toSet();
    });
    register('label', (_) async {});
    register('gotostage', (_) async {});
    register('warp', (c) async {
      final target = script.commands.indexWhere(
        (x) => x.tag == 'label' && x.value('name') == c.value('name'),
      );
      if (target < 0) {
        warn('第 ${c.line} 行：跳转目标不存在：${c.value('name')}');
        return;
      }
      cursor = target + 1;
    });
    register('skipnode', (_) async {
      if (_skipNodeIndex < _skipNodes.length) {
        _currentSkipMode = _skipNodes[_skipNodeIndex++].mode;
      }
    });
    register('skiptothis', (_) async {});
    register('theater', (c) async {
      if (c.flag('mode', true)) {
        _theaterRestore = autoMode;
        _theaterRestoreLevel = speedLevel;
        theaterMode = true;
        speedLevel = 0;
        setAutoMode('button_auto');
      } else {
        theaterMode = false;
        speedLevel = _theaterRestoreLevel;
        setAutoMode(_theaterRestore);
      }
      _changed();
    });
    register('bgeffect', (c) async {
      warn('第 ${c.line} 行：bgeffect 参考端同样不支持，跳过');
    });
    register('effect', (c) async {
      warn('第 ${c.line} 行：effect 参考端同样不支持，跳过');
    });
    register('video', (c) async {
      warn('第 ${c.line} 行：video 需要平台播放器（Windows 无官方实现），本轮跳过');
    });
    register('spellsticker', (c) async {
      warn('第 ${c.line} 行：spellsticker 依赖 FZTYSK/RoHMinSink 字体（未获授权），本轮跳过');
    });
    register('spellstickerclear', (_) async {});
    for (final tag in ['playmusic', 'stopmusic', 'musicvolume', 'playsound', 'stopsound', 'soundvolume']) {
      register(tag, audio.execute);
    }
    // ---- 图层与场景 ----
    for (final tag in ['background', 'image']) {
      register(tag, _image);
    }
    for (final tag in ['backgroundtween', 'imagetween']) {
      register(tag, _imageTween);
    }
    register('imagerotate', _imageRotate);
    register('blocker', _blocker);
    register('curtain', _curtain);
    register('cameraeffect', _cameraEffect);
    register('camerashake', _cameraShake);
    register('focusout', _focusOut);
    register('focusparam', _focusParam);
    register('charslot', _characterSlot);
    register('character', _legacyCharacter);
    register('characteraction', _characterAction);
    for (final tag in ['gridbg', 'verticalbg', 'largebg', 'largeimg']) {
      register(tag, _gridScene);
    }
    for (final tag in ['largebgtween', 'largeimgtween']) {
      register(tag, _largeTween);
    }
    register('cgitem', _cgItem);
    register('hidecgitem', _hideCgItem);
    register('avgdisplay', _avgDisplay);
    register('showitem', _showItem);
    register('hideitem', _hideItem);
    register('charactercutin', _characterCutin);
    // ---- 浮层与文字 ----
    register('subtitle', _subtitle);
    register('sticker', _sticker);
    register('stickertween', _stickerTween);
    register('timersticker', _timerSticker);
    register('timerclear', _timerClear);
    register('stickerclear', _stickerClear);
    register('animtext', _animText);
    register('interlude', _interlude);
  }

  // ============ 背景 / 图片 ============

  Future<void> _image(StoryCommand c) async {
    final layers = c.tag == 'image' ? state.images : state.backgrounds;
    _cancelAnimation(c.tag == 'image' ? 'imagetween' : 'backgroundtween');
    final old = layers.toList();
    final key = c.value('image');
    final seconds = scaled(c.number('fadetime'));
    if (key.isEmpty) {
      final epoch = _epoch;
      final future = animate(c.tag, seconds, (t) {
        for (final previous in old) {
          previous.alpha = 1 - t;
        }
      }).then((_) {
        if (epoch == _epoch) {
          layers.removeWhere(old.contains);
          _changed();
        }
      });
      if (c.flag('block')) await future;
      return;
    }
    final image = StageImage(key, cg: c.tag == 'image')
      ..x = c.number('x')
      ..y = c.number('y')
      ..scaleX = c.number('xscale', 1)
      ..scaleY = c.number('yscale', 1)
      ..widthScale = c.number('width', 1)
      ..heightScale = c.number('height', 1)
      ..tiled = c.flag('tiled');
    // 缺省 screenadapt 不缩放，参考端保持原图尺寸。
    final adapt = c.args['screenadapt'];
    image.fit = adapt is String ? adapt : '';
    layers.add(image);
    final epoch = _epoch;
    final future =
        animate(c.tag, seconds, (t) {
          image.alpha = t;
          for (final previous in old) {
            previous.alpha = 1 - t;
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
    final from = Offset(
      c.args.containsKey('xfrom') ? c.number('xfrom') : image.x,
      c.args.containsKey('yfrom') ? c.number('yfrom') : image.y,
    );
    final to = Offset(
      c.args.containsKey('xto') ? c.number('xto') : from.dx,
      c.args.containsKey('yto') ? c.number('yto') : from.dy,
    );
    final sxf = c.number('xscalefrom', image.scaleX), syf = c.number('yscalefrom', image.scaleY);
    final sxt = c.number('xscaleto', sxf), syt = c.number('yscaleto', syf);
    final loop = c.flag('loop');
    final seconds = c.number('duration');
    final ease = c.value('ease');
    if (loop && c.flag('block')) {
      warn('第 ${c.line} 行：${c.tag} 的 loop 与 block 同时为真，忽略 block');
    }
    final future = animate(c.tag, seconds, (t) {
      image.x = _lerp(from.dx, to.dx, t);
      image.y = _lerp(from.dy, to.dy, t);
      image.scaleX = _lerp(sxf, sxt, t);
      image.scaleY = _lerp(syf, syt, t);
    }, ease: ease, loop: loop);
    if (c.flag('block') && !loop) await future;
  }

  Future<void> _imageRotate(StoryCommand c) async {
    final target = c.number('angle');
    final circles = c.number('circles').truncate();
    final inverse = c.flag('inverse');
    final seconds = scaled(c.number('fadetime'));
    final current = state.imageRotation;
    var delta = target - current;
    while (delta > 180) {
      delta -= 360;
    }
    while (delta < -180) {
      delta += 360;
    }
    if (inverse) {
      if (delta < 0) delta += 360;
      delta += circles * 360.0;
    } else {
      if (delta > 0) delta -= 360;
      delta -= circles * 360.0;
    }
    await _transition(c, 'imageRotate', seconds, (t) {
      state.imageRotation = current + delta * t;
    });
  }

  // ============ 遮罩 / 幕布 / 镜头 ============

  Future<void> _blocker(StoryCommand c) async {
    double color(String key, double fallback) {
      final raw = c.args[key];
      if (raw == null) return fallback;
      return (double.tryParse(raw) ?? fallback).clamp(0.0, 1.0).toDouble();
    }

    final style = c.value('style', 'default');
    final isSlider = ['slider', 'verticalslider'].contains(style);
    state.blockerStyle = isSlider ? style : 'default';
    state.blockerInverse = c.flag('inverse');
    state.blockerImage = state.blockerStyle == 'default' ? c.value('image') : '';
    final hasFrom = ['rfrom', 'gfrom', 'bfrom', 'afrom'].any(c.args.containsKey);
    final fromR = color('rfrom', state.blockerColor.r),
        fromG = color('gfrom', state.blockerColor.g),
        fromB = color('bfrom', state.blockerColor.b),
        fromA = color('afrom', state.blockerAlpha);
    final toR = color('r', 0), toG = color('g', 0), toB = color('b', 0);
    final toA = c.args.containsKey('a') ? color('a', 1) : 1.0;
    final seconds = scaled(c.number('fadetime'));
    if (seconds <= 0) {
      state.blockerColor = Color.from(alpha: 1, red: toR, green: toG, blue: toB);
      state.blockerAlpha = toA;
      if (toA <= 0) state.blockerImage = '';
      _changed();
      return;
    }
    final epoch = _epoch;
    final from = state.blockerAlpha;
    await _transition(c, 'blocker', seconds, (t) {
      state.blockerColor = Color.from(
        alpha: 1,
        red: _lerp(hasFrom ? fromR : fromR, toR, t),
        green: _lerp(fromG, toG, t),
        blue: _lerp(fromB, toB, t),
      );
      state.blockerAlpha = _lerp(c.args.containsKey('afrom') ? fromA : from, toA, t);
      if (t >= 1 && toA <= 0) state.blockerImage = '';
    });
    if (epoch == _epoch && state.blockerAlpha <= 0) {
      state.blockerImage = '';
    }
  }

  Future<void> _curtain(StoryCommand c) async {
    final direction = c.number('direction', -1).toInt();
    final seconds = scaled(c.number('fadetime', .4));
    if (direction < 0) {
      final old = state.curtains.values.toList();
      final epoch = _epoch;
      unawaited(animate('curtain', seconds, (t) {
        final e = _easeOutQuad(t);
        for (final item in old) {
          item.fill = _lerp(item.fill, 0, e);
          item.alpha = _lerp(item.alpha, 0, e);
        }
      }).then((_) {
        if (epoch == _epoch) {
          state.curtains.removeWhere((key, item) => old.contains(item) && item.fill <= 0);
          _changed();
        }
      }));
      return;
    }
    if (direction > 7) {
      warn('第 ${c.line} 行：curtain 方向无效：$direction');
      return;
    }
    final item = state.curtains.putIfAbsent(direction, () => CurtainState(direction));
    final fillFrom = c.number('fillfrom', 1), fillTo = c.number('fillto', 0);
    final hasAlpha = c.args.containsKey('a') && c.number('a') >= 0;
    final double alphaFrom = hasAlpha ? c.number('afrom', item.alpha) : 1.0;
    final double alphaTo = hasAlpha ? c.number('a', 1) : 1.0;
    item.grad = c.flag('grad');
    final delayMs = math.max(0.0, c.number('delay')) * 1000;
    final epoch = _epoch;
    void update(double t) {
      final e = _easeOutQuad(t);
      item.fill = _lerp(fillFrom, fillTo, e);
      item.alpha = _lerp(alphaFrom, alphaTo, e);
      if (t >= 1 && item.fill <= 0) state.curtains.remove(direction);
    }

    if (delayMs > 0) {
      unawaited(Future<void>.delayed(Duration(milliseconds: delayMs.toInt())).then((_) {
        if (epoch == _epoch) {
          unawaited(animate('curtain:$direction', seconds, update));
        }
      }));
      if (c.flag('block')) {
        await Future<void>.delayed(Duration(milliseconds: (delayMs + seconds * 1000).toInt()));
      }
      return;
    }
    await _transition(c, 'curtain:$direction', seconds, update);
  }

  Future<void> _cameraEffect(StoryCommand c) async {
    final effect = c.value('effect');
    final keep = c.flag('keep');
    final seconds = scaled(c.number('fadetime', .4));
    if (effect == 'Chaos') {
      warn('第 ${c.line} 行：cameraeffect Chaos 参考端同样不支持，跳过');
      return;
    }
    if (effect == 'Colorinverse') {
      state.inverse = keep ? 1 : 0;
      _changed();
      return;
    }
    if (effect != 'Grayscale') return;
    final target = c.number('amount', 1);
    final hasInit = c.args.containsKey('initamount') && c.number('initamount') >= 0;
    final from = hasInit ? c.number('initamount') : state.grayscale;
    state.grayscale = from;
    final epoch = _epoch;
    final future = animate('camerafx', seconds, (t) {
      final eased = 1 - (1 - t) * (1 - t);
      state.grayscale = t >= 1 ? (keep ? target : 0) : _lerp(from, target, eased);
    });
    if (c.flag('block')) await future;
    if (epoch != _epoch) return;
  }

  Future<void> _cameraShake(StoryCommand c) async {
    if (c.flag('stop')) {
      _cancelShake();
      _changed();
      return;
    }
    final scaledDuration = c.number('duration', -1) * currentSpeed.animateRatio;
    final infinite = scaledDuration < 0;
    final durationMs = infinite ? 10000.0 : math.max(0.0, scaledDuration * 1000);
    if (durationMs <= 0) {
      _cancelShake();
      _changed();
      return;
    }
    _cancelShake();
    _shakePath = buildShakePath(
      durationMs: durationMs,
      vibrato: c.number('vibrato', 10),
      randomness: c.number('randomness', 90),
      xStrength: c.number('xstrength', 1),
      yStrength: c.number('ystrength', 0),
      fadeOut: c.flag('fadeout'),
      vectorBased: true,
      random: _random,
    );
    _shakeStartUs = _nowUs();
    _shakeDurationMs = durationMs;
    _shakeInfinite = infinite;
    _changed();
    if (c.flag('block')) {
      if (infinite) {
        _shakeWaiter = Completer<void>();
        await _shakeWaiter!.future;
      } else {
        await Future<void>.delayed(Duration(milliseconds: durationMs.toInt()));
      }
    }
  }

  Future<void> _focusOut(StoryCommand c) async {
    final type = c.value('type');
    final id = c.value('id');
    if (!['char', 'bg', 'cg', 'lbg'].contains(type) && !(type == 'cgitem' && id.isNotEmpty)) {
      warn('第 ${c.line} 行：未支持的 focusout 类型：$type');
      return;
    }
    final key = type == 'cgitem' ? 'cgitem:$id' : type;
    final fromArg = double.tryParse(c.value('from'));
    final from = fromArg != null && fromArg >= 0 ? fromArg : (state.focus[key] ?? 0);
    final to = c.number('to', 0);
    final seconds = c.number('duration');
    await _transition(c, 'focus:$key', seconds, (t) {
      state.focus[key] = _lerp(from, to, _smoothstep(t));
    });
  }

  Future<void> _focusParam(StoryCommand c) {
    state.focusBlur = c.flag('blur', true);
    final effect = c.value('effect');
    state.focusColor = ['Grayscale', 'Colorinverse'].contains(effect) ? effect : 'None';
    _changed();
    return Future.value();
  }

  // ============ 立绘 ============

  void _applyFocus(Set<String> slots) {
    for (final node in state.characters) {
      node.brightness = slots.contains(node.slot) ? 1 : .5;
    }
  }

  Set<String> _focusSlots(String value) {
    final raw = value.trim().toLowerCase();
    if (raw.isEmpty || raw == 'all') return {'l', 'm', 'r'};
    return raw.split(',').map(_slot).where((s) => s.isNotEmpty).toSet();
  }

  Future<void> _characterSlot(StoryCommand c) async {
    final rawSlot = c.value('slot').trim();
    final seconds = scaled(c.number('duration', 0));
    if (rawSlot.isEmpty) {
      final old = state.characters.toList();
      final epoch = _epoch;
      final future = animate('clearCharacters', seconds, (t) {
        for (final node in old) {
          node.alpha = 1 - t;
        }
      }).then((_) {
        if (epoch == _epoch) state.characters.removeWhere(old.contains);
      });
      if (c.flag('isblock')) await future;
      return;
    }
    final slot = _slot(rawSlot);
    if (slot.isEmpty) {
      warn('第 ${c.line} 行：charslot 槽位不受支持：$rawSlot');
      return;
    }
    final end = c.value('end').trim().toLowerCase() != 'false';
    final block = c.flag('isblock') && end;
    _applyFocus(_focusSlots(c.value('focus', 'all')));
    final name = c.value('name');
    var nodes = state.characters.where((n) => n.slot == slot).toList();
    var node = nodes.isEmpty ? null : nodes.last;
    if (name == 'char_empty') {
      state.characters.removeWhere((n) => n.slot == slot);
      _motions.remove(slot);
      return;
    }
    if (name.isNotEmpty) {
      final old = nodes;
      final afrom = double.tryParse(c.value('afrom'));
      final ato = double.tryParse(c.value('ato'));
      final alphaFrom = (afrom != null && ato != null) ? afrom.clamp(0.0, 1.0).toDouble() : 0.0;
      final alphaTo = (afrom != null && ato != null) ? ato.clamp(0.0, 1.0).toDouble() : 1.0;
      final focusSlots = _focusSlots(c.value('focus', 'all'));
      final fresh = StageCharacter(slot, name)
        ..brightness = focusSlots.contains(slot) ? 1 : .5
        ..blackStart = c.number('bstart', -1)
        ..blackEnd = c.number('bend', -1)
        ..contentAlpha = alphaFrom;
      state.characters.add(fresh);
      node = fresh;
      final next = fresh;
      final epoch = _epoch;
      final fade = animate('character:$slot', seconds, (t) {
        next.contentAlpha = _lerp(alphaFrom, alphaTo, t);
        for (final previous in old) {
          previous.alpha = 1 - t;
        }
      }).then((_) {
        if (epoch == _epoch) state.characters.removeWhere(old.contains);
      });
      // 槽位排队截止：阻塞时等待整段入场动画。
      if (block) {
        await fade;
      }
    }
    if (node == null) return;
    final target = node;
    final action = c.value('action').trim().toLowerCase();
    final motion = _motions[slot] ??= _Motion();
    if ((action == 'shake' || action == 'shakemove') && seconds > 0) {
      _startShake(
        slot,
        seconds * 1000,
        c.number('power', 0),
        c.number('times', 0),
        c.number('random', 10).clamp(0, 100),
        stop: c.flag('stop'),
      );
    } else if (c.flag('stop')) {
      _startShake(slot, 0, 0, 0, 0, stop: true);
      motion.jumpStartUs = -1;
      target.jumpOffsetY = 0;
    }
    if (action == 'jump' && seconds > 0) {
      _startJump(slot, c.number('power', 0), c.number('times', 0), seconds * 1000);
    }
    final hasAngle = c.args.containsKey('angle');
    if (hasAngle) {
      final fromAngle = target.rotationDeg;
      final toAngle = (c.flag('inverse') ? -1 : 1) * (c.number('angle') + 360 * c.number('circles').truncate());
      unawaited(animate('characterRotate:$slot', seconds, (t) {
        target.rotationDeg = _lerp(fromAngle, toAngle, t);
      }));
    }
    // 位置补间：move/setpos 从 posfrom 到 posto；jump 相对位移。
    final hasPos = c.args.containsKey('posfrom') || c.args.containsKey('posto');
    if (hasPos) {
      final to = _hasPoint(c.value('posto')) ? _point(c.value('posto')) : Offset.zero;
      Offset from;
      if (action == 'jump' && seconds > 0) {
        from = Offset(target.actionX, target.actionY);
        // jump 的 posto 为相对位移。
        unawaited(animate('characterMotion:$slot', seconds, (t) {
          target.actionX = _lerp(from.dx, from.dx + to.dx, _easeOutCubic(t));
          target.actionY = _lerp(from.dy, from.dy + to.dy, _easeOutCubic(t));
        }));
      } else {
        from = _hasPoint(c.value('posfrom')) ? _point(c.value('posfrom')) : Offset(target.actionX, target.actionY);
        final duration = action == 'setpos' ? 0.0 : seconds;
        unawaited(animate('characterMotion:$slot', duration, (t) {
          target.actionX = _lerp(from.dx, to.dx, t);
          target.actionY = _lerp(from.dy, to.dy, t);
        }));
      }
    }
    // zoom：以 poszoom 为轴心缩放。
    final hasZoom = action == 'zoom' && (c.args.containsKey('xscale') || c.args.containsKey('yscale') || c.args.containsKey('scale'));
    if (hasZoom) {
      final base = c.number('scale', 1);
      final sx = c.number('xscale', base), sy = c.number('yscale', base);
      final pivot = _hasPoint(c.value('poszoom')) ? _point(c.value('poszoom')) : const Offset(.5, .5);
      final artWidth = _characterSize(slot).dx, artHeight = _characterSize(slot).dy;
      final fromScaleX = target.scaleX, fromScaleY = target.scaleY;
      final fromShiftX = target.zoomShiftX, fromShiftY = target.zoomShiftY;
      final toShiftX = (.5 - pivot.dx) * sx * artWidth - (sx - 1) * artWidth / 2;
      final toShiftY = (.5 - pivot.dy) * sy * artHeight + (sy - 1) * artHeight / 2;
      unawaited(animate('characterZoom:$slot', seconds, (t) {
        target.scaleX = _lerp(fromScaleX, sx, t);
        target.scaleY = _lerp(fromScaleY, sy, t);
        target.zoomShiftX = _lerp(fromShiftX, toShiftX, t);
        target.zoomShiftY = _lerp(fromShiftY, toShiftY, t);
      }));
    }
  }

  /// 立绘的标称尺寸（zoom 位移计算用）；由外部注入 character.json 的尺寸解析。
  Offset _characterSize(String slot) {
    final node = state.characters.lastWhereOrNull((n) => n.slot == slot);
    if (node == null) return const Offset(1024, 1024);
    final size = characterArtSize?.call(node.name);
    return size ?? const Offset(1024, 1024);
  }

  Future<void> _legacyCharacter(StoryCommand c) async {
    final first = c.value('name'), second = c.value('name2');
    final seconds = scaled(c.number('fadetime', .15));
    if (first.isEmpty && second.isEmpty) {
      await _characterSlot(
        StoryCommand('charslot', {'duration': seconds.toString()}, '', c.line, c.raw),
      );
      return;
    }
    final focus = c.number('focus').toInt();
    final transtype = c.number('transtype').toInt();
    final enter = c.value('enter'), enter2 = c.value('enter2');
    final blackStart = c.number('blackstart', -1), blackEnd = c.number('blackend', -1);
    final blackStart2 = c.number('blackstart2', -1), blackEnd2 = c.number('blackend2', -1);
    state.characters.removeWhere((n) => second.isEmpty ? n.slot != 'm' : n.slot == 'm');
    final entries = [
      (second.isEmpty ? 'm' : 'l', first, enter, blackStart, blackEnd, '1'),
      ('r', second, enter2, blackStart2, blackEnd2, '2'),
    ];
    for (final (slot, name, enterDir, bStart, bEnd, index) in entries) {
      if (name.isEmpty) {
        state.characters.removeWhere((n) => n.slot == slot);
        continue;
      }
      final old = state.characters.where((n) => n.slot == slot).toList();
      final node = StageCharacter(slot, name)
        ..blackStart = bStart
        ..blackEnd = bEnd
        ..brightness = slot == 'r' ? !(focus == 0 || focus == 2) ? .5 : 1 : (focus > 1 ? .5 : 1);
      // 入场方向：先摆到屏幕外，再滑入。
      if (enterDir == 'left' || enterDir == 'right' || enterDir == 'up' || enterDir == 'down') {
        final base = slot == 'l' ? 200.0 : slot == 'r' ? -200.0 : 0.0;
        node.actionX = switch (enterDir) {
          'left' => base - 1152,
          'right' => base + 1152,
          _ => 0,
        };
        node.actionY = enterDir == 'up' ? 1072 : enterDir == 'down' ? -1072 : 0;
        if (c.args.containsKey('xpos$index') && c.args.containsKey('ypos$index')) {
          node.actionX = c.number('xpos$index').truncateToDouble();
          node.actionY = c.number('ypos$index').truncateToDouble();
        }
      }
      state.characters.add(node);
      final next = node;
      final hasEnter = enterDir == 'left' || enterDir == 'right' || enterDir == 'up' || enterDir == 'down';
      final startAlpha = hasEnter && transtype == 0 ? 0.0 : 1.0;
      final startX = node.actionX, startY = node.actionY;
      final epoch = _epoch;
      unawaited(animate('character:$slot', seconds, (t) {
        next.contentAlpha = startAlpha > 0 ? 1 : t;
        for (final previous in old) {
          previous.alpha = 1 - t;
        }
        if (hasEnter) {
          final e = _easeOutCubic(t);
          next.actionX = _lerp(startX, 0, e);
          next.actionY = _lerp(startY, 0, e);
        }
      }).then((_) {
        if (epoch == _epoch) state.characters.removeWhere(old.contains);
      }));
    }
    _changed();
  }

  Future<void> _characterAction(StoryCommand c) async {
    final type = c.value('type');
    if (!['exit', 'jump', 'move', 'shake', 'zoom'].contains(type)) {
      warn('第 ${c.line} 行：characteraction 类型无效：$type');
      return;
    }
    final nameArg = c.value('name');
    var slot = switch (nameArg) {
      'left' => 'l',
      'right' => 'r',
      'middle' => 'm',
      _ => type == 'exit' ? 'm' : 'l',
    };
    final node = state.characters.lastWhereOrNull((n) => n.slot == slot);
    if (node == null) {
      warn('第 ${c.line} 行：characteraction 目标槽位无立绘：$slot');
      return;
    }
    var action = type;
    final defaultDuration = type == 'exit' || type == 'zoom' ? 1.0 : .5;
    var seconds = scaled(c.number('fadetime', defaultDuration));
    if ((action == 'jump' || action == 'shake') && seconds <= 0) action = 'move';
    final hasX = c.args.containsKey('xpos'), hasY = c.args.containsKey('ypos');
    final xOffset = action == 'zoom' ? 0.0 : c.number('xpos', 0);
    final yOffset = action == 'zoom' ? 0.0 : c.number('ypos', 0);
    final block = c.flag('isblock');
    switch (action) {
      case 'move':
        final fromX = node.actionX, fromY = node.actionY;
        await animate('characterMotion:$slot', seconds, (t) {
          final e = _easeOutCubic(t);
          node.actionX = _lerp(fromX, fromX + xOffset, e);
          node.actionY = _lerp(fromY, fromY + yOffset, e);
        });
      case 'jump':
        _startJump(slot, c.number('power', 10), c.number('times', 3), seconds * 1000);
        final fromX = node.actionX, fromY = node.actionY;
        final move = animate('characterMotion:$slot', seconds, (t) {
          node.actionX = _lerp(fromX, fromX + xOffset, _easeOutCubic(t));
          node.actionY = _lerp(fromY, fromY + yOffset, _easeOutQuad(_easeOutCubic(t)));
        });
        if (block && seconds > 0) await move;
      case 'shake':
        _startShake(
          slot,
          seconds * 1000,
          c.number('power', 10),
          c.number('times', 3),
          c.number('random', 10),
          stop: c.flag('stop'),
        );
        if (block && !c.flag('stop')) {
          await Future<void>.delayed(Duration(milliseconds: (seconds * 1000).toInt()));
        }
      case 'zoom':
        final pivotX = c.number('xpos', .5), pivotY = c.number('ypos', .5);
        if (pivotX < 0 || pivotX > 1 || pivotY < 0 || pivotY > 1) {
          warn('第 ${c.line} 行：characteraction zoom 轴心越界：$pivotX,$pivotY');
          return;
        }
        final base = c.number('scale', 1);
        final sx = c.number('xscale', base), sy = c.number('yscale', base);
        final artWidth = _characterSize(slot).dx, artHeight = _characterSize(slot).dy;
        final fromScaleX = node.scaleX, fromScaleY = node.scaleY;
        final fromShiftX = node.zoomShiftX, fromShiftY = node.zoomShiftY;
        final toShiftX = (.5 - pivotX) * sx * artWidth - (sx - 1) * artWidth / 2;
        final toShiftY = (.5 - pivotY) * sy * artHeight + (sy - 1) * artHeight / 2;
        await animate('characterZoom:$slot', seconds, (t) {
          node.scaleX = _lerp(fromScaleX, sx, t);
          node.scaleY = _lerp(fromScaleY, sy, t);
          node.zoomShiftX = _lerp(fromShiftX, toShiftX, t);
          node.zoomShiftY = _lerp(fromShiftY, toShiftY, t);
        });
      case 'exit':
        Offset target;
        if (hasX && hasY) {
          target = Offset(c.number('xpos'), c.number('ypos'));
        } else {
          final dir = c.value('direction').isEmpty ? 'left' : c.value('direction');
          target = switch ((slot, dir)) {
            ('l', 'left') => const Offset(-952, 0),
            ('l', 'right') => const Offset(1352, 0),
            ('m', 'left') => const Offset(-1152, 0),
            ('m', 'right') => const Offset(1152, 0),
            ('r', 'left') => const Offset(-1352, 0),
            ('r', 'right') => const Offset(952, 0),
            (_, 'up') => const Offset(0, 1072),
            (_, 'down') => const Offset(0, -1072),
            _ => Offset.zero,
          };
        }
        final fromX = node.actionX, fromY = node.actionY;
        await animate('characterMotion:$slot', seconds, (t) {
          final e = _easeOutCubic(t);
          node.actionX = _lerp(fromX, target.dx, e);
          node.actionY = _lerp(fromY, target.dy, e);
        });
    }
  }

  // ============ 多图拼接场景 ============

  Future<void> _gridScene(StoryCommand c) async {
    final isImage = c.tag == 'largeimg';
    final group = c.value('imagegroup').isNotEmpty ? c.value('imagegroup') : c.value('cggroup');
    final cgKind = c.value('cggroup').isNotEmpty || (isImage && c.value('imagegroup').isEmpty);
    final seconds = c.tag == 'largeimg'
        ? math.max(0.0, c.number('fadetime', .15))
        : math.max(0.0, c.number('fadetime'));
    final block = isImage
        ? c.flag('blok') || c.flag('isblock') || c.flag('block')
        : seconds > 0 && c.flag('block');
    final layers = isImage ? state.largeImages : state.largeScenes;
    _cancelAnimation(isImage ? 'largeimgtween' : 'largebgtween');
    if (group.isEmpty) {
      final old = layers.toList();
      final epoch = _epoch;
      final future = animate(c.tag, seconds, (t) {
        for (final scene in old) {
          scene.alpha = 1 - t;
        }
      }).then((_) {
        if (epoch == _epoch) {
          layers.removeWhere(old.contains);
          _changed();
        }
      });
      if (block) await future;
      return;
    }
    final keys = group.split('/').where((s) => s.trim().isNotEmpty).toList();
    final solidWidths = _numbers(c.value('solidwidth'));
    final solidHeights = _numbers(c.value('solidheight'));
    String layout;
    if (c.tag == 'gridbg') {
      layout = 'grid';
      if (keys.length != 4 || solidWidths.length != 2 || solidHeights.length != 2) {
        warn('第 ${c.line} 行：gridbg 需要 4 图与 2×2 尺寸，实际 ${keys.length} 图');
        return;
      }
    } else if (c.tag == 'verticalbg') {
      layout = 'vertical';
      if (keys.isEmpty || keys.length > 4 || solidWidths.length != 1 || solidHeights.length != keys.length) {
        warn('第 ${c.line} 行：verticalbg 需要 width_count*height_count===image_count');
        return;
      }
    } else {
      layout = 'large';
      if (keys.length != 2 || solidWidths.length != 2) {
        warn('第 ${c.line} 行：largebg 需要 2 图横向拼接');
        return;
      }
    }
    final scene = LargeScene(
      tiles: [for (final key in keys) StageImage(key, cg: cgKind)],
      solidWidths: List<double>.from(solidWidths),
      solidHeights: List<double>.from(layout == 'large' ? [c.number('solidheight', 0)] : solidHeights),
      layout: layout,
      initPositionMode: c.value('initposmode', 'default'),
    )..x = c.number('x')..y = c.number('y')
      ..scaleX = c.number('xscale', 1)
      ..scaleY = c.number('yscale', 1);
    layers.clear();
    scene.alpha = seconds > 0 ? 0 : 1;
    layers.add(scene);
    final future = animate(c.tag, seconds, (t) => scene.alpha = t);
    if (block) await future;
  }

  Future<void> _largeTween(StoryCommand c) async {
    final layers = c.tag == 'largeimgtween' ? state.largeImages : state.largeScenes;
    if (layers.isEmpty) return;
    final scene = layers.last;
    final fromX = c.args.containsKey('xfrom') ? c.number('xfrom') : (c.args.containsKey('x') ? c.number('x') : scene.x);
    final fromY = c.args.containsKey('yfrom') ? c.number('yfrom') : (c.args.containsKey('y') ? c.number('y') : scene.y);
    final toX = c.args.containsKey('xto') ? c.number('xto') : fromX;
    final toY = c.args.containsKey('yto') ? c.number('yto') : fromY;
    final fromScaleX = c.args.containsKey('xscalefrom') ? c.number('xscalefrom') : (c.args.containsKey('xscale') ? c.number('xscale') : scene.scaleX);
    final fromScaleY = c.args.containsKey('yscalefrom') ? c.number('yscalefrom') : (c.args.containsKey('yscale') ? c.number('yscale') : scene.scaleY);
    final toScaleX = c.args.containsKey('xscaleto') ? c.number('xscaleto') : fromScaleX;
    final toScaleY = c.args.containsKey('yscaleto') ? c.number('yscaleto') : fromScaleY;
    final loop = c.flag('loop');
    final seconds = c.number('duration');
    final ease = c.value('ease');
    final future = animate(c.tag, seconds, (t) {
      scene.x = _lerp(fromX, toX, t);
      scene.y = _lerp(fromY, toY, t);
      scene.scaleX = _lerp(fromScaleX, toScaleX, t);
      scene.scaleY = _lerp(fromScaleY, toScaleY, t);
    }, ease: ease, loop: loop);
    if (loop && c.flag('block')) {
      warn('第 ${c.line} 行：${c.tag} 的 loop 与 block 同时为真，忽略 block');
    }
    if (c.flag('block') && !loop) await future;
  }

  // ============ CG 道具 ============

  Future<void> _cgItem(StoryCommand c) async {
    final image = c.value('image');
    final id = c.value('id');
    final key = id.isNotEmpty ? '${image}_$id' : image;
    final style = c.value('style', 'cg');
    if (style == 'blocker') {
      warn('第 ${c.line} 行：cgitem style=blocker 为原生专用精灵，参考端同样跳过');
      return;
    }
    if (style != 'cg') {
      warn('第 ${c.line} 行：cgitem style 未注册：$style');
      return;
    }
    if (image.isEmpty) {
      warn('第 ${c.line} 行：cgitem 缺少 image');
      return;
    }
    state.cgItems.remove(key);
    final item = CgItem(key, image)
      ..width = c.number('width').truncateToDouble()
      ..height = c.number('height').truncateToDouble();
    state.cgItems[key] = item;
    // 参考端 showCgItem：时长/延迟均以秒书写、毫秒执行，且不随播放速度缩放；
    // 时长<=0 时忽略延迟、直接置终值；时长>0 时先落初值，延迟期间保持初值。
    double dur(String k) => math.max(0.0, c.number(k));
    final hasPos = _hasPoint(c.value('pfrom')) && _hasPoint(c.value('pto'));
    final cfrom = _color(c.value('cfrom')), cto = _color(c.value('cto'));
    final hasColor = cfrom != null && cto != null;
    final alphaFrom = c.number('afrom', 1), alphaTo = c.number('ato', 1);
    final scaleFrom = c.number('sfrom', 1), scaleTo = c.number('sto', 1);
    final rfrom = c.number('rfrom', -1), rto = c.number('rto', 0);
    final ease = c.value('ease');
    final futures = <Future<void>>[];
    if (hasPos) {
      final from = _point(c.value('pfrom')), to = _point(c.value('pto'));
      final d = dur('pduration');
      if (d > 0) {
        item.x = from.dx;
        item.y = from.dy;
        futures.add(animate('cgitem:$key:pos', d, (t) {
          item.x = _lerp(from.dx, to.dx, t);
          item.y = _lerp(from.dy, to.dy, t);
        }, ease: ease, delay: dur('pdelay')));
      } else {
        item.x = to.dx;
        item.y = to.dy;
      }
    }
    // 参考端按 sfrom/sto 数值比较判定是否缩放（缺省各为 1）。
    if (scaleFrom != scaleTo) {
      final d = dur('sduration');
      if (d > 0) {
        item.scale = scaleFrom;
        futures.add(animate('cgitem:$key:scale', d, (t) {
          item.scale = _lerp(scaleFrom, scaleTo, t);
        }, ease: ease, delay: dur('sdelay')));
      } else {
        item.scale = scaleTo;
      }
    }
    if (hasColor) {
      final (fr, fg, fb, fa) = cfrom;
      final (tr, tg, tb, ta) = cto;
      final d = dur('aduration');
      if (d > 0) {
        item.tint = Color.from(alpha: 1, red: fr, green: fg, blue: fb);
        item.tintAlpha = fa;
        futures.add(animate('cgitem:$key:color', d, (t) {
          item.tint = Color.from(
            alpha: 1,
            red: _lerp(fr, tr, t),
            green: _lerp(fg, tg, t),
            blue: _lerp(fb, tb, t),
          );
          item.tintAlpha = _lerp(fa, ta, t);
        }, ease: ease, delay: dur('adelay')));
      } else {
        item.tint = Color.from(alpha: 1, red: tr, green: tg, blue: tb);
        item.tintAlpha = ta;
      }
    } else if (alphaFrom != alphaTo) {
      final d = dur('aduration');
      if (d > 0) {
        item.alpha = alphaFrom;
        futures.add(animate('cgitem:$key:alpha', d, (t) {
          item.alpha = _lerp(alphaFrom, alphaTo, t);
        }, ease: ease, delay: dur('adelay')));
      } else {
        item.alpha = alphaTo;
      }
    }
    if (rfrom <= 0) {
      final d = dur('rduration');
      if (d > 0) {
        futures.add(animate('cgitem:$key:rot', d, (t) {
          item.rotation = _lerp(rfrom, rto, t);
        }, ease: ease));
      } else {
        item.rotation += rto;
      }
    }
    if (c.flag('block')) await Future.wait(futures);
  }

  Future<void> _hideCgItem(StoryCommand c) async {
    final image = c.value('image'), id = c.value('id');
    final key = image.isNotEmpty || id.isNotEmpty
        ? (id.isNotEmpty ? '${image}_$id' : image)
        : null;
    final double seconds = c.args.containsKey('duration')
        ? c.number('duration')
        : c.number('fadetime', .13);
    final targets = key == null
        ? state.cgItems.values.toList()
        : state.cgItems.containsKey(key)
        ? [state.cgItems[key]!]
        : <CgItem>[];
    if (targets.isEmpty) return;
    final epoch = _epoch;
    final ease = c.value('ease');
    final futures = <Future<void>>[];
    for (final item in targets) {
      // 参考端 hide：淡出期间保持可见（root 仍在图层），结束后才销毁。
      final session = ++item.hideEpoch;
      final from = item.alpha;
      final fade = animate('cgitemHide:${item.key}', math.max(0.0, seconds), (t) {
        item.alpha = _lerp(from, 0, t);
      }, ease: ease);
      futures.add(fade.then((_) {
        if (epoch == _epoch &&
            item.hideEpoch == session &&
            state.cgItems[item.key] == item) {
          state.cgItems.remove(item.key);
          _changed();
        }
      }));
    }
    if (c.flag('block')) await Future.wait(futures);
  }

  // ============ avgdisplay ============

  Future<void> _avgDisplay(StoryCommand c) async {
    const styleMap = {1: 'animetext', 2: 'spine', 3: 'effect', 4: 'bgeffect', 5: 'bg', 6: 'animekv', 7: 'character'};
    const slotMap = {1: 'bgover', 2: 'charover', 3: 'cgover'};
    var style = c.value('style');
    final numericStyle = int.tryParse(style);
    if (numericStyle != null && styleMap.containsKey(numericStyle)) style = styleMap[numericStyle]!;
    var slot = c.value('slot');
    final numericSlot = int.tryParse(slot);
    if (numericSlot != null && slotMap.containsKey(numericSlot)) slot = slotMap[numericSlot]!;
    if (!['bgover', 'charover', 'cgover'].contains(slot)) {
      warn('第 ${c.line} 行：avgdisplay 槽位无效：$slot');
      return;
    }
    final id = c.value('id');
    final name = c.value('name');
    final seconds = scaled(c.number('duration', style == 'bg' ? .1 : 0));
    if (name.isEmpty) {
      state.avgDisplays.remove(id);
      _changed();
      return;
    }
    if (style != 'bg') {
      warn('第 ${c.line} 行：avgdisplay 样式参考端同样不支持：$style');
      return;
    }
    final item = AvgDisplayItem(id, ['bgover', 'charover', 'cgover'].contains(slot) ? slot : 'bgover', name);
    final from = c.args.containsKey('afrom') ? c.number('afrom') : 1.0;
    final to = c.args.containsKey('ato') ? c.number('ato') : 0.0;
    state.avgDisplays[id] = item;
    await _transition(c, 'avgdisplay:$id', seconds, (t) {
      item.alpha = _lerp(from, to, t);
    });
  }

  // ============ showitem ============

  Future<void> _showItem(StoryCommand c) async {
    final fadeMs = math.max(0.0, c.number('fadetime', .5)) * 1000;
    var style = c.value('style', 'photo');
    if (style != 'photo' && style != 'cutin') {
      if (_itemSlotInUse) {
        _itemSlotInUse = false;
        await _hideShowItems(fadeMs);
      }
      warn('第 ${c.line} 行：showitem 样式未注册：$style');
      return;
    }
    final image = c.value('image');
    var fadeStyle = c.value('fadestyle').trim().toLowerCase();
    const valid = [
      'fade',
      'horiz_expand_center',
      'horiz_expand_left2right',
      'horiz_expand_right2left',
      'vert_expand_center',
      'vert_expand_top2bottom',
      'vert_expand_bottom2top',
    ];
    if (!valid.contains(fadeStyle)) fadeStyle = 'fade';
    if (state.showItems.isNotEmpty) {
      await _hideShowItems(fadeMs);
    }
    final item = ShowItem(
      style: style,
      image: image,
      width: c.args.containsKey('width') ? c.number('width') : double.nan,
      offsetX: c.number('offsetx'),
      offsetY: c.number('offsety'),
      blackAlpha: c.number('black', .4).clamp(0.0, 1.0).toDouble(),
      fadeStyle: fadeStyle,
    );
    final expand = style == 'cutin' && fadeStyle != 'fade';
    final horiz = fadeStyle.startsWith('horiz');
    final targetW = item.width.isNaN ? (imageNaturalWidth?.call(image) ?? 100.0) : item.width;
    item.maskW = expand ? (horiz ? 0 : targetW) : 1280;
    item.maskH = expand ? (horiz ? 720 : 0) : 720;
    item.alpha = fadeMs > 0 && !expand ? 0 : 1;
    state.showItems.add(item);
    _itemSlotInUse = true;
    if (expand) {
      await animate('showItemMask', fadeMs / 1000, (t) {
        item.maskW = horiz ? _lerp(0, targetW, t) : targetW;
        item.maskH = horiz ? 720 : _lerp(0, 720, t);
      }, ease: 'OutQuad');
    } else if (item.alpha < 1) {
      await animate('showItem', fadeMs / 1000, (t) => item.alpha = t, ease: 'OutQuad');
    }
  }

  Future<void> _hideItem(StoryCommand c) async {
    final fadeMs = math.max(0.0, c.number('fadetime', .5)) * 1000;
    _itemSlotInUse = false;
    await _hideShowItems(fadeMs);
  }

  Future<void> _hideShowItems(double fadeMs) async {
    // 参考端 hideShowItem：淡出期间保持可见，结束后移除；重复隐藏为无操作。
    final old = state.showItems.where((it) => it.hideEpoch == 0).toList();
    if (old.isEmpty) return;
    if (fadeMs <= 0) {
      state.showItems.removeWhere(old.contains);
      _changed();
      return;
    }
    final epoch = _epoch;
    final futures = <Future<void>>[];
    for (final item in old) {
      final session = ++item.hideEpoch;
      final expand = item.style == 'cutin' && item.fadeStyle != 'fade';
      final horiz = item.fadeStyle.startsWith('horiz');
      Future<void> fade;
      if (expand) {
        // 展开式：遮罩收拢（压暗板随窗口展开度同步衰减，见 painter）。
        final fromW = item.maskW, fromH = item.maskH;
        fade = animate('hideItem:${item.hashCode}', fadeMs / 1000, (t) {
          if (item.hideEpoch != session) return;
          item.maskW = horiz ? fromW * (1 - t) : fromW;
          item.maskH = horiz ? fromH : fromH * (1 - t);
        }, ease: 'OutQuad');
      } else {
        // photo 参考端先重置 alpha=1；cutin+fade 从当前 alpha 续淡。
        if (item.style != 'cutin') item.alpha = 1;
        final from = item.alpha;
        fade = animate('hideItem:${item.hashCode}', fadeMs / 1000, (t) {
          if (item.hideEpoch != session) return;
          item.alpha = from * (1 - t);
        }, ease: 'OutQuad');
      }
      futures.add(fade.then((_) {
        if (epoch == _epoch && state.showItems.remove(item)) _changed();
      }));
    }
    await Future.wait(futures);
  }

  // ============ 立绘切入 ============

  Future<void> _characterCutin(StoryCommand c) async {
    final widgetId = c.value('widgetid');
    if (widgetId.isEmpty) {
      warn('第 ${c.line} 行：charactercutin 缺少 widgetID');
      return;
    }
    final fadeMs = scaled(c.number('fadetime', .4)) * 1000;
    final name = c.value('name');
    var fadeStyle = c.value('fadestyle').trim().toLowerCase();
    const valid = [
      'fade',
      'horiz_expand_center',
      'horiz_expand_left2right',
      'horiz_expand_right2left',
      'vert_expand_center',
      'vert_expand_top2bottom',
      'vert_expand_bottom2top',
    ];
    if (!valid.contains(fadeStyle)) fadeStyle = 'fade';
    final block = c.flag('block');
    if (name.isEmpty) {
      // 参考端 hideSlot：用窗口自身 fadestyle，淡出期间保持可见，结束后才销毁。
      final existing = state.cutins[widgetId];
      if (existing == null) return;
      final session = ++existing.hideEpoch;
      Future<void> fade;
      if (existing.fadeStyle == 'fade') {
        final from = existing.alpha;
        fade = animate('cutin:$widgetId', fadeMs / 1000, (t) {
          if (existing.hideEpoch == session) existing.alpha = from * (1 - t);
        });
      } else {
        final horiz = existing.fadeStyle.startsWith('horiz');
        final fromW = existing.maskW, fromH = existing.maskH;
        fade = animate('cutin:$widgetId', fadeMs / 1000, (t) {
          if (existing.hideEpoch != session) return;
          existing.maskW = horiz ? fromW * (1 - t) : fromW;
          existing.maskH = horiz ? fromH : fromH * (1 - t);
        });
      }
      unawaited(fade.then((_) {
        if (existing.hideEpoch == session && state.cutins[widgetId] == existing) {
          state.cutins.remove(widgetId);
          _changed();
        }
      }));
      if (block) await fade;
      return;
    }
    final showCharacter = name != 'char_empty';
    final existing = state.cutins[widgetId];
    if (!showCharacter && existing == null) {
      warn('第 ${c.line} 行：charactercutin 未找到立绘 $name，仅展示空窗口');
    }
    if (existing != null) {
      final session = ++existing.hideEpoch;
      final fromX = existing.rootX, fromY = existing.rootY;
      final fromContentX = existing.contentX, fromContentY = existing.contentY;
      final fromZoom = existing.zoom, fromAlpha = existing.alpha;
      final fromMaskW = existing.maskW, fromMaskH = existing.maskH;
      final toX = c.args.containsKey('offsetx') ? 640 + c.number('offsetx') : fromX;
      final toY = c.args.containsKey('offsety') ? 360 - c.number('offsety') : fromY;
      final toContentX = c.args.containsKey('povx') ? -c.number('povx') : fromContentX;
      final toContentY = c.args.containsKey('povy') ? c.number('povy') : fromContentY;
      final toZoom = c.number('zoom', fromZoom);
      final toWidth = c.number('width', fromMaskW);
      final sameCharacter = showCharacter && existing.characters.isNotEmpty && existing.characters.last.name == name;
      final oldCharacters = sameCharacter ? <CutinCharacter>[] : existing.characters.toList();
      final next = !sameCharacter && showCharacter ? CutinCharacter(name, 0) : null;
      if (next != null) existing.characters.add(next);
      existing.fadeStyle = fadeStyle;
      existing.targetW = toWidth;
      final fade = animate('cutin:$widgetId', fadeMs / 1000, (t) {
        existing.alpha = _lerp(fromAlpha, 1, t);
        existing.rootX = _lerp(fromX, toX, t);
        existing.rootY = _lerp(fromY, toY, t);
        existing.contentX = _lerp(fromContentX, toContentX, t);
        existing.contentY = _lerp(fromContentY, toContentY, t);
        existing.zoom = _lerp(fromZoom, toZoom, t);
        existing.maskW = _lerp(fromMaskW, toWidth, t);
        existing.maskH = _lerp(fromMaskH, 720, t);
        for (final character in oldCharacters) {
          character.alpha = 1 - t;
        }
        if (next != null) next.alpha = t;
      }).then((_) {
        if (existing.hideEpoch == session && state.cutins[widgetId] == existing) {
          existing.characters.removeWhere(oldCharacters.contains);
          _changed();
        }
      });
      if (block) await fade;
      return;
    }
    final window = CutinWindow(widgetId)
      ..fadeStyle = fadeStyle
      ..characters.addAll(showCharacter ? [CutinCharacter(name, 1)] : [] )
      ..charOffsetX = c.number('charoffsetx')
      ..charOffsetY = c.number('charoffsety')
      ..rootX = 640 + c.number('offsetx')
      ..rootY = 360 - c.number('offsety')
      ..contentX = -c.number('povx')
      ..contentY = c.number('povy')
      ..zoom = c.number('zoom', 1)
      ..targetW = c.number('width', 200)
      ..targetH = 720;
    final horiz = fadeStyle.startsWith('horiz');
    window.maskW = fadeStyle == 'fade' ? window.targetW : (horiz ? 0 : window.targetW);
    window.maskH = fadeStyle == 'fade' ? 720 : (horiz ? 720 : 0);
    window.alpha = fadeStyle == 'fade' ? 0 : 1;
    state.cutins[widgetId] = window;
    if (fadeMs > 0) {
      final fade = animate('cutin:$widgetId', fadeMs / 1000, (t) {
        if (fadeStyle == 'fade') {
          window.alpha = t;
        } else if (horiz) {
          window.maskW = _lerp(0, window.targetW, t);
        } else {
          window.maskH = _lerp(0, 720, t);
        }
      });
      if (block) await fade;
    } else {
      window.alpha = 1;
      window.maskW = window.targetW;
      window.maskH = 720;
    }
  }

  // ============ 旁白 / 贴纸 / 印章 ============

  String _alignment(String value) {
    final raw = value.trim().toLowerCase();
    return ['left', 'center', 'right'].contains(raw) ? raw : 'left';
  }

  void _logOverlay(StoryCommand c) {
    final text = translate(c.value('text'));
    if (c.flag('hidelog') || text.isEmpty) return;
    _flushMultiline();
    _resetMultiline();
    if (c.flag('multi') && _overlayLogSource == c.tag && state.history.isNotEmpty) {
      final previous = state.history.last;
      state.history[state.history.length - 1] = DialogueLine('', previous.text + text, c.line);
    } else {
      state.history.add(DialogueLine('', text, c.line));
    }
    _overlayLogSource = c.flag('multi') ? c.tag : null;
  }
  Future<void> _subtitle(StoryCommand c) async {
    final text = translate(c.value('text'));
    if (text.isEmpty) {
      state.subtitle = null;
      _changed();
      return;
    }
    final x = c.number('x'), y = c.number('y');
    if (x < 0 || x > 1280 || y < 0 || y > 720) return;
    final width = math.min(c.number('width', 1280), 1280 - x);
    final overlay = OverlayText(
      'subtitle',
      x: x,
      y: y,
      width: width,
      size: c.number('size', 24),
      alignment: _alignment(c.value('alignment')),
    )
      ..text = text
      ..alpha = 1
      ..visible = true
      ..typingMs = currentSpeed.typingMs
      ..typingTime = 0
      ..revealed = 0;
    state.subtitle = overlay;
    _changed();
    _waitingInput = true;
  }

  Future<void> _sticker(StoryCommand c) async {
    final id = c.value('id');
    if (id.isEmpty) {
      warn('第 ${c.line} 行：sticker 缺少 id');
      return;
    }
    final multi = c.flag('multi');
    final existing = state.stickers[id];
    final duration = c.number('duration', -1);
    final fadeMs = (duration > 0 ? duration : .15) * 1000;
    final block = c.flag('block', existing == null);
    if (existing != null && !multi) {
      // 参考端 hideSticker：池淡出期间保持可见，从当前 alpha 续淡到 0。
      state.stickers.remove(id);
      state.stickers['#fading:$id'] = existing;
      final epoch = _epoch;
      final from = existing.alpha;
      unawaited(animate('stickerFade:$id', fadeMs / 1000, (t) {
        existing.alpha = from * (1 - t);
      }).then((_) {
        if (epoch == _epoch && state.stickers['#fading:$id'] == existing) {
          state.stickers.remove('#fading:$id');
          _changed();
        }
      }));
      _changed();
      if (block) _waitingInput = true;
      return;
    }
    final text = translate(c.value('text'));
    final x = c.number('x'), y = c.number('y');
    if (existing != null && multi) {
      existing.text += text;
      existing.typingTime = existing.revealed * existing.typingMs;
      _changed();
      if (block) _waitingInput = true;
      return;
    }
    if (x < 0 || x > 1280 || y < 0 || y > 720 || text.isEmpty) return;
    if (state.stickers.length >= 20) {
      warn('第 ${c.line} 行：sticker 数量达到上限 20');
    }
    final delay = double.tryParse(c.value('delay'));
    final overlay = OverlayText(
      id,
      x: x,
      y: y,
      width: math.min(c.number('width', 1280), 1280 - x),
      size: c.number('size', 24),
      alignment: _alignment(c.value('alignment')),
    )
      ..text = text
      ..alpha = 0
      ..visible = true
      ..typingMs = (delay == null ? 1 : delay / (baseTypingMs / 1000)) * currentSpeed.typingMs
      ..typingTime = 0
      ..revealed = 0;
    state.stickers[id] = overlay;
    unawaited(animate('stickerIn:$id', fadeMs / 1000, (t) => overlay.alpha = t));
    _changed();
    if (block) _waitingInput = true;
  }

  Future<void> _stickerTween(StoryCommand c) async {
    final id = c.value('id');
    final sticker = state.stickers[id];
    if (id.isEmpty || sticker == null) return;
    final isend = c.flag('isend');
    final queue = _stickerTweens.putIfAbsent(id, () => []);
    final hasPos = _hasPoint(c.value('pto'));
    final posFrom = _hasPoint(c.value('pfrom')) ? _point(c.value('pfrom')) : Offset(sticker.x, sticker.y);
    final posTo = hasPos ? _point(c.value('pto')) : posFrom;
    if (hasPos) {
      queue.add(_StickerStep('position', math.max(0.0, c.number('pduration')) * 1000, c.flag('join'), posFrom, posTo));
    }
    if (c.args.containsKey('rto')) {
      queue.add(_StickerStep('rotation', math.max(0.0, c.number('rduration')) * 1000, c.flag('join'), null, null,
          from: c.number('rfrom', 0), to: c.number('rto', 0)));
    }
    if (c.args.containsKey('ato')) {
      queue.add(_StickerStep('alpha', math.max(0.0, c.number('aduration')) * 1000, c.flag('join'), null, null,
          from: c.number('afrom', 0), to: c.number('ato', 0)));
    }
    if (!isend) return;
    _stickerTweens.remove(id);
    // join 步骤与上一步并行，否则顺序执行。
    var start = 0.0;
    final steps = <(double start, _StickerStep step)>[];
    var prevEnd = 0.0;
    for (final step in queue) {
      if (!step.join) {
        start = math.max(start, prevEnd);
        prevEnd = start;
      }
      steps.add((start, step));
      prevEnd = math.max(prevEnd, start + step.durationMs);
    }
    final totalMs = steps.fold<double>(0, (a, s) => math.max(a, s.$1 + s.$2.durationMs));
    final epoch = _epoch;
    final future = animate('stickerTween:$id', math.max(totalMs, 1) / 1000, (t) {
      final now = t * totalMs;
      for (final (startAt, step) in steps) {
        if (now < startAt) continue;
        final local = step.durationMs <= 0 ? 1.0 : ((now - startAt) / step.durationMs).clamp(0.0, 1.0);
        switch (step.kind) {
          case 'position':
            sticker.x = _lerp(step.fromPos!.dx, step.toPos!.dx, local);
            sticker.y = _lerp(step.fromPos!.dy, step.toPos!.dy, local);
          case 'rotation':
            sticker.rotation = _lerp(step.from, step.to, local);
          case 'alpha':
            sticker.alpha = _lerp(step.from, step.to, local);
        }
      }
    }).then((_) {
      if (epoch == _epoch) _changed();
    });
    if (c.flag('block') && isend) await future;
  }

  Future<void> _timerSticker(StoryCommand c) async {
    final limit = c.args.containsKey('time') ? c.number('time').round() : -1;
    final overlay = TimerSticker(
      x: c.number('x'),
      y: c.number('y'),
      width: c.number('width', 1280),
      size: c.number('size', 24),
    )
      ..limitSeconds = limit
      ..alpha = c.number('afrom', 0)
      ..visible = true
      ..elapsedSeconds = 0;
    if (limit > 0) overlay.startMicros = _nowUs();
    state.timer = overlay;
    final durationMs = math.max(0.0, c.number('duration', 1)) * 1000;
    final to = c.number('ato', 1);
    final from = overlay.alpha;
    unawaited(animate(
      'timer',
      (durationMs <= 0 ? 130.0 : durationMs) / 1000,
      (t) => overlay.alpha = _lerp(from, to, t),
    ));
    _changed();
  }

  Future<void> _timerClear(StoryCommand c) async {
    final timer = state.timer;
    if (timer == null) return;
    final durationMs = math.max(0.0, c.number('duration', .13)) * 1000;
    final from = timer.alpha;
    final epoch = _epoch;
    final future = animate('timerOut', durationMs / 1000, (t) => timer.alpha = from * (1 - t)).then((_) {
      if (epoch == _epoch) {
        if (state.timer == timer) state.timer = null;
        _changed();
      }
    });
    unawaited(future);
  }

  Future<void> _stickerClear(StoryCommand c) async {
    // 参考端 clearStickers(150)：池淡出期间保持可见，结束后移除；计时器立即清除。
    final epoch = _epoch;
    final old = state.stickers.entries
        .where((entry) => !entry.key.startsWith('#fading:'))
        .map((entry) => entry.value)
        .toList();
    state.stickers.removeWhere((key, _) => !key.startsWith('#fading:'));
    state.timer = null;
    _stickerTweens.clear();
    final futures = <Future<void>>[];
    for (final sticker in old) {
      final fadeKey = '#fading:${sticker.id}';
      state.stickers[fadeKey] = sticker;
      final from = sticker.alpha;
      futures.add(animate('stickerFade:${sticker.id}', .15, (t) {
        sticker.alpha = from * (1 - t);
      }).then((_) {
        if (epoch == _epoch && state.stickers[fadeKey] == sticker) {
          state.stickers.remove(fadeKey);
          _changed();
        }
      }));
    }
    _changed();
    if (c.flag('block')) await Future.wait(futures);
  }

  List<String> _stampSegments(String content) {
    final segments = <String>['', ''];
    final regex = RegExp(r'<p\s*=\s*(\d+)>(.*?)(?:</>|$)', dotAll: true);
    var matched = false;
    for (final match in regex.allMatches(content)) {
      matched = true;
      final index = (int.tryParse(match[1] ?? '') ?? 1) - 1;
      if (index >= 0 && index < segments.length) {
        segments[index] = (match[2] ?? '').trim();
      }
    }
    if (!matched) segments[0] = content.trim();
    return segments;
  }

  Future<void> _animText(StoryCommand c) async {
    final name = c.value('name');
    if (name != 'group_location_stamp') {
      warn('第 ${c.line} 行：animtext 名称参考端同样不支持：$name');
      return;
    }
    final pos = _point(c.value('pos'));
    final stamp = LocationStamp(Offset(pos.dx, -pos.dy), _stampSegments(c.text), c.value('style'));
    state.stamps.add(stamp);
    _changed();
    if (c.flag('block')) {
      await animate('stamp:${state.stamps.length}', 5, (_) {});
    }
  }

  // ============ interlude 通讯窗口 ============

  static const _interludeSizes = {
    'group_interclude_vertical_common': (320.0, 760.0),
    'group_interclude_square_common': (300.0, 300.0),
    'ui_cutin_mask_vertical': (337.3, 788.5),
    'ui_cutin_mask_horizon': (1689.2, 335.27),
    'interlude_dialog_left': (550.0, 570.0),
    'interlude_dialog_right': (620.0, 590.0),
  };

  InterludeElement _interludeElement(InterludeFrame frame, StoryCommand c) {
    final type = c.number('type').toInt();
    String key;
    if (type == 2) {
      key = 'bg';
    } else if (type == 3) {
      key = 'avatar';
    } else {
      key = _slot(c.value('slot'));
      if (key.isEmpty) key = 'm';
    }
    return frame.elements.putIfAbsent(key, () {
      final element = InterludeElement(key);
      // 参考端 ensureElement：r 槽位默认摆位 (-140, -63)，除非显式 pfrom/pto 覆盖。
      if (key == 'r') element.offset = const Offset(-140, -63);
      return element;
    });
  }

  Future<void> _interlude(StoryCommand c) async {
    final channelArg = c.value('channel');
    final channel = channelArg.isEmpty ? '-1' : channelArg;
    if (c.flag('clear')) {
      // 参考端 clear→hide：dialog 模板按 ato/aduration 淡出（缺省 0/500ms），
      // 其余模板按 tsto/tsduration 比例收拢窗口；淡出期间保持可见，结束后移除。
      final targets = channel == '-1'
          ? state.interludes.values.toList()
          : state.interludes.containsKey(channel)
          ? [state.interludes[channel]!]
          : <InterludeFrame>[];
      if (targets.isEmpty) return;
      final epoch = _epoch;
      final futures = <Future<void>>[];
      for (final frame in targets) {
        final session = ++frame.hideEpoch;
        final isDialog =
            frame.maskId == 'interlude_dialog_left' || frame.maskId == 'interlude_dialog_right';
        Future<void> fade;
        if (isDialog) {
          final double alphaTo = c.number('ato', -1) >= 0 ? c.number('ato') : 0;
          final scaled = c.number('aduration') * currentSpeed.animateRatio;
          final seconds = scaled > 0 ? scaled : .5;
          final from = frame.alpha;
          fade = animate('interludeClear:${frame.channel}', math.max(0.0, seconds), (t) {
            if (frame.hideEpoch == session) frame.alpha = _lerp(from, alphaTo, t);
          });
        } else {
          final to = _hasPoint(c.value('tsto')) ? _point(c.value('tsto')) : Offset.zero;
          final from = frame.templateScale;
          final scaled = c.number('tsduration') * currentSpeed.animateRatio;
          fade = animate('interludeClear:${frame.channel}', math.max(0.0, scaled), (t) {
            if (frame.hideEpoch != session) return;
            frame.templateScale = Offset.lerp(from, to, t)!;
          });
        }
        futures.add(fade.then((_) {
          if (epoch == _epoch &&
              frame.hideEpoch == session &&
              state.interludes[frame.channel] == frame) {
            state.interludes.remove(frame.channel);
            _changed();
          }
        }));
      }
      if (c.flag('block')) await Future.wait(futures);
      return;
    }
    if (channel == '-1') {
      warn('第 ${c.line} 行：interlude 缺少 channel');
      return;
    }
    final existing = state.interludes[channel];
    final InterludeFrame frame;
    if (existing != null) {
      frame = existing;
      frame.hideEpoch++;
      if (_animations.containsKey('interludeClear:$channel')) {
        _cancelAnimation('interludeClear:$channel');
        frame.alpha = 1;
        frame.templateScale = const Offset(1, 1);
      }
    } else {
      frame = InterludeFrame(channel)
        ..alpha = 1
        ..visible = true;
      state.interludes[channel] = frame;
    }
    final maskId = c.value('maskid');
    if (maskId.isNotEmpty) frame.maskId = maskId;
    frame.type = c.number('type').toInt();
    frame.style = c.value('style');
    frame.slot = c.value('slot');
    frame.charName = c.value('char');
    if (c.args.containsKey('size')) {
      final size = _point(c.value('size'));
      frame.size = size;
    }
    if (c.args.containsKey('offset')) frame.offset = _point(c.value('offset'));
    final name = c.value('name');
    if (name.isNotEmpty) {
      frame.name = name;
      if (frame.type == 3) frame.avatar = name;
    }
    if (c.args.containsKey('switch')) frame.visible = c.flag('switch');
    if (c.args.containsKey('icharpos')) frame.dialogCharOffset = _point(c.value('icharpos'));
    if (c.args.containsKey('icharscale')) frame.dialogCharScale = _point(c.value('icharscale'));
    // 模板尺寸：size 为 0 时用模板默认值。
    if (frame.size == Offset.zero) {
      final preset = _interludeSizes[frame.maskId];
      frame.size = preset == null ? const Offset(300, 300) : Offset(preset.$1, preset.$2);
    }
    // 元素：type=1 切入图 / type=2 背景图 / type=3 头像立绘。
    if (frame.type >= 1 && frame.type <= 3 && frame.name.isNotEmpty) {
      final element = _interludeElement(frame, c);
      element.image = frame.name;
      element.visible = frame.type != 3 || frame.avatar.isNotEmpty;
      final double alphaFrom = math.max(0.0, c.number('afrom', -1));
      final double alphaTo = c.number('ato', -1) >= 0 ? c.number('ato') : 1.0;
      final alphaDuration = math.max(0.0, c.number('aduration')) * currentSpeed.animateRatio;
      final hasPos = _hasPoint(c.value('pfrom')) && _hasPoint(c.value('pto'));
      final hasScale = _hasPoint(c.value('sfrom')) && _hasPoint(c.value('sto'));
      final duration = math.max(0.0, c.number('duration')) * currentSpeed.animateRatio;
      final futures = <Future<void>>[];
      if (alphaDuration > 0) {
        futures.add(animate('interlude:$channel:a', alphaDuration, (t) {
          element.alpha = _lerp(alphaFrom, alphaTo, t);
        }));
      } else {
        element.alpha = alphaTo;
      }
      if (hasPos) {
        final from = _point(c.value('pfrom')), to = _point(c.value('pto'));
        futures.add(animate('interlude:$channel:p', duration, (t) {
          element.offset = Offset(_lerp(from.dx, to.dx, t), -_lerp(from.dy, to.dy, t));
        }));
      }
      if (hasScale) {
        final from = _point(c.value('sfrom')), to = _point(c.value('sto'));
        futures.add(animate('interlude:$channel:s', math.max(0.0, c.number('sduration')) * currentSpeed.animateRatio, (t) {
          element.scale = Offset.lerp(from, to, t)!;
        }));
      }
      if (c.flag('block') && futures.isNotEmpty) await Future.wait(futures);
    }
    // 模板比例动画（参考端 startScaleEntry）：style 0/2 且 tsto 有效时从 tsfrom（缺省 0）展开。
    final tsto = _hasPoint(c.value('tsto')) ? _point(c.value('tsto')) : null;
    if ((frame.style.isEmpty || frame.style == '0' || frame.style == '2') &&
        tsto != null && (tsto.dx > 0 || tsto.dy > 0)) {
      final from = _hasPoint(c.value('tsfrom')) ? _point(c.value('tsfrom')) : Offset.zero;
      final duration = math.max(0.0, c.number('tsduration')) * currentSpeed.animateRatio;
      unawaited(animate('interlude:$channel:ts', duration, (t) {
        frame.templateScale = Offset.lerp(from, tsto, t)!;
      }));
    }
    _changed();
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    _ticker.cancel();
    _cancelAnimations();
    _cancelShake();
    _clock.stop();
    unawaited(audio.dispose());
    super.dispose();
  }
}

extension _LastWhereOrNull<T> on Iterable<T> {
  T? lastWhereOrNull(bool Function(T) test) {
    T? result;
    for (final item in this) {
      if (test(item)) result = item;
    }
    return result;
  }
}
