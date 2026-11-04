import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../data/media_catalog.dart';
import '../data/story_repository.dart';
import '../data/playback_settings.dart';
import '../runtime/just_audio_output.dart';
import '../runtime/story_audio.dart';
import '../runtime/story_engine.dart';
import 'story_stage.dart';

/// 可直接由关卡选择页打开；生命周期和资源不依赖应用入口。
class StoryPlayer extends StatefulWidget {
  const StoryPlayer({super.key, required this.story, this.audio, this.settings = const PlaybackSettings()});
  final PreparedStory story;
  final StoryAudio? audio;
  final PlaybackSettings settings;
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]));
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky));
    engine = StoryEngine(widget.story.document.script,
      variables: widget.story.catalog.variables,
      typingInterval: Duration(milliseconds: widget.settings.typingMs.round()),
      autoWaitSeconds: widget.settings.autoDelay,
      audio: widget.audio ?? JustAudioOutput(widget.story.catalog, widget.story.assets, masterVolume: widget.settings.master, bgmVolume: widget.settings.bgm, sfxVolume: widget.settings.sfx, onWarning: (message) { if (mounted) { engine.warn(message); setState(() {}); } }),
      characterArtSize: (name) {
        final art = widget.story.catalog.character(name);
        return art == null ? null : Offset(art.size.width, art.size.height);
      },
      imageNaturalWidth: (key) {
        final uri = widget.story.catalog.image(key, kind: 'images');
        return textures[uri]?.width.toDouble();
      });
    engine.warnings.addAll(widget.story.warnings);
    unawaited(_prepare());
  }

  Future<void> _prepare() async {
    final uris = widget.story.catalog.dependencies(widget.story.document.script, []);
    for (final uri in uris.where((u) => u.path.endsWith('.png'))) {
      final bytes = widget.story.assets.peek(uri);
      if (bytes == null) continue;
      try {
        final codec = await ui.instantiateImageCodec(bytes);
        final frame = await codec.getNextFrame();
        codec.dispose();
        if (!mounted) { frame.image.dispose(); return; }
        textures[uri] = frame.image;
      } catch (e) { engine.warn('图片解码失败：$uri：$e'); }
    }
    try {
      slideMaskShader = (await ui.FragmentProgram.fromAsset('assets/shaders/slide_mask.frag')).fragmentShader();
      final data = await rootBundle.load(MediaCatalog.slideMaskAsset);
      final codec = await ui.instantiateImageCodec(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
      slideMask = (await codec.getNextFrame()).image;
      codec.dispose();
    } catch (e) { engine.warn('滑动遮罩加载失败：$e'); }
    for (final entry in _spriteAssets.entries) {
      try {
        final data = await rootBundle.load(entry.value);
        final codec = await ui.instantiateImageCodec(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
        sprites[entry.key] = (await codec.getNextFrame()).image;
        codec.dispose();
      } catch (e) { engine.warn('界面贴图加载失败：${entry.key}：$e'); }
    }
    try { await (FontLoader(fontFamily)..addFont(rootBundle.load(MediaCatalog.fontAsset))).load(); }
    catch (e) { engine.warn('字体加载失败：$e'); }
    if (!mounted) return;
    setState(() => ready = true);
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
    'interlude_common_frame': 'assets/images/prts_ui/interlude_common_frame.png',
    'interlude_gradient_v': 'assets/images/prts_ui/interlude_gradient_v.png',
    'showitem_photo_frame': 'assets/images/prts_ui/showitem_photo_frame.png',
    'showitem_cutin_header': 'assets/images/prts_ui/showitem_cutin_header.png',
  };

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) unawaited(engine.setPaused(true));
  }

  Future<void> _showLog({bool diagnostics = false}) async {
    final wasPaused = engine.paused;
    await engine.setPaused(true);
    if (!mounted) return;
    await showModalBottomSheet<void>(context: context, isScrollControlled: true, builder: (context) => SafeArea(child: SizedBox(height: MediaQuery.sizeOf(context).height * .8, child: Column(children: [
      ListTile(title: Text(diagnostics ? '资源与指令诊断' : '对话记录'), trailing: IconButton(tooltip: '关闭', onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close))),
      Expanded(child: ListView(padding: const EdgeInsets.all(16), children: diagnostics
        ? [for (final message in engine.warnings) Padding(padding: const EdgeInsets.only(bottom: 12), child: SelectableText(message))]
        : [for (final line in engine.state.history) ListTile(title: Text(StoryEngine.plainText(line.text)), subtitle: line.speaker.isEmpty ? null : Text(line.speaker))])),
    ]))));
    if (mounted && !wasPaused) await engine.setPaused(false);
  }

  String get _speedLabel => switch (engine.autoMode) {
    'quick_play' => '快速 ${engine.speedLevel + 1} 档',
    'button_auto' => '自动 ${engine.speedLevel + 1} 档',
    _ => '手动',
  };

  void _cycleSpeed() {
    final maxLevel = engine.autoMode == 'quick_play' ? 3 : 2;
    if (engine.autoMode == 'default') {
      engine.setAutoMode('button_auto');
      engine.setSpeedLevel(0);
      return;
    }
    engine.setSpeedLevel(engine.speedLevel >= maxLevel ? 0 : engine.speedLevel + 1);
  }

  @override
  Widget build(BuildContext context) => Scaffold(backgroundColor: Colors.black, body: SafeArea(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    AnimatedBuilder(animation: engine, builder: (context, _) => AnimatedOpacity(
      opacity: engine.theaterMode ? 0 : 1,
      duration: const Duration(milliseconds: 200),
      child: IgnorePointer(ignoring: engine.theaterMode, child: Row(children: [
        IconButton(tooltip: '退出播放器', onPressed: () => Navigator.pop(context), icon: const Icon(Icons.arrow_back)),
        Expanded(child: Text(engine.state.metadata.title.isNotEmpty ? engine.state.metadata.title : widget.story.document.title, maxLines: 1, overflow: TextOverflow.ellipsis)),
        IconButton(tooltip: '跳过节点', onPressed: engine.canSkipNode ? () => engine.skipNode() : null, icon: const Icon(Icons.fast_forward)),
        TextButton(onPressed: engine.state.metadata.isAutoable ? _cycleSpeed : null, onLongPress: !engine.state.metadata.isAutoable ? null : () { engine.setAutoMode(engine.autoMode == 'quick_play' ? 'default' : 'quick_play'); engine.setSpeedLevel(0); }, child: Text(_speedLabel, style: const TextStyle(color: Colors.white))),
        IconButton(tooltip: engine.autoMode != 'default' ? '关闭自动播放' : '自动播放', onPressed: !engine.state.metadata.isAutoable ? null : () => engine.setAutoMode(engine.autoMode == 'default' ? 'button_auto' : 'default'), icon: Icon(engine.autoMode != 'default' ? Icons.repeat_on : Icons.repeat)),
        IconButton(tooltip: engine.paused ? '继续播放' : '暂停', onPressed: () => engine.setPaused(!engine.paused), icon: Icon(engine.paused ? Icons.play_arrow : Icons.pause)),
        IconButton(tooltip: '对话记录', onPressed: () => _showLog(), icon: const Icon(Icons.history)),
        IconButton(tooltip: '诊断', onPressed: () => _showLog(diagnostics: true), icon: Badge(isLabelVisible: engine.warnings.isNotEmpty, child: const Icon(Icons.info_outline))),
      ])),
    )),
    Expanded(child: ready ? Stack(alignment: Alignment.center, children: [
      Positioned.fill(child: StoryStage(engine: engine, catalog: widget.story.catalog, textures: textures, slideMask: slideMask, slideMaskShader: slideMaskShader, sprites: sprites, fontFamily: fontFamily)),
      AnimatedBuilder(animation: engine, builder: (context, _) => engine.cursor == 0 || engine.finished ? FilledButton.icon(onPressed: engine.finished ? engine.restart : engine.start, icon: Icon(engine.finished ? Icons.replay : Icons.play_arrow), label: Text(engine.finished ? '重新播放' : '开始播放')) : const SizedBox.shrink()),
    ]) : const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [CircularProgressIndicator(), SizedBox(height: 16), Text('正在解码演出资源…')]))),
  ])));

  @override
  void dispose() {
    slideMaskShader?.dispose();
    slideMask?.dispose();
    for (final texture in sprites.values) {
      texture.dispose();
    }
    WidgetsBinding.instance.removeObserver(this);
    engine.dispose();
    for (final texture in textures.values) { texture.dispose(); }
    unawaited(SystemChrome.setPreferredOrientations(DeviceOrientation.values));
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    super.dispose();
  }
}
