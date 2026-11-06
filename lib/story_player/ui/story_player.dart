import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/media_catalog.dart';
import '../data/playback_progress.dart';
import '../data/story_repository.dart';
import '../data/playback_settings.dart';
import '../runtime/just_audio_output.dart';
import '../runtime/story_audio.dart';
import '../runtime/story_engine.dart';
import '../runtime/playback_checkpoint.dart';
import 'story_stage.dart';

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
  bool _fastForwarding = false;
  bool _resumeFailed = false, _progressErrorReported = false;
  int _savedRevision = 0;

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
    _setFastForward(false);
    if (state != AppLifecycleState.resumed) {
      unawaited(_saveProgress(force: true));
    }
    if (state != AppLifecycleState.resumed) unawaited(engine.setPaused(true));
  }

  void _progressChanged() => unawaited(_saveProgress());

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
    _setFastForward(false);
    final wasPaused = engine.paused;
    await engine.setPaused(true);
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .8,
          child: Column(
            children: [
              ListTile(
                title: Text(diagnostics ? '资源与指令诊断' : '对话记录'),
                trailing: IconButton(
                  tooltip: '关闭',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: diagnostics
                      ? [
                          for (final message in engine.warnings)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: SelectableText(message),
                            ),
                        ]
                      : [
                          for (final line in engine.state.history)
                            ListTile(
                              title: Text(StoryEngine.plainText(line.text)),
                              subtitle: line.speaker.isEmpty
                                  ? null
                                  : Text(line.speaker),
                            ),
                        ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (mounted && !wasPaused) await engine.setPaused(false);
  }

  void _setFastForward(bool value) {
    if (!mounted || _fastForwarding == value) return;
    engine.setFastForward(value);
    setState(() => _fastForwarding = value);
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
              child: StoryStage(
                engine: engine,
                catalog: widget.story.catalog,
                textures: textures,
                slideMask: slideMask,
                slideMaskShader: slideMaskShader,
                sprites: sprites,
                fontFamily: fontFamily,
                onFastForwardChanged: _setFastForward,
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
          if (_fastForwarding)
            Positioned.fill(
              child: IgnorePointer(
                child: Center(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 12,
                      ),
                      child: Text(
                        '2× 加速中',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
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
