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
  });
  final PreparedStory story;
  final StoryAudio? audio;
  final PlaybackSettings settings;

  /// 可选恢复点：存在时开始画面额外提供「从上次继续」入口，
  /// 点击后才校验并恢复；不传入或进度失效时仅可从头播放。
  final PlaybackProgress? resumable;
  final Future<void> Function(PlaybackCheckpoint?)? onProgress;
  @override
  State<StoryPlayer> createState() => _StoryPlayerState();
}

class _StoryPlayerState extends State<StoryPlayer> with WidgetsBindingObserver {
  late final StoryEngine engine;
  final Map<Uri, ui.Image> textures = {};
  final Map<String, ui.Image> sprites = {};
  ui.FragmentShader? slideMaskShader;
  ui.Image? slideMask;
  static const fontFamily = 'StoryNotoSans';
  bool ready = false;
  bool _showingHistory = false;
  int _fastForwarding = 0;
  bool _resumeFailed = false, _progressErrorReported = false;
  int _savedRevision = 0;
  bool _scrubbing = false;
  double? _scrubPosition;
  bool _scrubWasPaused = false;
  bool _fineScrubbing = false;

  bool _progressHovered = false, _previewVisible = false;
  StoryStopPoint? _displayedPreviewStop;
  Timer? _previewDebounce, _previewShowTimer, _previewDismissTimer;
  Timer? _thumbSnapTimer;
  bool _thumbSnapping = false;
  StoryStopPoint? _previewStop;
  double? _scrubDragOriginY;
  double _scrubStartPosition = 0;
  double _finePull = 0;

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
    engine = StoryEngine(
      widget.story.document.script,
      variables: widget.story.catalog.variables,
      typingInterval: Duration(milliseconds: widget.settings.typingMs.round()),
      autoWaitSeconds: widget.settings.autoDelay,
      audio:
          widget.audio ??
          JustAudioOutput(
            widget.story.catalog,
            widget.story.assets,
            masterVolume: widget.settings.master,
            bgmVolume: widget.settings.bgm,
            sfxVolume: widget.settings.sfx,
            onWarning: (message) {
              if (mounted) {
                engine.warn(message);
                setState(() {});
              }
            },
          ),
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
      await engine.setPaused(true);
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
    if (state != AppLifecycleState.resumed) {
      unawaited(_saveProgress(force: true));
    }
    if (state != AppLifecycleState.resumed) unawaited(engine.setPaused(true));
  }

  void _progressChanged() => unawaited(_saveProgress());
  bool get _progressDisabled =>
      !ready ||
      engine.cursor == 0 ||
      engine.finished ||
      engine.state.metadata.isVideoOnly ||
      engine.state.choices.isNotEmpty;

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

  void _startScrub(DragStartDetails details, double width) {
    if (_progressDisabled) return;
    _thumbSnapTimer?.cancel();
    _thumbSnapping = false;
    _previewDebounce?.cancel();
    _previewShowTimer?.cancel();
    _previewDismissTimer?.cancel();
    _scrubbing = true;
    _fineScrubbing = false;
    _finePull = 0;
    _scrubDragOriginY = details.localPosition.dy;
    _scrubStartPosition = engine.progress;
    _previewStop = null;
    _displayedPreviewStop = null;
    _previewVisible = false;
    _scrubWasPaused = engine.paused;
    if (!_scrubWasPaused) unawaited(engine.setPaused(true));
    _previewShowTimer = Timer(const Duration(milliseconds: 200), () {
      if (!mounted || !_scrubbing) return;
      setState(() => _previewVisible = true);
    });
    _updateScrub(details.localPosition.dx, width);
  }

  void _updateFineScrub(DragUpdateDetails details, double width) {
    if (width <= 0 || _scrubPosition == null) return;
    final pull = _finePull + details.delta.dy;
    if (details.delta.dy < -4) {
      _finePull = 0;
      _fineScrubbing = false;
      _setScrubPosition(
        (_scrubPosition! + details.delta.dx / width).clamp(0.0, 1.0),
      );
      return;
    }
    _finePull = pull.clamp(0.0, 110.0);
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

  void _updateScrub(double dx, double width) {
    if (_progressDisabled || width <= 0) return;
    _setScrubPosition((dx / width).clamp(0.0, 1.0));
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
    _previewVisible = false;
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
    final wasPaused = _scrubWasPaused;
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
      if (!wasPaused) unawaited(engine.setPaused(false));
      return;
    }
    unawaited(() async {
      await engine.seekToStop(target);
      if (!mounted) return;
      setState(() => _scrubPosition = null);
      if (!wasPaused) await engine.setPaused(false);
    }());
  }

  void _cancelScrub() {
    if (!_scrubbing) return;
    final wasPaused = _scrubWasPaused;
    setState(() {
      _scrubbing = false;
      _fineScrubbing = false;
      _finePull = 0;
      _scrubDragOriginY = null;
      _scrubPosition = null;
    });
    _dismissPreview();
    if (!wasPaused) unawaited(engine.setPaused(false));
  }

  StageState _previewStageState(StoryStopPoint point) {
    final state = StageState();
    if (point.background.isNotEmpty) {
      state.backgrounds.add(StageImage(point.background));
    }
    state.characters.addAll([
      for (final character in point.characters)
        StageCharacter(character.slot, character.name),
    ]);
    return state;
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
      final targetThickness = _fineScrubbing
          ? 22.0
          : _scrubbing
          ? 10.0
          : _progressHovered
          ? 6.0
          : 4.0;
      return MouseRegion(
        onEnter: (_) {
          if (!_progressHovered) setState(() => _progressHovered = true);
        },
        onExit: (_) {
          if (_progressHovered) setState(() => _progressHovered = false);
        },
        child: AnimatedOpacity(
          opacity: engine.theaterMode ? 0 : (disabled ? .35 : 1),
          duration: const Duration(milliseconds: 200),
          child: IgnorePointer(
            ignoring: engine.theaterMode,
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: MediaQuery.sizeOf(context).width * .025,
              ),
              child: LayoutBuilder(
                builder: (context, constraints) => GestureDetector(
                  key: const Key('story-progress-hit-area'),
                  behavior: HitTestBehavior.opaque,
                  dragStartBehavior: DragStartBehavior.down,
                  onTapUp: disabled
                      ? null
                      : (details) {
                          _startScrub(
                            DragStartDetails(
                              localPosition: details.localPosition,
                            ),
                            constraints.maxWidth,
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
                            _updateScrub(
                              details.localPosition.dx,
                              constraints.maxWidth,
                            );
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
                              duration: Duration(
                                milliseconds: _fineScrubbing ? 160 : 120,
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
                                        ),
                                      ),
                                );
                              },
                            ),
                          ),
                        ),
                        if (_fineScrubbing)
                          const Positioned(
                            left: 0,
                            top: 30,
                            child: IgnorePointer(
                              child: Text(
                                '精细定位 · 灵敏度降低',
                                style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: 11,
                                  backgroundColor: Color(0x66000000),
                                ),
                              ),
                            ),
                          ),
                        if (previewStop != null)
                          AnimatedPositioned(
                            duration: const Duration(milliseconds: 120),
                            curve: Curves.easeOutCubic,
                            left:
                                ((constraints.maxWidth * position) -
                                        constraints.maxWidth *
                                            (_fineScrubbing ? .16 : .11))
                                    .clamp(
                                      0.0,
                                      constraints.maxWidth *
                                          (_fineScrubbing ? .68 : .78),
                                    ),
                            top: _fineScrubbing ? 68 : 36,
                            child: IgnorePointer(
                              child: AnimatedOpacity(
                                opacity: _previewVisible && _scrubbing ? 1 : 0,
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
                                        (_fineScrubbing ? .32 : .22),
                                    decoration: BoxDecoration(
                                      color: Colors.black.withValues(
                                        alpha: .92,
                                      ),
                                      border: Border.all(color: Colors.white54),
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
                                            switchInCurve: Curves.easeOutCubic,
                                            switchOutCurve: Curves.easeOut,
                                            transitionBuilder:
                                                (child, animation) =>
                                                    FadeTransition(
                                                      opacity: animation,
                                                      child: SlideTransition(
                                                        position: Tween<Offset>(
                                                          begin: const Offset(
                                                            0,
                                                            .04,
                                                          ),
                                                          end: Offset.zero,
                                                        ).animate(animation),
                                                        child: child,
                                                      ),
                                                    ),
                                            child: FittedBox(
                                              key: ValueKey(
                                                previewStop.commandIndex,
                                              ),
                                              fit: BoxFit.cover,
                                              child: SizedBox(
                                                width: 1280,
                                                height: 720,
                                                child: CustomPaint(
                                                  key: const Key(
                                                    'story-progress-preview-stage',
                                                  ),
                                                  size: const Size(1280, 720),
                                                  painter: StagePainter(
                                                    previewState!,
                                                    widget.story.catalog,
                                                    textures,
                                                    slideMask,
                                                    slideMaskShader,
                                                    sprites,
                                                    fontFamily: fontFamily,
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
                                            child: Text(
                                              '${previewStop.speaker.isEmpty ? '剧情' : previewStop.speaker}\n${previewStop.text}',
                                              key: ValueKey(
                                                'preview-text-${previewStop.commandIndex}',
                                              ),
                                              maxLines: 4,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 12,
                                                height: 1.25,
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

  Future<void> _showLog({bool diagnostics = false}) async {
    _fastForwardEnd();
    final wasPaused = engine.paused;
    await engine.setPaused(true);
    if (!mounted) return;
    if (diagnostics) {
      var copyStatus = '复制全部';
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (context) => SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(context).height * .8,
            child: Column(
              children: [
                StatefulBuilder(
                  builder: (context, setCopyState) => ListTile(
                    title: const Text('资源与指令诊断'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: copyStatus,
                          onPressed: engine.warnings.isEmpty
                              ? null
                              : () async {
                                  try {
                                    await Clipboard.setData(
                                      ClipboardData(
                                        text: engine.warnings.join('\n'),
                                      ),
                                    );
                                    if (context.mounted) {
                                      setCopyState(() => copyStatus = '已复制全部');
                                    }
                                  } catch (_) {
                                    if (context.mounted) {
                                      setCopyState(
                                        () => copyStatus = '复制失败，请重试',
                                      );
                                    }
                                  }
                                },
                          icon: Icon(
                            copyStatus == '已复制全部' ? Icons.check : Icons.copy,
                          ),
                        ),
                        IconButton(
                          tooltip: '关闭',
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      for (final message in engine.warnings)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: SelectableText(message),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    } else {
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
            if (target != null) await engine.seekToCommand(target);
          },
        ),
      );
      if (mounted) setState(() => _showingHistory = false);
    }
    if (mounted && !wasPaused) await engine.setPaused(false);
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
                      await engine.setPaused(false);
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
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            left: 0,
            right: 0,
            top:
                MediaQuery.sizeOf(context).height * .076 +
                (_fineScrubbing ? 36 : 0),
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
                                tooltip: '资源与指令诊断',
                                icon: Icons.info_outline,
                                onPressed: () => _showLog(diagnostics: true),
                                badge: engine.warnings.isNotEmpty,
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
    unawaited(_saveProgress());
    engine.removeListener(_progressChanged);
    slideMaskShader?.dispose();
    slideMask?.dispose();
    for (final texture in sprites.values) {
      texture.dispose();
    }
    WidgetsBinding.instance.removeObserver(this);
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
  });

  final double value, thickness, thumbRadius;
  final bool disabled;

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
      oldDelegate.thumbRadius != thumbRadius;
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
                      return InkWell(
                        onTap: line.stopCommandIndex == null
                            ? null
                            : () => widget.onSelect(line),
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
                            ],
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
