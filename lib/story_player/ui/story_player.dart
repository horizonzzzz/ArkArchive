import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_theme.dart';
import '../data/media_catalog.dart';
import '../data/playback_progress.dart';
import '../data/story_repository.dart';
import '../data/playback_settings.dart';
import '../runtime/dialogue_voice.dart';
import '../runtime/local_dialogue_voice.dart';
import 'control_hub_sheet.dart';
import '../runtime/just_audio_output.dart';
import '../runtime/story_audio.dart';
import '../runtime/story_engine.dart';
import '../runtime/playback_checkpoint.dart';
import '../stage_state.dart';
import 'story_stage.dart';
import 'stage_painter.dart';
import 'story_text.dart';

/// 可直接由关卡选择页打开；生命周期和资源不依赖应用入口。
class StoryPlayer extends StatefulWidget {
  const StoryPlayer({
    super.key,
    required this.story,
    this.audio,
    this.settings = const PlaybackSettings(),
    this.resumable,
    this.onProgress,
    this.onSettingsChanged,
    this.onDiagnostics,
  });
  final PreparedStory story;
  final StoryAudio? audio;
  final PlaybackSettings settings;
  final ValueChanged<PlaybackSettings>? onSettingsChanged;
  final ValueChanged<List<String>>? onDiagnostics;

  /// 可选恢复点：存在时开始画面额外提供「从上次继续」入口，
  /// 点击后才校验并恢复；不传入或进度失效时仅可从头播放。
  final PlaybackProgress? resumable;
  final Future<void> Function(PlaybackCheckpoint?)? onProgress;
  @override
  State<StoryPlayer> createState() => _StoryPlayerState();
}

class _StoryPlayerState extends State<StoryPlayer> with WidgetsBindingObserver {
  late final StoryEngine engine;
  late final DialogueVoice _voice;
  late final StoryAudio _audioOutput;
  late PlaybackSettings _settings = widget.settings;
  bool _hubOpen = false;
  bool _lifecyclePaused = false;
  final Map<Uri, ui.Image> textures = {};
  final Map<String, ui.Image> sprites = {};
  ui.FragmentShader? slideMaskShader;
  ui.Image? slideMask;
  static const fontFamily = 'StoryNotoSans';
  bool ready = false;
  bool _showingHistory = false;
  int _fastForwarding = 0;
  bool _resumeFailed = false, _progressErrorReported = false;

  Future<void>? _seekQueue;
  int _savedRevision = 0;
  bool _scrubbing = false;
  double? _scrubPosition;

  bool _fineScrubbing = false;

  /// seek 黑闪：规格 §5-A8，100ms 入 / 180ms 出，掩盖确定性重放的瞬跳。
  bool _seekFlash = false;

  bool _progressHovered = false, _previewVisible = false;
  StoryStopPoint? _displayedPreviewStop;
  Timer? _previewDebounce, _previewShowTimer, _previewDismissTimer;
  Timer? _thumbSnapTimer;
  bool _thumbSnapping = false;
  StoryStopPoint? _previewStop;
  double? _scrubDragOriginX, _scrubDragOriginY;
  double _scrubStartPosition = 0;
  double _finePull = 0;

  /// 进度条自动隐藏（播放中让位给剧情）：顶部交互后显示约 3 秒，
  /// 无操作则淡出；拖动/黑闪/悬停期间保持显示。
  bool _progressRevealed = true;
  bool _topAreaHovered = false;

  int _lastCursor = 0;
  Timer? _progressHideTimer;
  static const _progressHideDelay = Duration(seconds: 3);

  /// 长按快进档位与换挡步长：每下滑一步（64 逻辑像素）提升一档。
  static const _fastForwardSpeeds = [2, 4, 8, 16];
  static const _fastForwardSlideStep = 64.0;
  Offset? _fastForwardOrigin;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]),
    );
    unawaited(
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky),
    );
    _voice = createDialogueVoice(volume: _settings.master * _settings.voice);
    _audioOutput = widget.audio ?? JustAudioOutput(
      widget.story.catalog, widget.story.assets,
      masterVolume: _settings.master, bgmVolume: _settings.bgm, sfxVolume: _settings.sfx,
      onWarning: (message) { if (mounted) { engine.warn(message); setState(() {}); } },
    );
    engine = StoryEngine(
      widget.story.document.script,
      variables: widget.story.catalog.variables,
      typingInterval: Duration(milliseconds: widget.settings.typingMs.round()),
      autoWaitSeconds: widget.settings.autoDelay,
      audio: _audioOutput,
      voice: _voice,
      characterArtSize: (name) {
        final art = widget.story.catalog.character(name);
        return art == null ? null : Offset(art.size.width, art.size.height);
      },
      imageNaturalWidth: (key) {
        final uri = widget.story.catalog.image(key, kind: 'images');
        return textures[uri]?.width.toDouble();
      },
    );
    engine.warnings.addAll(widget.story.warnings);
    engine.setSpeedLevel(_settings.speedLevel);
    engine.addListener(_progressChanged);
    unawaited(_prepare());
  }

  Future<void> _prepare() async {
    final uris = widget.story.catalog.dependencies(
      widget.story.document.script,
      [],
    );
    for (final uri in uris.where((u) => u.path.endsWith('.png'))) {
      final bytes = widget.story.assets.peek(uri);
      if (bytes == null) continue;
      try {
        final codec = await ui.instantiateImageCodec(bytes);
        final frame = await codec.getNextFrame();
        codec.dispose();
        if (!mounted) {
          frame.image.dispose();
          return;
        }
        textures[uri] = frame.image;
      } catch (e) {
        engine.warn('图片解码失败：$uri：$e');
      }
    }
    try {
      slideMaskShader = (await ui.FragmentProgram.fromAsset(
        'assets/shaders/slide_mask.frag',
      )).fragmentShader();
      final data = await rootBundle.load(MediaCatalog.slideMaskAsset);
      final codec = await ui.instantiateImageCodec(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
      slideMask = (await codec.getNextFrame()).image;
      codec.dispose();
    } catch (e) {
      engine.warn('滑动遮罩加载失败：$e');
    }
    for (final entry in _spriteAssets.entries) {
      try {
        final data = await rootBundle.load(entry.value);
        final codec = await ui.instantiateImageCodec(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        );
        sprites[entry.key] = (await codec.getNextFrame()).image;
        codec.dispose();
      } catch (e) {
        engine.warn('界面贴图加载失败：${entry.key}：$e');
      }
    }
    try {
      await (FontLoader(
        fontFamily,
      )..addFont(rootBundle.load(MediaCatalog.fontAsset))).load();
    } catch (e) {
      engine.warn('字体加载失败：$e');
    }
    if (!mounted) return;
    setState(() => ready = true);
    _progressChanged();
  }

  /// 校验可选恢复点并沿断点重放；失效时复用播放器内的断点失效界面。
  Future<void> _resumeFromCheckpoint() async {
    final saved = widget.resumable;
    if (saved == null) return;
    try {
      if (!saved.matches(widget.story.document.script)) {
        throw const FormatException('观看断点已失效');
      }
      await engine.restore(saved.checkpoint);
    } catch (_) {
      _resumeFailed = true;
      engine.theaterMode = false;

      if (mounted) setState(() {});
      return;
    }
    if (mounted) _progressChanged();
  }

  /// 参考播放器 widget 内嵌的 UI 贴图；用于地点印章、通讯窗口与相框。
  static const _spriteAssets = {
    'stamp_back_shadow': 'assets/images/prts_ui/stamp_back_shadow.png',
    'stamp_back_gradient': 'assets/images/prts_ui/stamp_back_gradient.png',
    'stamp_frame_outer': 'assets/images/prts_ui/stamp_frame_outer.png',
    'stamp_frame_inner': 'assets/images/prts_ui/stamp_frame_inner.png',
    'stamp_icon_back': 'assets/images/prts_ui/icon_back.png',
    'stamp_icon_comps': 'assets/images/prts_ui/stamp_icon_comps.png',
    'stamp_icon_start': 'assets/images/prts_ui/stamp_icon_start.png',
    'interlude_icon_back': 'assets/images/prts_ui/icon_back.png',
    'interlude_common_frame':
        'assets/images/prts_ui/interlude_common_frame.png',
    'interlude_gradient_v': 'assets/images/prts_ui/interlude_gradient_v.png',
    'showitem_photo_frame': 'assets/images/prts_ui/showitem_photo_frame.png',
    'showitem_cutin_header': 'assets/images/prts_ui/showitem_cutin_header.png',
  };

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _fastForwardEnd();
    _cancelScrub();
    _progressHideTimer?.cancel();
    if (state != AppLifecycleState.resumed) {
      unawaited(_saveProgress(force: true));
      if (!_lifecyclePaused && !engine.paused) {
        _lifecyclePaused = true;
        unawaited(engine.setPaused(true));
      }
    } else if (_lifecyclePaused) {
      _lifecyclePaused = false;
      if (!_hubOpen) unawaited(engine.setPaused(false));
    }
  }

  void _progressChanged() {
    unawaited(_saveProgress());
    // 开始播放的头几秒展示进度条（功能可发现性），随后自动让位给剧情。
    if (_lastCursor == 0 && engine.cursor > 0 && _progressRevealed) {
      _scheduleProgressHide();
    }
    _lastCursor = engine.cursor;
  }

  bool get _progressDisabled =>
      !ready ||
      engine.cursor == 0 ||
      engine.finished ||
      engine.state.metadata.isVideoOnly ||
      engine.state.choices.isNotEmpty;

  /// 进度条当前的可见态：拖动、黑闪与用户主动呼出任一成立即显示。
  bool get _progressActive => _scrubbing || _seekFlash || _progressRevealed;

  /// 呼出进度条并重新计时。
  void _revealProgress() {
    _progressHideTimer?.cancel();
    if (mounted && !_progressRevealed) {
      setState(() => _progressRevealed = true);
    }
    _scheduleProgressHide();
  }

  void _scheduleProgressHide() {
    _progressHideTimer?.cancel();
    _progressHideTimer = Timer(_progressHideDelay, () {
      if (!mounted) return;
      // 拖动或悬停中延后重试。
      if (_scrubbing || _topAreaHovered) {
        _scheduleProgressHide();
        return;
      }
      if (_seekFlash) return;
      if (_progressRevealed) setState(() => _progressRevealed = false);
    });
  }

  StoryStopPoint? _nearestStop(double position) {
    final points = engine.stopPoints;
    if (points.isEmpty) return null;
    final target = position * engine.script.commands.length;
    var low = 0, high = points.length;
    while (low < high) {
      final middle = (low + high) >> 1;
      if (points[middle].commandIndex < target) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    if (low == 0) return points.first;
    if (low == points.length) return points.last;
    final before = points[low - 1], after = points[low];
    return target - before.commandIndex <= after.commandIndex - target
        ? before
        : after;
  }

  /// [seekToPointer] 仅为单击跳转服务：按下点即映射为位置；
  /// 按住拖动（粗扫）走增量映射——起始比例 + Δx，拖回原位即可取消（§0/S4）。
  void _startScrub(
    DragStartDetails details,
    double width, {
    bool seekToPointer = false,
  }) {
    if (_progressDisabled) return;

    _thumbSnapTimer?.cancel();
    _thumbSnapping = false;
    _previewDebounce?.cancel();
    _previewShowTimer?.cancel();
    _previewDismissTimer?.cancel();
    _revealProgress();
    _scrubbing = true;
    _fineScrubbing = false;
    _finePull = 0;
    _scrubDragOriginX = details.localPosition.dx;
    _scrubDragOriginY = details.localPosition.dy;
    _scrubStartPosition = engine.progress;
    _previewStop = null;
    _displayedPreviewStop = null;
    _previewVisible = false;
    _previewShowTimer = Timer(const Duration(milliseconds: 200), () {
      if (!mounted || !_scrubbing) return;
      setState(() => _previewVisible = true);
    });
    _setScrubPosition(
      seekToPointer
          ? (details.localPosition.dx / width).clamp(0.0, 1.0)
          : _scrubStartPosition,
    );
  }

  void _updateFineScrub(DragUpdateDetails details, double width) {
    if (width <= 0 || _scrubPosition == null) return;

    // 精细深度随累积纵向位移变化：下拉加深、上滑回拉变浅。
    // 只有在回拉把深度拉回 0 时才退出精细模式；横向滑动因 dy≈0 不会
    // 误触退出（修复移动端"左右扫一下即恢复非精细"的问题）。退出时
    // 以当前手柄位置重新建立粗扫基准，避免跳点。
    _finePull = (_finePull + details.delta.dy).clamp(0.0, 110.0);
    if (_finePull <= 0) {
      _fineScrubbing = false;
      _scrubStartPosition = _scrubPosition!;
      _scrubDragOriginX = details.localPosition.dx;
      _scrubDragOriginY = details.localPosition.dy;
      setState(() {});
      return;
    }

    final depth = (_finePull / 110).clamp(0.0, 1.0);
    final eased = 1 - math.pow(1 - depth, 3).toDouble();
    final sensitivity = 1 - .82 * eased;
    _setScrubPosition(
      (_scrubPosition! + details.delta.dx / width * sensitivity).clamp(
        0.0,
        1.0,
      ),
    );
  }

  void _setScrubPosition(double position) {
    final stop = _nearestStop(position);
    final changedStop = stop?.commandIndex != _previewStop?.commandIndex;
    setState(() {
      _scrubPosition = position;
      _previewStop = stop;
    });
    if (!changedStop) return;
    _previewDebounce?.cancel();
    if (stop == null) {
      setState(() => _displayedPreviewStop = null);
      return;
    }
    _previewDebounce = Timer(const Duration(milliseconds: 80), () {
      if (!mounted ||
          !_scrubbing ||
          _previewStop?.commandIndex != stop.commandIndex) {
        return;
      }
      setState(() => _displayedPreviewStop = stop);
    });
  }

  /// 粗扫增量映射：位置 = 起始比例 + 手指相对按下点的水平位移（§1 位置层）。
  void _applyCoarseScrub(DragUpdateDetails details, double width) {
    if (_progressDisabled || width <= 0) return;
    final originX = _scrubDragOriginX;
    if (originX == null || _scrubPosition == null) return;
    _setScrubPosition(
      (_scrubStartPosition + (details.localPosition.dx - originX) / width)
          .clamp(0.0, 1.0),
    );
  }

  void _startFineScrub() {
    if (!_scrubbing || _fineScrubbing) return;
    _fineScrubbing = true;
    _finePull = 0;
  }

  void _dismissPreview() {
    _previewDebounce?.cancel();
    _previewShowTimer?.cancel();
    _previewDismissTimer?.cancel();
    if (mounted && _previewVisible) setState(() => _previewVisible = false);
    _previewDismissTimer = Timer(const Duration(milliseconds: 220), () {
      if (!mounted || _scrubbing) return;
      setState(() {
        _previewStop = null;
        _displayedPreviewStop = null;
      });
    });
  }

  void _finishScrub({bool allowSmallSeek = false}) {
    if (!_scrubbing) return;
    final position = _scrubPosition ?? engine.progress;
    final moved = (position - _scrubStartPosition).abs();
    final shouldSeek = allowSmallSeek || moved >= .015;

    final target = shouldSeek ? _nearestStop(position) : null;

    final snapPosition = target == null
        ? _scrubStartPosition
        : ((target.commandIndex + 1) / engine.script.commands.length).clamp(
            0.0,
            1.0,
          );
    setState(() {
      _scrubbing = false;
      _fineScrubbing = false;
      _finePull = 0;
      _scrubDragOriginX = null;
      _scrubDragOriginY = null;
      _scrubPosition = snapPosition;
      _thumbSnapping = true;
    });
    _dismissPreview();
    _thumbSnapTimer?.cancel();
    _thumbSnapTimer = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      setState(() {
        if (target == null) _scrubPosition = null;
        _thumbSnapping = false;
      });
    });
    if (target == null) {
      _revealProgress();
      return;
    }
    unawaited(_seekWithFlash(target.commandIndex));
  }

  /// 统一的 seek 通道：黑闪 100ms 入 → 确定性重放 → 黑闪 180ms 出（§5-A8）。
  /// 进度条松手、单击轨道与 Log 行跳转共用。
  Future<void> _seekWithFlash(int commandIndex) {
    final previous = _seekQueue;
    final operation = previous == null
        ? _performSeekWithFlash(commandIndex)
        : previous.then((_) => _performSeekWithFlash(commandIndex));
    _seekQueue = operation;
    return operation;
  }

  Future<void> _performSeekWithFlash(int commandIndex) async {
    if (!mounted) return;

    setState(() => _seekFlash = true);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final ok = await engine.seekToCommand(commandIndex);

    if (!mounted) return;
    if (!ok) {
      engine.warn('第 ${commandIndex + 1} 条命令附近无法跳转：可能存在无法自动抉择的全禁用分支。');
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('该处剧情暂不支持跳转')));
    }
    setState(() => _seekFlash = false);
    // 快速连拖时旧回调不得清掉进行中的新拖动位置。
    if (!mounted || _scrubbing) return;
    setState(() => _scrubPosition = null);
    _revealProgress();
  }

  void _cancelScrub() {
    if (!_scrubbing) return;

    setState(() {
      _scrubbing = false;
      _fineScrubbing = false;
      _finePull = 0;
      _scrubDragOriginX = null;
      _scrubDragOriginY = null;
      _scrubPosition = null;
    });
    _dismissPreview();

    _revealProgress();
  }

  /// 跨句滚动切换（§3-B）：新卡 translateY(60%→0) 淡入，旧卡 translateY(0→−115%) 淡出。
  /// AnimatedSwitcher 对新旧 child 共用本 builder，按 key 判定方向。
  Widget _rollTransition(
    Widget child,
    Animation<double> animation, {
    required Key incomingKey,
  }) {
    final isIncoming = child.key == incomingKey;
    final slide = isIncoming
        ? Tween<Offset>(begin: const Offset(0, .6), end: Offset.zero)
        : Tween<Offset>(begin: Offset.zero, end: const Offset(0, -1.15));
    return FadeTransition(
      opacity: animation,
      child: SlideTransition(
        position: slide.animate(animation),
        child: RepaintBoundary(child: child),
      ),
    );
  }

  /// 信息区锁高布局（§3 callout「LayoutBuilder 锁高，交叠期间不跳动」）：
  /// Stack 尺寸只由当前新卡决定，旧卡贴顶摆放且超出部分由 Stack 裁剪——
  /// 旧卡滚出不会侵入画面区，新卡下方也不留黑块。
  Widget _previewStackLayout(
    Widget? currentChild,
    List<Widget> previousChildren,
  ) => Stack(
    alignment: Alignment.topLeft,
    clipBehavior: Clip.hardEdge,
    children: [
      for (final previous in previousChildren)
        Positioned(top: 0, left: 0, child: previous),
      if (currentChild != null)
        Align(alignment: Alignment.topLeft, child: currentChild),
    ],
  );

  StageState _previewStageState(StoryStopPoint point) {
    final state = StageState();
    if (point.background.isNotEmpty) {
      // fit 传摘要记录的 screenadapt（空串 = 不缩放），与真实舞台一致（所见即所得）。
      state.backgrounds.add(
        StageImage(point.background, fit: point.backgroundFit),
      );
    }
    state.characters.addAll([
      for (final character in point.characters)
        StageCharacter(character.slot, character.name)
          ..brightness = character.brightness,
    ]);
    return state;
  }

  /// 当前正在播放的停顿点序号（1 起始）；无障碍播报与排序行共用。
  StoryStopPoint? get _currentStop {
    if (engine.cursor == 0 || engine.state.history.isEmpty) return null;
    int? stopIndex;
    for (final line in engine.state.history) {
      if (line.stopCommandIndex != null) stopIndex = line.stopCommandIndex;
    }
    if (stopIndex == null) return null;
    final points = engine.stopPoints;
    var low = 0, high = points.length;
    while (low < high) {
      final middle = (low + high) >> 1;
      if (points[middle].commandIndex < stopIndex) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return low < points.length && points[low].commandIndex == stopIndex
        ? points[low]
        : null;
  }

  /// 无障碍（§6）：Slider 语义，value 为句序号；前后停顿点可开调操作。
  void _seekRelativeStop(int offset) {
    final current = _currentStop;
    final points = engine.stopPoints;
    if (points.isEmpty || _progressDisabled) return;
    var index = current == null
        ? -1
        : points.indexWhere((p) => p.commandIndex == current.commandIndex);
    if (index < 0) index = 0;
    final target = (index + offset).clamp(0, points.length - 1);
    unawaited(_seekWithFlash(points[target].commandIndex));
  }

  Widget _buildProgressBar() => AnimatedBuilder(
    animation: engine,
    builder: (context, _) {
      final disabled = _progressDisabled;
      final position = _scrubPosition ?? engine.progress;
      final previewStop = _displayedPreviewStop;
      final previewState = previewStop == null
          ? null
          : _previewStageState(previewStop);
      // 精细展开跟手连续（§5-A5）：深度 0→1 驱动轨道厚度 10→22 与面板下移。
      final fineDepth = (_finePull / 110).clamp(0.0, 1.0);
      final fineEased = 1 - math.pow(1 - fineDepth, 3).toDouble();
      final fineSensitivity = 1 - .82 * fineEased;
      final targetThickness = _scrubbing
          ? 10 + 12 * fineDepth
          : _progressHovered
          ? 6.0
          : 4.0;
      final currentStop = _currentStop;
      final stopPoints = engine.stopPoints;
      return MouseRegion(
        onEnter: (_) {
          _revealProgress();
          if (!_progressHovered) setState(() => _progressHovered = true);
        },
        onExit: (_) {
          if (_progressHovered) setState(() => _progressHovered = false);
        },
        child: AnimatedOpacity(
          key: const Key('story-progress-fade'),
          // 剧场模式与未开始完全不显示；其余隐藏态只受自动隐藏控制，
          // choices/结束等禁用态沿用 .35 半透明告知。
          opacity:
              engine.theaterMode ||
                  !ready ||
                  engine.cursor == 0 ||
                  !_progressActive
              ? 0
              : (disabled ? .35 : 1),
          duration: const Duration(milliseconds: 200),
          child: IgnorePointer(
            ignoring: engine.theaterMode,
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: MediaQuery.sizeOf(context).width * .025,
              ),
              child: LayoutBuilder(
                builder: (context, constraints) => Semantics(
                  label: '剧情进度',
                  value: currentStop == null || stopPoints.isEmpty
                      ? '未开始'
                      : '第 ${currentStop.ordinal} / ${stopPoints.length} 句',
                  increasedValue: '跳到下一句',
                  decreasedValue: '跳到上一句',
                  onIncrease: disabled ? null : () => _seekRelativeStop(1),
                  onDecrease: disabled ? null : () => _seekRelativeStop(-1),
                  child: GestureDetector(
                    key: const Key('story-progress-hit-area'),
                    behavior: HitTestBehavior.opaque,
                    dragStartBehavior: DragStartBehavior.down,
                    onTapUp: disabled
                        ? null
                        : (details) {
                            // 隐藏态轻点只呼出不跳转（防误触）；
                            // 显示态轻点才吸附最近停顿点跳转。
                            if (!_progressActive) {
                              _revealProgress();
                              return;
                            }
                            _startScrub(
                              DragStartDetails(
                                localPosition: details.localPosition,
                              ),
                              constraints.maxWidth,
                              seekToPointer: true,
                            );
                            _finishScrub(allowSmallSeek: true);
                          },
                    onPanStart: disabled
                        ? null
                        : (details) => _startScrub(
                            DragStartDetails(
                              localPosition: details.localPosition,
                            ),
                            constraints.maxWidth,
                          ),
                    onPanUpdate: disabled
                        ? null
                        : (details) {
                            final originY = _scrubDragOriginY;
                            if (!_fineScrubbing &&
                                originY != null &&
                                details.localPosition.dy - originY > 24) {
                              _startFineScrub();
                            }
                            if (_fineScrubbing) {
                              _updateFineScrub(details, constraints.maxWidth);
                            } else {
                              _applyCoarseScrub(details, constraints.maxWidth);
                            }
                          },
                    onPanEnd: disabled ? null : (_) => _finishScrub(),
                    onPanCancel: _cancelScrub,
                    child: SizedBox(
                      height: _scrubbing ? 200 : 28,
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Align(
                            alignment: Alignment.topCenter,
                            child: SizedBox(
                              key: const Key('story-progress-track'),
                              width: double.infinity,
                              height: 28,
                              child: TweenAnimationBuilder<double>(
                                tween: Tween<double>(
                                  begin: 4,
                                  end: targetThickness,
                                ),
                                // 精细跟手时不加缓动；按下展开 120ms（§5-A2），hover 增厚 80ms（§5-A1）。
                                duration: Duration(
                                  milliseconds: _scrubbing
                                      ? (fineDepth > 0 ? 0 : 120)
                                      : 80,
                                ),
                                curve: Curves.easeOutCubic,
                                builder: (context, thickness, _) {
                                  final thumbRadius = thickness <= 10
                                      ? 4 + (thickness - 4) * 2 / 3
                                      : 8 + (thickness - 10) / 6;
                                  return TweenAnimationBuilder<double>(
                                    tween: Tween<double>(end: position),
                                    duration: Duration(
                                      milliseconds: _thumbSnapping ? 300 : 0,
                                    ),
                                    curve: _thumbSnapping
                                        ? Curves.easeOutBack
                                        : Curves.linear,
                                    builder: (context, animatedPosition, _) =>
                                        CustomPaint(
                                          painter: _ProgressTrackPainter(
                                            value: animatedPosition,
                                            disabled: disabled,
                                            thickness: thickness,
                                            thumbRadius: thumbRadius,
                                            // 精细模式刻度点（S2）：随展开淡入。
                                            tickAlpha: _fineScrubbing
                                                ? fineEased
                                                : 0,
                                            tickFractions: [
                                              for (final stop in stopPoints)
                                                (stop.commandIndex + 1) /
                                                    engine
                                                        .script
                                                        .commands
                                                        .length,
                                            ],
                                          ),
                                        ),
                                  );
                                },
                              ),
                            ),
                          ),
                          if (_fineScrubbing)
                            Positioned(
                              key: const Key('story-fine-tag'),
                              left: 0,
                              top: 30,
                              child: IgnorePointer(
                                child: Text(
                                  // 实时倍率（§5-A5）：1.0 → 0.18 随下拉深度连续变化。
                                  '精细定位 · 灵敏度 ×${fineSensitivity.toStringAsFixed(2)} · 拉得越深越慢',
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 11,
                                    backgroundColor: Color(0x66000000),
                                  ),
                                ),
                              ),
                            ),
                          if (previewStop != null)
                            AnimatedPositioned(
                              // 跟手连续：精细展开时卡宽 22%→32%、下沉 36→68px（S2/§5-A5）。
                              duration: Duration(
                                milliseconds: _fineScrubbing ? 0 : 120,
                              ),
                              curve: Curves.easeOutCubic,
                              left:
                                  ((constraints.maxWidth * position) -
                                          constraints.maxWidth *
                                              (.11 + .05 * fineDepth))
                                      .clamp(
                                        0.0,
                                        constraints.maxWidth *
                                            (.78 - .10 * fineDepth),
                                      ),
                              top: 36 + 32 * fineDepth,
                              child: IgnorePointer(
                                child: AnimatedOpacity(
                                  opacity: _previewVisible && _scrubbing
                                      ? 1
                                      : 0,
                                  duration: Duration(
                                    milliseconds: _scrubbing ? 200 : 220,
                                  ),
                                  curve: Curves.easeOut,
                                  child: AnimatedScale(
                                    scale: _previewVisible && _scrubbing
                                        ? 1
                                        : .97,
                                    duration: Duration(
                                      milliseconds: _scrubbing ? 200 : 220,
                                    ),
                                    curve: Curves.easeOutCubic,
                                    alignment: Alignment.topCenter,
                                    child: Container(
                                      width:
                                          constraints.maxWidth *
                                          (.22 + .10 * fineDepth),
                                      decoration: BoxDecoration(
                                        color: Colors.black.withValues(
                                          alpha: .92,
                                        ),
                                        border: Border.all(
                                          color: Colors.white54,
                                        ),
                                        boxShadow: const [
                                          BoxShadow(
                                            color: Colors.black54,
                                            blurRadius: 12,
                                            offset: Offset(0, 6),
                                          ),
                                        ],
                                      ),
                                      clipBehavior: Clip.antiAlias,
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.stretch,
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          AspectRatio(
                                            aspectRatio: 16 / 9,
                                            child: AnimatedSwitcher(
                                              duration: const Duration(
                                                milliseconds: 160,
                                              ),
                                              switchInCurve:
                                                  Curves.easeOutCubic,
                                              switchOutCurve: Curves.easeOut,
                                              // 滚动式切换（§3-B）：新卡自下方 60% 滑入，
                                              // 旧卡向上 -115% 滚出；交叠期 RepaintBoundary
                                              // 隔离两块 1280x720 画面，避免快扫掉帧。
                                              transitionBuilder:
                                                  (
                                                    child,
                                                    animation,
                                                  ) => _rollTransition(
                                                    child,
                                                    animation,
                                                    // 黑幕态与画面态 key 不同，入场方向都要按「新卡」判定。
                                                    incomingKey:
                                                        previewStop.blockerDark
                                                        ? ValueKey(
                                                            'blocker-${previewStop.commandIndex}',
                                                          )
                                                        : ValueKey(
                                                            previewStop
                                                                .commandIndex,
                                                          ),
                                                  ),
                                              child: previewStop.blockerDark
                                                  ? DecoratedBox(
                                                      key: ValueKey(
                                                        'blocker-${previewStop.commandIndex}',
                                                      ),
                                                      decoration:
                                                          const BoxDecoration(
                                                            color: Colors.black,
                                                          ),
                                                      child: const Center(
                                                        child: Text(
                                                          '黑幕演出',
                                                          style: TextStyle(
                                                            color:
                                                                Colors.white54,
                                                            fontSize: 13,
                                                          ),
                                                        ),
                                                      ),
                                                    )
                                                  : FittedBox(
                                                      key: ValueKey(
                                                        previewStop
                                                            .commandIndex,
                                                      ),
                                                      fit: BoxFit.cover,
                                                      child: SizedBox(
                                                        width: 1280,
                                                        height: 720,
                                                        child: CustomPaint(
                                                          key: const Key(
                                                            'story-progress-preview-stage',
                                                          ),
                                                          size: const Size(
                                                            1280,
                                                            720,
                                                          ),
                                                          painter: StagePainter(
                                                            previewState!,
                                                            widget
                                                                .story
                                                                .catalog,
                                                            textures,
                                                            slideMask,
                                                            slideMaskShader,
                                                            sprites,
                                                            fontFamily:
                                                                fontFamily,
                                                          ),
                                                        ),
                                                      ),
                                                    ),
                                            ),
                                          ),
                                          Padding(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 12,
                                              vertical: 8,
                                            ),
                                            child: AnimatedSwitcher(
                                              duration: const Duration(
                                                milliseconds: 160,
                                              ),
                                              switchInCurve:
                                                  Curves.easeOutCubic,
                                              switchOutCurve: Curves.easeOut,
                                              layoutBuilder:
                                                  _previewStackLayout,
                                              transitionBuilder:
                                                  (
                                                    child,
                                                    animation,
                                                  ) => _rollTransition(
                                                    child,
                                                    animation,
                                                    incomingKey: ValueKey(
                                                      'preview-text-${previewStop.commandIndex}',
                                                    ),
                                                  ),
                                              // 无障碍（§6）：缩影卡台词同步 liveRegion。
                                              // key 必须挂在 AnimatedSwitcher 的直接 child 上，
                                              // 否则跨句不触发切换、滚动方向判定也会失效。
                                              child: Semantics(
                                                key: ValueKey(
                                                  'preview-text-${previewStop.commandIndex}',
                                                ),
                                                liveRegion: true,
                                                child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment
                                                          .stretch,
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    Text(
                                                      '第 ${previewStop.ordinal} / ${stopPoints.length} 句',
                                                      style: const TextStyle(
                                                        color: Colors.white54,
                                                        fontSize: 11,
                                                        height: 1.2,
                                                      ),
                                                    ),
                                                    const SizedBox(height: 2),
                                                    Text(
                                                      '${previewStop.speaker.isEmpty ? '剧情' : previewStop.speaker}\n${previewStop.text}',
                                                      maxLines: 4,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: const TextStyle(
                                                        color: Colors.white,
                                                        fontSize: 12,
                                                        height: 1.25,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );

  Future<void> _saveProgress({bool force = false}) async {
    if (!ready ||
        _resumeFailed ||
        widget.onProgress == null ||
        engine.checkpointRevision == 0) {
      return;
    }
    final revision = engine.finished ? -1 : engine.checkpointRevision;
    if (!force && revision == _savedRevision) return;
    final checkpoint = engine.checkpoint;
    if (!engine.finished && checkpoint == null) return;
    _savedRevision = revision;
    try {
      await widget.onProgress!(checkpoint);
    } catch (_) {
      if (mounted && !_progressErrorReported) {
        _progressErrorReported = true;
        engine.warn('无法保存观看进度，请检查存储权限或剩余空间。');
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('观看进度保存失败，请检查存储权限或剩余空间。')));
      }
    }
  }

  Future<void> _applyPlaybackSettings(PlaybackSettings value) async {
    final wasEnabled = _settings.voice > 0 && _settings.master > 0;
    setState(() => _settings = value);
    engine.configurePlayback(typing: Duration(milliseconds: value.typingMs.round()), autoDelay: value.autoDelay);
    widget.onSettingsChanged?.call(value);
    final output = _audioOutput;
    if (output is JustAudioOutput) {
      unawaited(output.updateVolumes(master: value.master, bgm: value.bgm, sfx: value.sfx));
    }
    await _voice.setVolume(value.master * value.voice);
    if (mounted && !wasEnabled && value.voice > 0 && value.master > 0) engine.speakCurrentDialogue();
  }

  Future<void> _showControlHub() async {
    if (_hubOpen || !mounted) return;
    _hubOpen = true;
    _fastForwardEnd();
    final wasPaused = engine.paused;
    if (!wasPaused) await engine.setPaused(true);
    if (!mounted) return;
    try {
      await showGeneralDialog<void>(
        context: context,
        barrierDismissible: true,
        barrierLabel: '关闭控制中心',
        barrierColor: const Color(0x99000000),
        transitionDuration: const Duration(milliseconds: 220),
        pageBuilder: (context, _, _) => Align(
          alignment: Alignment.centerRight,
          child: ControlHubSheet(
            engine: engine, settings: _settings,
            onSettingsChanged: (value) => unawaited(_applyPlaybackSettings(value)),
            speakers: {for (final command in widget.story.document.script.commands)
              if (command.tag == 'dialogue' || command.tag == 'multiline')
                engine.translate(command.value('name'))}.toList(),
          ),
        ),
        transitionBuilder: (context, animation, _, child) => SlideTransition(
          position: Tween(begin: const Offset(1, 0), end: Offset.zero).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
          child: child,
        ),
      );
    } finally {
      _hubOpen = false;
      if (mounted && !wasPaused) await engine.setPaused(false);
    }
  }

  Future<void> _showLog() async {
    _fastForwardEnd();
    if (!mounted) return;
    setState(() => _showingHistory = true);
      await showGeneralDialog<void>(
        context: context,
        barrierColor: const Color(0xc9000000),
        transitionDuration: const Duration(milliseconds: 150),
        pageBuilder: (context, _, _) => _DialogueHistory(
          history: engine.state.history,
          fontFamily: fontFamily,
          onSelect: (line) async {
            Navigator.of(context).pop();
            final target = line.stopCommandIndex;
            if (target == null) return;
            // Log 跳转与进度条走同一 seek 通道（§4）：黑闪 + 确定性重放。
            await _seekWithFlash(target);
          },
        ),
      );
      if (mounted) setState(() => _showingHistory = false);
  }

  void _setFastForward(int multiplier) {
    if (!mounted || _fastForwarding == multiplier) return;
    engine.setFastForward(multiplier);
    setState(() => _fastForwarding = multiplier);
  }

  /// 长按开始：进入 2 倍速快进；手动模式下剧情也会自动推进。
  void _fastForwardStart(Offset globalPosition) {
    _fastForwardOrigin = globalPosition;
    _setFastForward(2);
  }

  /// 按住下滑换挡：每下滑一步提升一档，上滑回退。
  void _fastForwardMove(Offset globalPosition) {
    final origin = _fastForwardOrigin;
    if (origin == null || _fastForwarding == 0) return;
    final level = ((globalPosition.dy - origin.dy) / _fastForwardSlideStep)
        .clamp(0.0, 3.0)
        .toInt();
    _setFastForward(_fastForwardSpeeds[level]);
  }

  void _fastForwardEnd() {
    _fastForwardOrigin = null;
    _setFastForward(0);
  }

  Widget _overlayButton({
    required String tooltip,
    required IconData icon,
    required VoidCallback? onPressed,
    bool badge = false,
  }) => IconButton(
    tooltip: tooltip,
    onPressed: onPressed,
    color: Colors.white.withValues(alpha: .8),
    disabledColor: Colors.white54,
    icon: Badge(isLabelVisible: badge, child: Icon(icon)),
  );

  @override
  Widget build(BuildContext context) => PopScope<void>(
    onPopInvokedWithResult: (didPop, _) {
      if (didPop) unawaited(_saveProgress(force: true));
    },
    child: Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        alignment: Alignment.center,
        children: [
          if (ready && !_resumeFailed)
            Positioned.fill(
              child: AnimatedOpacity(
                opacity: _scrubbing ? .55 : 1,
                duration: const Duration(milliseconds: 120),
                child: StoryStage(
                  engine: engine,
                  catalog: widget.story.catalog,
                  textures: textures,
                  slideMask: slideMask,
                  slideMaskShader: slideMaskShader,
                  sprites: sprites,
                  fontFamily: fontFamily,
                  showDialogue: !_showingHistory,
                  onFastForwardStart: _fastForwardStart,
                  onFastForwardMove: _fastForwardMove,
                  onFastForwardEnd: _fastForwardEnd,
                ),
              ),
            ),
          if (!ready)
            const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('正在解码演出资源…'),
                ],
              ),
            )
          else if (_resumeFailed)
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('观看断点已失效，无法恢复原观看位置。'),
                  TextButton(
                    onPressed: () async {
                      await engine.restart();
                      if (!mounted) return;
                      setState(() => _resumeFailed = false);
                      _progressChanged();
                    },
                    child: const Text('从头观看'),
                  ),
                ],
              ),
            )
          else
            AnimatedBuilder(
              animation: engine,
              builder: (context, _) {
                if (engine.cursor != 0 && !engine.finished) {
                  return const SizedBox.shrink();
                }
                final canResume =
                    widget.resumable != null &&
                    engine.cursor == 0 &&
                    !engine.finished;
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FilledButton.icon(
                      onPressed: engine.finished
                          ? engine.restart
                          : engine.start,
                      icon: Icon(
                        engine.finished ? Icons.replay : Icons.play_arrow,
                      ),
                      label: Text(engine.finished ? '重新播放' : '开始播放'),
                    ),
                    if (canResume) ...[
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white.withValues(alpha: .9),
                          side: BorderSide(
                            color: Colors.white.withValues(alpha: .3),
                          ),
                        ),
                        onPressed: _resumeFromCheckpoint,
                        icon: const Icon(Icons.history),
                        label: const Text('从上次继续'),
                      ),
                    ],
                  ],
                );
              },
            ),
          AnimatedPositioned(
            // 工具条正下方 8px（S0）：固定偏移 = 安全区 + 56 + 8，
            // 与窗口高宽比解耦，桌面窗口化不与工具条错位。
            // 精细态 duration 0 直接跟手；进出用 160ms 过渡（§5-A5）。
            duration: Duration(milliseconds: _fineScrubbing ? 0 : 160),
            curve: Curves.easeOut,
            left: 0,
            right: 0,
            top:
                MediaQuery.paddingOf(context).top +
                64 +
                36 * (_finePull / 110).clamp(0.0, 1.0),
            child: _buildProgressBar(),
          ),
          if (_fastForwarding > 0)
            Positioned.fill(
              child: IgnorePointer(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 24),
                    child: _FastForwardSpeedPanel(selected: _fastForwarding),
                  ),
                ),
              ),
            ),
          // seek 黑闪层（§5-A8）：100ms linear 入 / 180ms ease-out 出，最顶层。
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedOpacity(
                key: const Key('story-seek-flash'),
                opacity: _seekFlash ? 1 : 0,
                duration: Duration(milliseconds: _seekFlash ? 100 : 180),
                curve: _seekFlash ? Curves.linear : Curves.easeOut,
                child: const ColoredBox(color: Colors.black),
              ),
            ),
          ),
          // 顶部宽热区（工具条同高）：桌面鼠标移入即呼出进度条，
          // 轻点工具条空白同样呼出；不拦截工具条按钮，也不覆盖进度条条带。
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            height: MediaQuery.paddingOf(context).top + 64,
            child: MouseRegion(
              onEnter: (_) {
                _topAreaHovered = true;
                _revealProgress();
              },
              onExit: (_) {
                _topAreaHovered = false;
                _scheduleProgressHide();
              },
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _revealProgress,
                child: const SizedBox.expand(),
              ),
            ),
          ),
          AnimatedBuilder(
            animation: engine,
            builder: (context, _) => AnimatedOpacity(
              opacity: engine.theaterMode ? 0 : 1,
              duration: const Duration(milliseconds: 200),
              child: IgnorePointer(
                ignoring: engine.theaterMode,
                child: Align(
                  alignment: Alignment.topCenter,
                  child: SafeArea(
                    bottom: false,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          _overlayButton(
                            tooltip: '退出播放器',
                            icon: Icons.arrow_back,
                            onPressed: () => Navigator.pop(context),
                          ),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _overlayButton(
                                tooltip: '对话记录',
                                icon: Icons.history,
                                onPressed: () => _showLog(),
                              ),
                              _overlayButton(
                                tooltip: '控制中心',
                                icon: Icons.tune,
                                onPressed: _showControlHub,
                              ),
                              _overlayButton(
                                tooltip: engine.autoMode != 'default'
                                    ? '自动播放：开启'
                                    : '手动播放：开启',
                                icon: engine.autoMode != 'default'
                                    ? Icons.play_circle_outline
                                    : Icons.touch_app,
                                onPressed: !engine.state.metadata.isAutoable
                                    ? null
                                    : () => engine.setAutoMode(
                                        engine.autoMode == 'default'
                                            ? 'button_auto'
                                            : 'default',
                                      ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );

  @override
  void dispose() {
    _previewDebounce?.cancel();
    _thumbSnapTimer?.cancel();
    _previewShowTimer?.cancel();
    _previewDismissTimer?.cancel();
    _progressHideTimer?.cancel();
    unawaited(_saveProgress());
    engine.removeListener(_progressChanged);
    slideMaskShader?.dispose();
    slideMask?.dispose();
    for (final texture in sprites.values) {
      texture.dispose();
    }
    WidgetsBinding.instance.removeObserver(this);
    widget.onDiagnostics?.call(List.of(engine.warnings));
    engine.dispose();
    for (final texture in textures.values) {
      texture.dispose();
    }
    unawaited(SystemChrome.setPreferredOrientations(DeviceOrientation.values));
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    super.dispose();
  }
}

class _ProgressTrackPainter extends CustomPainter {
  const _ProgressTrackPainter({
    required this.value,
    required this.disabled,
    required this.thickness,
    required this.thumbRadius,
    this.tickAlpha = 0,
    this.tickFractions = const [],
  });

  final double value, thickness, thumbRadius, tickAlpha;
  final bool disabled;

  /// 精细模式下的停顿点刻度位置（命令比例），仅 tickAlpha > 0 时绘制。
  final List<double> tickFractions;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.height / 2;
    final activeX = (size.width * value).clamp(0.0, size.width);
    final track = Paint()
      ..color = Colors.white.withValues(alpha: disabled ? .24 : .25)
      ..strokeWidth = thickness
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset.zero.translate(0, center),
      Offset(size.width, center),
      track,
    );
    final active = Paint()
      ..color = disabled ? Colors.white38 : Colors.white.withValues(alpha: .85)
      ..strokeWidth = thickness
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(0, center), Offset(activeX, center), active);
    if (tickAlpha > 0) {
      // 停顿点刻度（S2）：3px 白点、50% 透明度，随精细展开淡入；
      // 相邻间距不足 6px 自动降采样，避免长剧密集刻度糊成一串。
      final tick = Paint()
        ..color = Colors.white.withValues(alpha: .5 * tickAlpha);
      var lastX = -6.0;
      for (final fraction in tickFractions) {
        final x = size.width * fraction;
        if (x - lastX < 6) continue;
        lastX = x;
        canvas.drawCircle(Offset(x, center), 1.5, tick);
      }
    }
    canvas.drawCircle(
      Offset(activeX, center),
      thumbRadius,
      Paint()..color = disabled ? Colors.white54 : Colors.white,
    );
  }

  @override
  bool shouldRepaint(_ProgressTrackPainter oldDelegate) =>
      oldDelegate.value != value ||
      oldDelegate.disabled != disabled ||
      oldDelegate.thickness != thickness ||
      oldDelegate.thumbRadius != thumbRadius ||
      oldDelegate.tickAlpha != tickAlpha ||
      oldDelegate.tickFractions.length != tickFractions.length;
}

class _DialogueHistory extends StatefulWidget {
  const _DialogueHistory({
    required this.history,
    required this.fontFamily,
    required this.onSelect,
  });

  final List<DialogueLine> history;
  final String fontFamily;
  final Future<void> Function(DialogueLine line) onSelect;

  @override
  State<_DialogueHistory> createState() => _DialogueHistoryState();
}

class _DialogueHistoryState extends State<_DialogueHistory> {
  final _scrollController = ScrollController();

  /// hover 中的显示行索引（reverse 列表索引，0 为最新一行）。
  int? _hoveredIndex;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Material(
    type: MaterialType.transparency,
    child: SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final scale = math
              .min(constraints.maxWidth / 1280, constraints.maxHeight / 720)
              .clamp(0.65, 2.0);
          final base = storyDialogueStyle(widget.fontFamily)
              .copyWith(fontSize: 24 * scale);
          return Stack(
            children: [
              if (widget.history.isEmpty)
                Center(child: Text('暂无对话记录', style: base))
              else
                Scrollbar(
                  controller: _scrollController,
                  thumbVisibility: true,
                  child: ListView.builder(
                    key: const Key('dialogue-history-list'),
                    controller: _scrollController,
                    reverse: true,
                    padding: EdgeInsets.fromLTRB(
                      constraints.maxWidth * .08,
                      60 * scale,
                      constraints.maxWidth * .08,
                      70 * scale,
                    ),
                    itemCount: widget.history.length,
                    itemBuilder: (context, index) {
                      final line =
                          widget.history[widget.history.length - 1 - index];
                      // reverse 列表第 0 项即最新一行：正在播放的当前句。
                      final isCurrent = index == 0;
                      final jumpable =
                          line.stopCommandIndex != null && !isCurrent;
                      final isHovered = _hoveredIndex == index;
                      return MouseRegion(
                        onEnter: jumpable
                            ? (_) => setState(() => _hoveredIndex = index)
                            : null,
                        onExit: isHovered
                            ? (_) => setState(() => _hoveredIndex = null)
                            : null,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: isCurrent
                                ? Colors.white.withValues(alpha: .06)
                                : null,
                          ),
                          child: InkWell(
                            hoverColor: Colors.white.withValues(alpha: .08),
                            onTap: jumpable
                                ? () => widget.onSelect(line)
                                : null,
                            child: Padding(
                              padding: EdgeInsets.only(bottom: 22 * scale),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  SizedBox(
                                    width: constraints.maxWidth * .14,
                                    child: Text(
                                      line.speaker,
                                      textAlign: TextAlign.right,
                                      textScaler: TextScaler.noScaling,
                                      style: base.copyWith(
                                        fontSize: 30 * scale,
                                        color: const Color(0xff929292),
                                      ),
                                    ),
                                  ),
                                  SizedBox(width: 32 * scale),
                                  Expanded(
                                    child: Text.rich(
                                      TextSpan(
                                        children: storyTextSpans(
                                          line.text,
                                          line.text.runes.length,
                                          base,
                                        ),
                                      ),
                                      textScaler: TextScaler.noScaling,
                                    ),
                                  ),
                                  if (isCurrent || (isHovered && jumpable))
                                    Padding(
                                      padding: EdgeInsets.only(
                                        left: 12 * scale,
                                      ),
                                      child: Text(
                                        isCurrent ? '当前句 ▸' : '跳转 ↵',
                                        style: base.copyWith(
                                          fontSize: 20 * scale,
                                          color: Colors.white54,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              Positioned(
                top: 4,
                right: 8,
                child: IconButton(
                  tooltip: '关闭对话记录',
                  onPressed: () => Navigator.pop(context),
                  color: Colors.white,
                  icon: const Icon(Icons.close),
                ),
              ),
            ],
          );
        },
      ),
    ),
  );
}

/// 长按快进时的倍速面板：竖向列出 2/4/8/16 倍速，样式对齐官方播放器——
/// 淡灰色半透明边框、框内近乎透明、直角；选中项为略粗的白色框，
/// 仅向右突出并承载快进图标；文字统一白色。
class _FastForwardSpeedPanel extends StatelessWidget {
  const _FastForwardSpeedPanel({required this.selected});

  final int selected;
  static const speeds = [2, 4, 8, 16];
  static const _itemExtent = 44.0;
  static const _width = 108.0;

  /// 选中框向右突出宽度（约为面板宽的 20%）。
  static const _protrusion = 20.0;
  static const _edgeColor = Color(0x59ffffff); // 淡灰描边：白 35%
  static const _panelFill = Color(0x38000000); // 近乎透明底：黑 22%
  static const _frameFill = Color(0x59000000); // 选中底：黑 35%

  @override
  Widget build(BuildContext context) {
    final selectedIndex = speeds.indexOf(selected);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(8 * (1 - t), 0),
          child: child,
        ),
      ),
      child: Semantics(
        label: '长按快进中，当前 $selected x倍速，下滑提升倍速',
        liveRegion: true,
        child: SizedBox(
          width: _width,
          height: speeds.length * _itemExtent,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // 面板主体：左边框、上下边框；右边框避开选中档位，由外凸白框跨越。
              Positioned.fill(
                child: DecoratedBox(
                  key: const Key('fast-forward-speed-panel'),
                  decoration: const BoxDecoration(
                    color: _panelFill,
                    border: Border(
                      top: BorderSide(color: _edgeColor),
                      left: BorderSide(color: _edgeColor),
                      bottom: BorderSide(color: _edgeColor),
                    ),
                  ),
                  child: Column(
                    children: [
                      for (final speed in speeds)
                        SizedBox(
                          key: ValueKey('fast-forward-speed-$speed'),
                          width: double.infinity,
                          height: _itemExtent,
                          // 选中档位由下方外凸白框绘制。
                          child: speed == selected
                              ? null
                              : Center(child: _label(speed)),
                        ),
                    ],
                  ),
                ),
              ),
              // 右边框分段补齐：选中档位上下各留空。
              if (selectedIndex > 0)
                Positioned(
                  top: 0,
                  right: 0,
                  width: 1,
                  height: selectedIndex * _itemExtent,
                  child: const ColoredBox(color: _edgeColor),
                ),
              if (selectedIndex < speeds.length - 1)
                Positioned(
                  bottom: 0,
                  right: 0,
                  width: 1,
                  height: (speeds.length - selectedIndex - 1) * _itemExtent,
                  child: const ColoredBox(color: _edgeColor),
                ),
              // 选中档位：白色 2px 直角框，向右突出并承载快进图标。
              Positioned(
                left: 0,
                top: selectedIndex * _itemExtent,
                width: _width + _protrusion,
                height: _itemExtent,
                child: DecoratedBox(
                  key: const Key('fast-forward-speed-selected-frame'),
                  decoration: BoxDecoration(
                    color: _frameFill,
                    border: Border.all(color: Colors.white, width: 2),
                  ),
                  child: Row(
                    children: [
                      Expanded(child: Center(child: _label(selected))),
                      const Padding(
                        padding: EdgeInsets.only(right: 4),
                        child: Icon(
                          Icons.fast_forward,
                          size: 20,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _label(int speed) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        '${speed}x',
        style: TextStyle(
          fontFamily: AppTypography.bender,
          fontFamilyFallback: const [AppTypography.sans],
          fontSize: 15,
          fontWeight: FontWeight.w700,
          letterSpacing: .5,
          color: Colors.white,
        ),
      ),
      const SizedBox(width: 4),
      Text(
        '倍速',
        style: TextStyle(
          fontFamily: AppTypography.sans,
          fontSize: 11,
          color: Colors.white,
        ),
      ),
    ],
  );
}
