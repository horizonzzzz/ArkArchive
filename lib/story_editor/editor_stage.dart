import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';

import 'package:material_ui/material_ui.dart';

import '../story_player/stage_state.dart';
import '../story_player/ui/story_stage.dart';
import 'editor_preview.dart';
import 'editor_project.dart';

typedef _Handle = ({
  int index,
  int sourceScene,
  int sourceBeat,
  int sourceCommand,
  bool inherited,
  String tag,
  String label,
  String keyName,
  Offset anchor,
  Offset position,
  bool yUp,
  double? width,
  double? fontSize,
  void Function(Offset) update,
  void Function(double width, double fontSize)? updateSubtitleBox,
});

/// 舞台继承对象覆盖请求（当前分镜拖动继承自前序分镜的对象时触发）。
typedef StageInheritedRequest = ({
  String tag,
  String label,
  String keyName,
  String slot,
  int sourceScene,
  int sourceBeat,
  int sourceCommand,
  Map<String, String> values,
});
/// 编辑器监视器：以「播放头」语义渲染舞台——
/// 选中第 n 条指令时重放到该指令执行后的状态（P0-1）；
/// [selected] 为 -1 时保持分镜末态。
/// 结构（资产引用）变化才重新准备引擎；坐标类参数变化仅重放；
/// 对白文本/说话人变化就地更新对白框，打字时不闪屏（P0-1 伴生）。
class EditorStage extends StatefulWidget {
  const EditorStage({
    super.key,
    required this.project,
    required this.scene,
    required this.beat,
    required this.selected,
    required this.resources,
    required this.onMove,
    required this.onIssues,
    this.playing = false,
    this.loop = false,
    this.speed = 1,
    this.onPlayhead,
    this.onPlaybackEnded,
    this.onSelectCommand,
    this.onInheritedDrag,
  });

  final EditorProject project;
  final int scene, beat, selected;
  final EditorPreviewResources resources;
  final void Function(int index, Map<String, String> values) onMove;
  final Future<bool> Function(
    List<String> issues, {
    String title,
    bool allowExport,
  })
  onIssues;

  /// 传输条驱动的播放状态；播放沿当前分镜的停顿点推进。
  final bool playing;

  /// 只循环当前分镜。
  final bool loop;

  /// 播放节奏倍率：1 / 2 / 4。
  final int speed;

  /// 播放推进时同步页面播放头高亮（分镜内指令索引）。
  final void Function(int index)? onPlayhead;

  /// 非循环播放自然结束（播放到分镜末）时回调，页面复位播放按钮。
  final void Function()? onPlaybackEnded;

  /// 点击舞台未选中对象或左上角对象列表时选中对应指令。
  final void Function(int index)? onSelectCommand;

  /// 拖动继承自前序分镜的对象时通知页面弹出二选一（跳到来源/在当前分镜插入覆盖）。
  final Future<void> Function(StageInheritedRequest request)? onInheritedDrag;
  @override
  State<EditorStage> createState() => _EditorStageState();
}

class _EditorStageState extends State<EditorStage> {
  PreparedStage? _stage;
  Timer? _refresh;
  int _generation = 0;
  int _seekRevision = 0;
  Timer? _seekDebounce;
  Future<void> _seekQueue = Future.value();
  int _playToken = 0;
  Timer? _paceTimer;
  Completer<void>? _paceWaiter;
  int _beatStart = 0, _beatEnd = 0;
  String? _error;
  bool _loading = true;
  _Handle? _drag;
  Offset _point = Offset.zero;
  Offset _dragOrigin = Offset.zero;
  double? _dragWidth;
  double? _dragFontSize;
  String? _dragBubble;
  double? _snapGuideX;
  double? _snapGuideY;
  int? _hoveredHandle;
  double _zoom = 1.0;
  Offset _pan = Offset.zero;
  bool _spaceDown = false;
  bool _showObjects = false;
  late final FocusNode _focusNode;

  /// 播放推进同步给页面的播放头，避免页面重建被误判为用户 seek。
  int? _syncedPlayhead;

  /// 引擎构建时的文本签名；与 [_textSignature] 不一致说明脚本正文已落后。
  int _stageTextSignature = 0;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode(debugLabel: '剧情舞台');
    _prepare();
  }

  @override
  void didUpdateWidget(EditorStage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final projectChanged = oldWidget.project != widget.project;
    final positionChanged =
        oldWidget.scene != widget.scene || oldWidget.beat != widget.beat;
    if (positionChanged ||
        oldWidget.resources != widget.resources ||
        (projectChanged &&
            _assetSignature(oldWidget) != _assetSignature(widget))) {
      _prepare();
      return;
    }
    if (projectChanged) {
      if (_replaySignature(oldWidget) != _replaySignature(widget)) {
        // 参数/结构变化需要引擎执行新脚本：重建（100ms 防抖）。
        // 对白/舞台文字正文不在此列，走 [_syncTextsInPlace] 零重建。
        _prepare();
        return;
      } else {
        _syncTextsInPlace();
      }
    }
    if (oldWidget.selected != widget.selected) {
      if (_syncedPlayhead == widget.selected) {
        _syncedPlayhead = null;
      } else {
        _scheduleSeek();
      }
    }
    if (oldWidget.playing != widget.playing) {
      widget.playing ? _startPlayback() : _pausePlayback();
    }
  }

  /// 影响当前舞台重放的前缀指令（当前分镜含之前全部）。
  static Iterable<EditCommand> _prefixCommands(EditorStage stage) sync* {
    for (var s = 0; s <= stage.scene; s++) {
      final scene = stage.project.scenes[s];
      for (var b = 0; b < scene.beats.length; b++) {
        if (s == stage.scene && b > stage.beat) break;
        yield* scene.beats[b].commands;
      }
    }
  }

  /// 资产引用签名：决定是否重新准备引擎（纹理收集、引擎重建）。
  static String _assetPart(EditCommand command) => switch (command.tag) {
    'background' || 'image' => command.value('image'),
    'charslot' => command.value('name'),
    'playmusic' => '${command.value('key')}\u0001${command.value('intro')}',
    'playsound' => command.value('key'),
    'bgeffect' || 'effect' => command.value('name'),
    _ => '',
  };

  static int _assetSignature(EditorStage stage) => Object.hashAll([
    for (final c in _prefixCommands(stage)) (c.tag, c.raw, _assetPart(c)),
  ]);

  /// 重放签名：除表单对白（文本/说话人）与舞台文字正文外，任何参数变化都需要重放。
  /// 这些正文变化走 [_syncTextsInPlace]，避免打字时反复重放闪屏。
  static int _replaySignature(EditorStage stage) => Object.hashAll([
    for (final c in _prefixCommands(stage))
      (
        c.tag,
        c.raw,
        c.tag == 'dialogue' && c.raw == null
            ? 'dialogue'
            : [
                for (final e in c.args.entries)
                  if (!(c.tag == 'subtitle' &&
                      c.raw == null &&
                      e.key == 'text'))
                    '${e.key}=${e.value}',
              ].join('\u0001'),
      ),
  ]);

  /// 文本签名：对白/舞台文字正文的项目快照。引擎创建时脚本已固定，
  /// 就地同步只更新显示；播放前检测签名落后则重建引擎（完成后自动续播），
  /// 保证「改完马上复看」读的是当前文本。
  static int _textSignature(EditorStage stage) => Object.hashAll([
    for (final c in _prefixCommands(stage))
      (c.tag, c.raw, c.value('name'), c.value('text')),
  ]);

  void _prepare({bool immediate = false}) {
    _refresh?.cancel();
    _seekDebounce?.cancel();
    _seekRevision++;
    _playToken++;
    _cancelPace();
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _drag = null;
    });
    if (immediate) {
      unawaited(_prepareNow(generation));
    } else {
      _refresh = Timer(
        const Duration(milliseconds: 100),
        () => _prepareNow(generation),
      );
    }
  }

  Future<void> _prepareNow(int generation) async {
    bool active() => mounted && generation == _generation;
    PreparedStage? prepared;
    try {
      final textSignature = _textSignature(widget);
      final compiled = widget.project.compile();
      final range = compiled.ranges[(widget.scene, widget.beat)]!;
      final beatEnd = range.$2;
      prepared = await widget.resources.prepare(
        widget.project,
        compiled,
        end: beatEnd,
        audible: false,
        active: active,
      );
      if (!active()) throw StateError('预览已取消');
      final target = _targetEnd(range);
      final reached = await prepared.engine.rebuildBefore(target);
      if (!active()) throw StateError('预览已取消');
      _stage?.dispose();
      setState(() {
        _beatStart = range.$1;
        _beatEnd = beatEnd;
        _stage = prepared;
        _error = reached ? null : '无法重建此分镜的舞台';
        _loading = false;
      });
      // 记录引擎构建时的文本快照签名：此后就地编辑的正文不进脚本，
      // 播放前按此检测落后并重建。
      _stageTextSignature = textSignature;
      if (textSignature != _textSignature(widget)) {
        prepared = null;
        _prepare();
        return;
      }
      prepared = null;
      if (widget.playing) _startPlayback();
    } catch (e) {
      if (active()) {
        setState(() {
          _error = '舞台加载失败，请检查素材或脚本后重试';
          _loading = false;
        });
      }
    } finally {
      prepared?.dispose();
    }
  }

  /// 播放头目标：选中指令执行后的位置；未选中 = 分镜末态。
  int _targetEnd((int, int) range) {
    if (widget.selected < 0) return range.$2;
    return math.min(range.$1 + widget.selected + 1, range.$2);
  }

  void _scheduleSeek() {
    _seekDebounce?.cancel();
    _seekDebounce = Timer(const Duration(milliseconds: 100), _seekToPlayhead);
  }

  void _seekToPlayhead() {
    if (_stage == null || _loading) return;
    if (_stageTextSignature != _textSignature(widget)) {
      _prepare(immediate: true);
      return;
    }
    unawaited(_enqueueSeek(_targetEnd((_beatStart, _beatEnd))));
  }

  /// 串行化 seek：引擎重放不可并发，旧结果按修订号丢弃。
  Future<bool> _enqueueSeek(int target) {
    _seekRevision++;
    final revision = _seekRevision;
    final operation = _seekQueue.then(
      (_) => _performSeek(target, revision),
      onError: (_) => false,
    );
    _seekQueue = operation.then((_) {}, onError: (_) {});
    return operation;
  }

  Future<bool> _performSeek(int target, int revision) async {
    final stage = _stage;
    if (stage == null || revision != _seekRevision || !mounted) return false;
    final reached = await stage.engine.rebuildBefore(target);
    if (revision != _seekRevision || !mounted) return false;
    setState(() => _error = reached ? null : '无法重建此分镜的舞台');
    return reached;
  }

  /// 表单正文变化（对白/舞台文字）：不重放，直接同步显示。
  void _syncTextsInPlace() {
    final stage = _stage;
    final index = widget.selected;
    if (stage == null || index < 0 || _loading) return;
    final commands =
        widget.project.scenes[widget.scene].beats[widget.beat].commands;
    if (index >= commands.length) return;
    final command = commands[index];
    if (command.raw != null) return;
    switch (command.tag) {
      case 'dialogue':
        final text = command.value('text').replaceAll(r'\n', '\n');
        final speaker = command.value('name');
        final state = stage.engine.state;
        if (state.text == text && state.speaker == speaker) return;
        state.speaker = speaker;
        state.text = text;
        state.dialogueVisible = text.isNotEmpty;
        state.revealed = stage.engine.totalCharacters;
      case 'subtitle':
        _syncSubtitleInPlace(stage, command, commands, index);
    }
  }

  /// 舞台文字正文就地更新：播放头重放到选中指令执行后，
  /// state.subtitle 必然来自选中的这条指令（此前同名指令已被它覆盖），
  /// 可直接按项目当前值同步；布局参数变化仍走重放（重放签名含布局）。
  void _syncSubtitleInPlace(
    PreparedStage stage,
    EditCommand command,
    List<EditCommand> commands,
    int index,
  ) {
    final state = stage.engine.state;
    final text = command.value('text').replaceAll(r'\n', '\n');
    if (text.isEmpty) {
      state.subtitle = null; // 与引擎清除语义一致。
      return;
    }
    var overlay = state.subtitle;
    if (overlay == null || overlay.id != 'subtitle') {
      // 从清除状态恢复：按项目当前值就地重建覆盖层（与引擎 _subtitle 同规则）。
      double parse(String key, double fallback) =>
          double.tryParse(command.value(key)) ?? fallback;
      final x = parse('x', 240), y = parse('y', 300);
      if (x < 0 || x > 1280 || y < 0 || y > 720) return;
      final alignment = command.value('alignment').trim().toLowerCase();
      overlay =
          OverlayText(
              'subtitle',
              x: x,
              y: y,
              width: math.min(parse('width', 1280), 1280 - x),
              size: parse('size', 24),
              alignment: const ['left', 'center', 'right'].contains(alignment)
                  ? alignment
                  : 'left',
            )
            ..alpha = 1
            ..visible = true
            ..typingTime = 0;
      state.subtitle = overlay;
    }
    if (overlay.text == text && overlay.revealed >= text.runes.length) return;
    overlay.text = text;
    overlay.revealed = text.runes.length;
  }

  // —— 播放（P0-2）：沿停顿点推进，循环本段支持 —— //

  void _startPlayback() {
    if (_stage != null && _stageTextSignature != _textSignature(widget)) {
      // 就地编辑的正文未进入引擎脚本：先重建引擎，完成后自动续播。
      _prepare();
      return;
    }
    final token = ++_playToken;
    unawaited(_playLoop(token));
  }

  void _pausePlayback() {
    _playToken++;
    _cancelPace();
  }

  /// 播放节奏等待：显式管理 Timer，暂停/销毁时立即取消并唤醒循环。
  Future<void> _pace(Duration duration) {
    final waiter = Completer<void>();
    _paceWaiter = waiter;
    _paceTimer = Timer(duration, () {
      _paceWaiter = null;
      if (!waiter.isCompleted) waiter.complete();
    });
    return waiter.future;
  }

  void _cancelPace() {
    _paceTimer?.cancel();
    _paceTimer = null;
    final waiter = _paceWaiter;
    _paceWaiter = null;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
  }

  Future<void> _playLoop(int token) async {
    final stage = _stage;
    if (stage == null || token != _playToken) return;
    final engine = stage.engine;
    // 启动时已在末尾：无论是否循环都从头播放（「播放到末停止，再按从头」）；
    // 播放推进中到达末尾：循环则回绕，否则自然结束。
    var firstIteration = true;
    while (mounted && token == _playToken && widget.playing) {
      final finished = engine.finished || engine.cursor >= _beatEnd;
      if (finished) {
        if (widget.loop || firstIteration) {
          if (!await _enqueueSeek(_beatStart)) return;
        } else {
          // 自然结束：重放回分镜末态，保留对白框（advance 结束会清除对白框）。
          await _enqueueSeek(_beatEnd);
          _notifyPlayhead(math.max(0, _beatEnd - _beatStart - 1));
          widget.onPlaybackEnded?.call();
          return;
        }
      }
      firstIteration = false;
      await engine.advance();
      if (token != _playToken || !mounted) return;
      // 常驻监视器为无声预览：遇分支沿定位（rebuildBefore）的默认分支规则
      // 自动选择，避免卡在选项等待；分支交互保留给全屏试播。
      if (engine.state.choices.isNotEmpty) {
        final enabled = engine.state.choices
            .where((choice) => !choice.disabled)
            .toList();
        if (enabled.isEmpty) {
          setState(() => _error = '没有可用的分支选项');
          widget.onPlaybackEnded?.call();
          return;
        }
        await engine.choose(enabled.first.value);
        if (token != _playToken || !mounted) return;
      }
      final played = (engine.cursor - 1).clamp(_beatStart, _beatEnd - 1);
      _notifyPlayhead(played - _beatStart);
      await _pace(Duration(milliseconds: (400 / widget.speed).round()));
    }
  }

  void _notifyPlayhead(int index) {
    _syncedPlayhead = index;
    widget.onPlayhead?.call(index);
  }

  @override
  void dispose() {
    _refresh?.cancel();
    _seekDebounce?.cancel();
    _playToken++;
    _cancelPace();
    _focusNode.dispose();
    _stage?.dispose();
    super.dispose();
  }

  String _slot(String slot) => switch (slot.trim().toLowerCase()) {
    'left' || 'l' || 'char_left' => 'l',
    'right' || 'r' || 'char_right' => 'r',
    'm' || 'middle' || 'center' || 'c' || 'char_middle' => 'm',
    _ => '',
  };

  List<_Handle> _handles(PreparedStage stage) {
    final state = stage.engine.state;
    final handles = <_Handle>[];
    final seen = <String>{};
    var clearedSlots = false;

    // 从当前分镜倒序扫描到开头，包含继承自前序分镜但仍在舞台上显示的对象。
    final ordered = <(int s, int b, int c, EditCommand cmd)>[];
    for (var s = 0; s <= widget.scene; s++) {
      final scene = widget.project.scenes[s];
      for (var b = 0; b < scene.beats.length; b++) {
        if (s == widget.scene && b > widget.beat) break;
        final cmds = scene.beats[b].commands;
        for (var c = 0; c < cmds.length; c++) {
          ordered.add((s, b, c, cmds[c]));
        }
      }
    }

    for (var k = ordered.length - 1; k >= 0; k--) {
      final (s, b, c, command) = ordered[k];
      if (command.raw != null) continue;
      final inherited = s != widget.scene || b != widget.beat;
      final localIndex = inherited ? -(k + 1) : c;
      switch (command.tag) {
        case 'background':
        case 'image':
          if (!seen.add(command.tag)) continue;
          final layer =
              (command.tag == 'image' ? state.images : state.backgrounds)
                  .lastOrNull;
          if (layer == null || layer.key != command.value('image')) continue;
          final origin = command.tag == 'image'
              ? const Offset(690, 360)
              : const Offset(590, 360);
          handles.add((
            index: localIndex,
            sourceScene: s,
            sourceBeat: b,
            sourceCommand: c,
            inherited: inherited,
            tag: command.tag,
            label: editorFields[command.tag]!.$1,
            keyName: command.value('image'),
            anchor: origin + Offset(layer.x, -layer.y),
            position: Offset(layer.x, layer.y),
            yUp: true,
            width: null,
            fontSize: null,
            update: (p) {
              layer.x = p.dx;
              layer.y = p.dy;
            },
            updateSubtitleBox: null,
          ));
        case 'charslot':
          final slot = _slot(command.value('slot'));
          if (slot.isEmpty) clearedSlots = true;
          if (clearedSlots || !seen.add(slot)) continue;
          final node = state.characters
              .where((node) => node.slot == slot)
              .lastOrNull;
          if (node == null ||
              (command.value('name').isNotEmpty &&
                  node.name != command.value('name'))) {
            continue;
          }
          final art = stage.catalog.character(node.name);
          final x = switch (slot) {
            'l' => 440.0,
            'r' => 840.0,
            _ => 640.0,
          };
          final y =
              720 - (art?.size.height ?? 440) / 2 - (art?.position.dy ?? 0);
          final slotLabel = switch (slot) {
            'l' => '左',
            'r' => '右',
            _ => '中',
          };
          handles.add((
            index: localIndex,
            sourceScene: s,
            sourceBeat: b,
            sourceCommand: c,
            inherited: inherited,
            tag: 'charslot',
            label: '立绘（$slotLabel）',
            keyName: '$slot:${node.name}',
            anchor: Offset(x + node.actionX, y - node.actionY),
            position: Offset(node.actionX, node.actionY),
            yUp: true,
            width: null,
            fontSize: null,
            update: (p) {
              node.actionX = p.dx;
              node.actionY = p.dy;
            },
            updateSubtitleBox: null,
          ));
        case 'subtitle':
          if (!seen.add(command.tag)) continue;
          final subtitle = state.subtitle;
          if (subtitle == null || command.value('text').isEmpty) continue;
          handles.add((
            index: localIndex,
            sourceScene: s,
            sourceBeat: b,
            sourceCommand: c,
            inherited: inherited,
            tag: 'subtitle',
            label: '舞台文字',
            keyName: command.value('text'),
            anchor: Offset(subtitle.x, subtitle.y),
            position: Offset(subtitle.x, subtitle.y),
            yUp: false,
            width: subtitle.width,
            fontSize: subtitle.size,
            update: (p) {
              subtitle.x = p.dx;
              subtitle.y = p.dy;
            },
            updateSubtitleBox: (w, fs) {
              subtitle.width = w;
              subtitle.size = fs;
            },
          ));
      }
    }
    return handles.reversed.toList();
  }

  String _format(double value) => value.toStringAsFixed(1);

  void _nudge(KeyEvent event) {
    if (event.logicalKey == LogicalKeyboardKey.space) {
      final down = event is KeyDownEvent || event is KeyRepeatEvent;
      if (_spaceDown != down) setState(() => _spaceDown = down);
      return;
    }
    if (event is! KeyDownEvent || widget.selected < 0) return;
    final commands =
        widget.project.scenes[widget.scene].beats[widget.beat].commands;
    if (widget.selected >= commands.length) return;
    final command = commands[widget.selected];
    final step = HardwareKeyboard.instance.isShiftPressed ? 10.0 : 1.0;
    final key = event.logicalKey;
    var dx = 0.0;
    var dy = 0.0;
    if (key == LogicalKeyboardKey.arrowLeft) dx = -step;
    if (key == LogicalKeyboardKey.arrowRight) dx = step;
    if (key == LogicalKeyboardKey.arrowUp) dy = step;
    if (key == LogicalKeyboardKey.arrowDown) dy = -step;
    if (dx == 0 && dy == 0) return;
    if (command.tag == 'charslot') {
      final parts = command.value('posto').split(',');
      final x = double.tryParse(parts.firstOrNull ?? '') ?? 0;
      final y = double.tryParse(parts.length > 1 ? parts[1] : '') ?? 0;
      widget.onMove(widget.selected, {
        'posto': '${_format(x + dx)},${_format(y + dy)}',
      });
    } else if (command.tag == 'background' ||
        command.tag == 'image' ||
        command.tag == 'subtitle') {
      final x = double.tryParse(command.value('x')) ?? 0;
      final y = double.tryParse(command.value('y')) ?? 0;
      final nextY = command.tag == 'subtitle' ? y - dy : y + dy;
      widget.onMove(widget.selected, {
        'x': _format(x + dx),
        'y': _format(nextY),
      });
    }
  }

  /// 计算吸附后的逻辑坐标及辅助线（舞台中心线、三分线、安全框与同台其他对象对齐，阈值 6px；Alt 临时关闭）。
  (Offset snapped, double? guideX, double? guideY) _applySnap(
    _Handle drag,
    Offset raw,
    List<_Handle> allHandles,
  ) {
    if (HardwareKeyboard.instance.isAltPressed) return (raw, null, null);
    const threshold = 6.0;
    final anchorOffset = drag.anchor - Offset(
      drag.position.dx,
      drag.yUp ? -drag.position.dy : drag.position.dy,
    );
    var stageX = anchorOffset.dx + raw.dx;
    var stageY = anchorOffset.dy + (drag.yUp ? -raw.dy : raw.dy);

    final candidatesX = <double>[
      640.0,
      1280.0 / 3,
      2560.0 / 3,
      64.0,
      1216.0,
      for (final other in allHandles)
        if (other.index != drag.index) other.anchor.dx,
    ];
    final candidatesY = <double>[
      360.0,
      240.0,
      480.0,
      36.0,
      684.0,
      for (final other in allHandles)
        if (other.index != drag.index) other.anchor.dy,
    ];

    double? hitX;
    var bestDx = threshold + 1;
    for (final c in candidatesX) {
      final d = (stageX - c).abs();
      if (d <= threshold && d < bestDx) {
        bestDx = d;
        hitX = c;
      }
    }
    double? hitY;
    var bestDy = threshold + 1;
    for (final c in candidatesY) {
      final d = (stageY - c).abs();
      if (d <= threshold && d < bestDy) {
        bestDy = d;
        hitY = c;
      }
    }

    var sx = raw.dx;
    var sy = raw.dy;
    if (hitX != null) sx = hitX - anchorOffset.dx;
    if (hitY != null) {
      final deltaY = hitY - anchorOffset.dy;
      sy = drag.yUp ? -deltaY : deltaY;
    }
    return (Offset(sx, sy), hitX, hitY);
  }

  void _finishDrag(_Handle drag) {
    final x = _format(_point.dx);
    final y = _format(_point.dy);
    final values = drag.tag == 'charslot'
        ? {'posto': '$x,$y'}
        : {'x': x, 'y': y};
    if (drag.inherited) {
      // 先复原本地预览坐标，再让页面决定跳转到来源还是在当前分镜插入覆盖。
      drag.update(drag.position);
      final parts = drag.keyName.split(':');
      final slot = drag.tag == 'charslot' ? parts.first : '';
      final keyName = drag.tag == 'charslot' && parts.length > 1
          ? parts.sublist(1).join(':')
          : drag.keyName;
      widget.onInheritedDrag?.call((
        tag: drag.tag,
        label: drag.label,
        keyName: keyName,
        slot: slot,
        sourceScene: drag.sourceScene,
        sourceBeat: drag.sourceBeat,
        sourceCommand: drag.sourceCommand,
        values: values,
      ));
      return;
    }
    widget.onMove(drag.index, values);
  }

  Widget _outline(_Handle handle, Size size, double scale, bool selected) {
    final hovered = _hoveredHandle == handle.index;
    final primary = Theme.of(context).colorScheme.primary;
    // 舞台文字（subtitle）具备 width/size，按真实排版区域绘制变换框；立绘/背景/CG 仅绘制定位框。
    if (handle.tag == 'subtitle' && handle.width != null) {
      final w = (handle.width! * scale).clamp(48.0, size.width).toDouble();
      final h = ((handle.fontSize ?? 36) * 2.2 * scale)
          .clamp(32.0, size.height)
          .toDouble();
      final left = (handle.anchor.dx * scale)
          .clamp(0.0, math.max(0.0, size.width - w))
          .toDouble();
      final top = (handle.anchor.dy * scale)
          .clamp(0.0, math.max(0.0, size.height - h))
          .toDouble();
      return Positioned(
        left: left,
        top: top,
        width: w,
        height: h,
        child: IgnorePointer(
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(
                color: selected
                    ? primary
                    : hovered
                    ? primary.withValues(alpha: 0.65)
                    : Colors.white.withValues(alpha: 0.18),
                width: selected ? 2 : 1,
              ),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        ),
      );
    }
    return Positioned(
      left: (handle.anchor.dx * scale - 30).clamp(
        0.0,
        math.max(0.0, size.width - 60),
      ),
      top: (handle.anchor.dy * scale - 30).clamp(
        0.0,
        math.max(0.0, size.height - 60),
      ),
      child: IgnorePointer(
        child: Container(
          width: 60,
          height: 60,
          decoration: BoxDecoration(
            border: Border.all(
              color: selected
                  ? primary
                  : hovered
                  ? primary.withValues(alpha: 0.65)
                  : Colors.white.withValues(alpha: 0.16),
              width: selected ? 2 : 1,
            ),
            borderRadius: BorderRadius.circular(6),
          ),
        ),
      ),
    );
  }

  /// 仅对选中中的舞台文字（subtitle）提供右边缘调宽、右下角调字号的变换手柄（P0-4）。
  List<Widget> _subtitleTransformHandles(
    _Handle handle,
    Size size,
    double scale,
  ) {
    if (handle.tag != 'subtitle' ||
        handle.inherited ||
        handle.width == null ||
        handle.updateSubtitleBox == null) {
      return const [];
    }
    final width = _drag?.index == handle.index && _dragWidth != null
        ? _dragWidth!
        : handle.width!;
    final fontSize = _drag?.index == handle.index && _dragFontSize != null
        ? _dragFontSize!
        : (handle.fontSize ?? 36.0);
    final boxW = (width * scale).clamp(48.0, size.width).toDouble();
    final boxH = (fontSize * 2.2 * scale).clamp(32.0, size.height).toDouble();
    final left = (handle.anchor.dx * scale)
        .clamp(0.0, math.max(0.0, size.width - boxW))
        .toDouble();
    final top = (handle.anchor.dy * scale)
        .clamp(0.0, math.max(0.0, size.height - boxH))
        .toDouble();
    final primary = Theme.of(context).colorScheme.primary;
    return [
      // 右边缘：调宽度
      Positioned(
        key: ValueKey(('subtitle-width', handle.index)),
        left: (left + boxW - 8).clamp(0.0, math.max(0.0, size.width - 16)),
        top: (top + boxH / 2 - 12).clamp(0.0, math.max(0.0, size.height - 24)),
        child: Semantics(
          label: '调整文字宽度',
          child: MouseRegion(
            cursor: SystemMouseCursors.resizeLeftRight,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: (_) {
                setState(() {
                  _drag = handle;
                  _dragWidth = width;
                  _dragFontSize = fontSize;
                  _dragBubble = '宽 ${_format(width)}';
                });
              },
              onPanUpdate: (d) {
                final nextW = ((_dragWidth ?? width) + d.delta.dx / scale)
                    .clamp(120.0, 1280.0 - handle.anchor.dx);
                setState(() {
                  _dragWidth = nextW;
                  _dragBubble = '宽 ${_format(nextW)}';
                  handle.updateSubtitleBox!(nextW, _dragFontSize ?? fontSize);
                });
              },
              onPanEnd: (_) {
                final w = _dragWidth ?? width;
                setState(() {
                  _drag = null;
                  _dragWidth = null;
                  _dragFontSize = null;
                  _dragBubble = null;
                });
                widget.onMove(handle.index, {'width': _format(w)});
              },
              child: Container(
                width: 16,
                height: 24,
                alignment: Alignment.center,
                child: Container(
                  width: 6,
                  height: 18,
                  decoration: BoxDecoration(
                    color: primary,
                    borderRadius: BorderRadius.circular(3),
                    border: Border.all(color: Colors.white, width: 1),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
      // 右下角：调字号
      Positioned(
        key: ValueKey(('subtitle-size', handle.index)),
        left: (left + boxW - 8).clamp(0.0, math.max(0.0, size.width - 16)),
        top: (top + boxH - 8).clamp(0.0, math.max(0.0, size.height - 16)),
        child: Semantics(
          label: '调整文字字号',
          child: MouseRegion(
            cursor: SystemMouseCursors.resizeUpLeftDownRight,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: (_) {
                setState(() {
                  _drag = handle;
                  _dragWidth = width;
                  _dragFontSize = fontSize;
                  _dragBubble = '字号 ${fontSize.round()}';
                });
              },
              onPanUpdate: (d) {
                final delta = (d.delta.dx + d.delta.dy) * 0.25 / scale;
                final nextSize = ((_dragFontSize ?? fontSize) + delta).clamp(
                  14.0,
                  96.0,
                );
                setState(() {
                  _dragFontSize = nextSize;
                  _dragBubble = '字号 ${nextSize.round()}';
                  handle.updateSubtitleBox!(_dragWidth ?? width, nextSize);
                });
              },
              onPanEnd: (_) {
                final fs = _dragFontSize ?? fontSize;
                setState(() {
                  _drag = null;
                  _dragWidth = null;
                  _dragFontSize = null;
                  _dragBubble = null;
                });
                widget.onMove(handle.index, {'size': _format(fs)});
              },
              child: Container(
                width: 16,
                height: 16,
                alignment: Alignment.center,
                child: Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: primary,
                    border: Border.all(color: Colors.white, width: 1.5),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ];
  }

  Widget _handle(
    _Handle handle,
    List<_Handle> allHandles,
    Size size,
    double scale,
  ) {
    final index = handle.index;
    final tag = handle.tag;
    final label = handle.label;
    final selected =
        (!handle.inherited && widget.selected == index) ||
        _drag?.index == index;
    final hovered = _hoveredHandle == index;
    // P0-4：默认只显示选中对象的手柄；未选中对象保留可点击命中区并在 hover 时显形。
    final showGrip = selected || hovered;
    return Positioned(
      key: ValueKey(('drag', index)),
      left: (handle.anchor.dx * scale - 22).clamp(
        0.0,
        math.max(0.0, size.width - 44),
      ),
      top: (handle.anchor.dy * scale - 22).clamp(
        0.0,
        math.max(0.0, size.height - 44),
      ),
      child: Semantics(
        label: handle.inherited ? '拖动继承对象$label' : '拖动$label',
        child: MouseRegion(
          cursor: SystemMouseCursors.move,
          onEnter: (_) => setState(() => _hoveredHandle = index),
          onExit: (_) {
            if (_hoveredHandle == index) setState(() => _hoveredHandle = null);
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              _focusNode.requestFocus();
              if (!handle.inherited) widget.onSelectCommand?.call(index);
            },
            onPanStart: (_) {
              _drag = handle;
              _point = handle.position;
              _dragOrigin = handle.position;
              setState(() {
                _dragBubble = 'X ${_format(_point.dx)}  Y ${_format(_point.dy)}';
              });
            },
            onPanUpdate: (d) {
              final drag = _drag;
              if (drag == null) return;
              var raw =
                  _point +
                  Offset(d.delta.dx, drag.yUp ? -d.delta.dy : d.delta.dy) /
                      scale;
              // Shift 锁定单轴（水平或垂直）。
              if (HardwareKeyboard.instance.isShiftPressed) {
                final diff = raw - _dragOrigin;
                if (diff.dx.abs() >= diff.dy.abs()) {
                  raw = Offset(raw.dx, _dragOrigin.dy);
                } else {
                  raw = Offset(_dragOrigin.dx, raw.dy);
                }
              }
              final min = drag.yUp ? -1.0 : 0.0;
              raw = Offset(
                raw.dx.clamp(min * 1280, tag == 'subtitle' ? 1279.0 : 1280.0),
                raw.dy.clamp(min * 720, 720.0),
              );
              final (snapped, guideX, guideY) = _applySnap(
                drag,
                raw,
                allHandles,
              );
              _point = snapped;
              setState(() {
                _snapGuideX = guideX;
                _snapGuideY = guideY;
                _dragBubble =
                    'X ${_format(_point.dx)}  Y ${_format(_point.dy)}'
                    '${drag.inherited ? ' · 继承' : ''}';
                drag.update(_point);
              });
            },
            onPanCancel: () {
              final drag = _drag;
              if (drag != null) {
                setState(() {
                  drag.update(drag.position);
                  _drag = null;
                  _snapGuideX = null;
                  _snapGuideY = null;
                  _dragBubble = null;
                });
              }
            },
            onPanEnd: (_) {
              final drag = _drag;
              if (drag == null) return;
              setState(() {
                _drag = null;
                _snapGuideX = null;
                _snapGuideY = null;
                _dragBubble = null;
              });
              _finishDrag(drag);
            },
            child: SizedBox.square(
              dimension: 44,
              child: Center(
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 120),
                  opacity: showGrip ? 1.0 : 0.0,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: handle.inherited
                          ? const Color(0xCCDFC080)
                          : selected
                          ? Theme.of(context).colorScheme.primary
                          : Colors.black54,
                      shape: BoxShape.circle,
                    ),
                    child: const Padding(
                      padding: EdgeInsets.all(3),
                      child: Icon(
                        Icons.open_with,
                        color: Colors.white,
                        size: 16,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _setZoom(double next) {
    final clamped = next.clamp(0.5, 2.0);
    setState(() {
      _zoom = clamped;
      if ((clamped - 1.0).abs() < 0.01) _pan = Offset.zero;
    });
  }

  void _resetViewport() {
    setState(() {
      _zoom = 1.0;
      _pan = Offset.zero;
    });
  }

  Widget _hudOverlay(List<_Handle> handles) {
    final scheme = Theme.of(context).colorScheme;
    final zoomPct = '${(_zoom * 100).round()}%';
    return Stack(
      children: [
        // 左上角：舞台对象列表浮层按钮（P0-4）
        if (handles.isNotEmpty)
          Positioned(
            top: 6,
            left: 6,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Material(
                  color: const Color(0xCC111518),
                  borderRadius: BorderRadius.circular(6),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(6),
                    onTap: () => setState(() => _showObjects = !_showObjects),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.layers_outlined,
                            size: 14,
                            color: Color(0xFFE8EDF0),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '对象 ${handles.length}',
                            style: const TextStyle(
                              fontSize: 11,
                              color: Color(0xFFE8EDF0),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (_showObjects)
                  Container(
                    margin: const EdgeInsets.only(top: 4),
                    constraints: const BoxConstraints(
                      maxWidth: 210,
                      maxHeight: 160,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xE6171C20),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: const Color(0xFF354048)),
                    ),
                    child: ListView(
                      shrinkWrap: true,
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      children: [
                        for (final h in handles)
                          InkWell(
                            onTap: () {
                              if (!h.inherited) {
                                widget.onSelectCommand?.call(h.index);
                              } else {
                                final parts = h.keyName.split(':');
                                final slot = h.tag == 'charslot'
                                    ? parts.first
                                    : '';
                                final keyName =
                                    h.tag == 'charslot' && parts.length > 1
                                    ? parts.sublist(1).join(':')
                                    : h.keyName;
                                widget.onInheritedDrag?.call((
                                  tag: h.tag,
                                  label: h.label,
                                  keyName: keyName,
                                  slot: slot,
                                  sourceScene: h.sourceScene,
                                  sourceBeat: h.sourceBeat,
                                  sourceCommand: h.sourceCommand,
                                  values: h.tag == 'charslot'
                                      ? {
                                          'posto':
                                              '${_format(h.position.dx)},${_format(h.position.dy)}',
                                        }
                                      : {
                                          'x': _format(h.position.dx),
                                          'y': _format(h.position.dy),
                                        },
                                ));
                              }
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 5,
                              ),
                              child: Row(
                                children: [
                                  Container(
                                    width: 6,
                                    height: 6,
                                    decoration: BoxDecoration(
                                      color: h.inherited
                                          ? const Color(0xFFDFC080)
                                          : h.index == widget.selected
                                          ? scheme.primary
                                          : const Color(0xFF83939F),
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      h.inherited ? '${h.label}（继承）' : h.label,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: h.index == widget.selected
                                            ? scheme.primary
                                            : const Color(0xFFE8EDF0),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        // 右下角：50%–200% 缩放与适配控件（P0-4）
        Positioned(
          right: 6,
          bottom: 6,
          child: Material(
            color: const Color(0xCC111518),
            borderRadius: BorderRadius.circular(6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: '缩小舞台',
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(
                    minWidth: 26,
                    minHeight: 26,
                  ),
                  padding: EdgeInsets.zero,
                  iconSize: 14,
                  color: const Color(0xFFE8EDF0),
                  onPressed: _zoom > 0.5
                      ? () => _setZoom(_zoom - 0.25)
                      : null,
                  icon: const Icon(Icons.remove),
                ),
                InkWell(
                  onTap: _resetViewport,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Text(
                      zoomPct,
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFFE8EDF0),
                      ),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '放大舞台',
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(
                    minWidth: 26,
                    minHeight: 26,
                  ),
                  padding: EdgeInsets.zero,
                  iconSize: 14,
                  color: const Color(0xFFE8EDF0),
                  onPressed: _zoom < 2.0
                      ? () => _setZoom(_zoom + 0.25)
                      : null,
                  icon: const Icon(Icons.add),
                ),
                if (_zoom != 1.0 || _pan != Offset.zero)
                  IconButton(
                    tooltip: '适配窗口（双击舞台）',
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(
                      minWidth: 26,
                      minHeight: 26,
                    ),
                    padding: EdgeInsets.zero,
                    iconSize: 14,
                    color: const Color(0xFFA5C7D5),
                    onPressed: _resetViewport,
                    icon: const Icon(Icons.fit_screen),
                  ),
              ],
            ),
          ),
        ),
        // 拖动数值气泡
        if (_dragBubble != null)
          Positioned(
            top: 8,
            left: 0,
            right: 0,
            child: Center(
              child: IgnorePointer(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xE6111518),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: scheme.primary),
                  ),
                  child: Text(
                    _dragBubble!,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: Color(0xFFE8EDF0),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final baseScale = math.min(box.maxWidth / 1280, box.maxHeight / 720);
      if (baseScale <= 0 || !baseScale.isFinite) return const SizedBox.shrink();
      final viewport = Size(1280 * baseScale, 720 * baseScale);
      final scale = baseScale * _zoom;
      final size = Size(1280 * scale, 720 * scale);
      final stage = _stage;
      final warnings = [?_error, ...?stage?.engine.warnings];
      final handles = stage != null && !_loading
          ? _handles(stage)
          : const <_Handle>[];
      return KeyboardListener(
        focusNode: _focusNode,
        onKeyEvent: _nudge,
        child: SizedBox.fromSize(
          size: viewport,
          child: ClipRect(
            child: ColoredBox(
              color: const Color(0xff181c1f),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _focusNode.requestFocus,
                      onDoubleTap: _resetViewport,
                      onPanUpdate: _spaceDown || _zoom > 1.0
                          ? (d) => setState(() => _pan += d.delta)
                          : null,
                      child: const SizedBox.expand(),
                    ),
                  ),
                    Center(
                      child: Transform.translate(
                        offset: _pan,
                        child: OverflowBox(
                          maxWidth: size.width,
                          maxHeight: size.height,
                          child: SizedBox.fromSize(
                            size: size,
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                if (stage != null)
                                  IgnorePointer(
                                    child: StoryStage(
                                      engine: stage.engine,
                                      catalog: stage.catalog,
                                      textures: stage.textures,
                                    ),
                                  ),
                                // 吸附参考线
                                if (_snapGuideX != null)
                                  Positioned(
                                    left: (_snapGuideX! * scale)
                                        .clamp(0.0, size.width - 1),
                                    top: 0,
                                    bottom: 0,
                                    child: IgnorePointer(
                                      child: Container(
                                        width: 1,
                                        color: const Color(0xCC56B6C2),
                                      ),
                                    ),
                                  ),
                                if (_snapGuideY != null)
                                  Positioned(
                                    top: (_snapGuideY! * scale)
                                        .clamp(0.0, size.height - 1),
                                    left: 0,
                                    right: 0,
                                    child: IgnorePointer(
                                      child: Container(
                                        height: 1,
                                        color: const Color(0xCC56B6C2),
                                      ),
                                    ),
                                  ),
                                for (final handle in handles)
                                  _outline(
                                    handle,
                                    size,
                                    scale,
                                    !handle.inherited &&
                                        handle.index == widget.selected,
                                  ),
                                for (final handle in handles)
                                  if (!handle.inherited &&
                                      handle.index == widget.selected)
                                    ..._subtitleTransformHandles(
                                      handle,
                                      size,
                                      scale,
                                    ),
                                for (final handle in handles)
                                  _handle(handle, handles, size, scale),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    _hudOverlay(handles),
                    if (_loading)
                      const Align(
                        alignment: Alignment.topCenter,
                        child: LinearProgressIndicator(minHeight: 2),
                      ),
                    if (!_loading && warnings.isNotEmpty)
                      Positioned(
                        top: 0,
                        right: 0,
                        child: IconButton(
                          tooltip: '舞台提示',
                          color: Colors.amber,
                          icon: const Icon(Icons.warning_amber),
                          onPressed: () => widget.onIssues(warnings),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
      );
    },
  );
}
