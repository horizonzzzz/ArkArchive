import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../data/media_catalog.dart';
import '../data/story_repository.dart';
import '../runtime/just_audio_output.dart';
import '../runtime/story_audio.dart';
import '../runtime/story_engine.dart';
import 'story_stage.dart';

/// 可直接由关卡选择页打开；生命周期和资源不依赖应用入口。
class StoryPlayer extends StatefulWidget {
  const StoryPlayer({super.key, required this.story, this.audio});
  final PreparedStory story;
  final StoryAudio? audio;
  @override
  State<StoryPlayer> createState() => _StoryPlayerState();
}

class _StoryPlayerState extends State<StoryPlayer> with WidgetsBindingObserver {
  late final StoryEngine engine;
  final Map<Uri, ui.Image> textures = {};
  ui.FragmentShader? slideMaskShader;
  bool ready = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]));
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky));
    engine = StoryEngine(widget.story.document.script,
      variables: widget.story.catalog.variables,
      audio: widget.audio ?? JustAudioOutput(widget.story.catalog, widget.story.assets, onWarning: (message) { if (mounted) { engine.warn(message); setState(() {}); } }));
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
    final font = widget.story.assets.peek(MediaCatalog.fontUri);
    if (uris.contains(MediaCatalog.slideMaskUri)) {
      try {
        final program = await ui.FragmentProgram.fromAsset('assets/shaders/slide_mask.frag');
        slideMaskShader = program.fragmentShader();
      } catch (e) {
        engine.warn('滑动遮罩 shader 加载失败：$e');
      }
    }
    if (font != null) {
      try { await (FontLoader('StoryNotoSans')..addFont(Future.value(ByteData.sublistView(font)))).load(); }
      catch (e) { engine.warn('字体加载失败：$e'); }
    }
    if (!mounted) return;
    setState(() => ready = true);
  }

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

  @override
  Widget build(BuildContext context) => Scaffold(backgroundColor: Colors.black, body: SafeArea(child: Column(children: [
    AnimatedBuilder(animation: engine, builder: (context, _) => Row(children: [
      IconButton(tooltip: '退出播放器', onPressed: () => Navigator.pop(context), icon: const Icon(Icons.arrow_back)),
      Expanded(child: Text(widget.story.document.title, maxLines: 1, overflow: TextOverflow.ellipsis)),
      IconButton(tooltip: engine.autoPlay ? '关闭自动播放' : '自动播放', onPressed: () => engine.setAutoPlay(!engine.autoPlay), icon: Icon(engine.autoPlay ? Icons.repeat_on : Icons.repeat)),
      IconButton(tooltip: engine.paused ? '继续播放' : '暂停', onPressed: () => engine.setPaused(!engine.paused), icon: Icon(engine.paused ? Icons.play_arrow : Icons.pause)),
      IconButton(tooltip: '对话记录', onPressed: () => _showLog(), icon: const Icon(Icons.history)),
      IconButton(tooltip: '诊断', onPressed: () => _showLog(diagnostics: true), icon: Badge(isLabelVisible: engine.warnings.isNotEmpty, child: const Icon(Icons.info_outline))),
    ])),
    Expanded(child: ready ? Stack(alignment: Alignment.center, children: [
      Positioned.fill(child: StoryStage(engine: engine, catalog: widget.story.catalog, textures: textures, slideMaskShader: slideMaskShader)),
      AnimatedBuilder(animation: engine, builder: (context, _) => engine.cursor == 0 || engine.finished ? FilledButton.icon(onPressed: engine.finished ? engine.restart : engine.start, icon: Icon(engine.finished ? Icons.replay : Icons.play_arrow), label: Text(engine.finished ? '重新播放' : '开始播放')) : const SizedBox.shrink()),
    ]) : const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [CircularProgressIndicator(), SizedBox(height: 16), Text('正在解码演出资源…')]))),
  ])));

  @override
  void dispose() {
    slideMaskShader?.dispose();
    WidgetsBinding.instance.removeObserver(this);
    engine.dispose();
    for (final texture in textures.values) { texture.dispose(); }
    unawaited(SystemChrome.setPreferredOrientations(DeviceOrientation.values));
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    super.dispose();
  }
}
