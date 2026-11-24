import 'dart:typed_data';
import 'dart:math' as math;

import 'package:just_audio/just_audio.dart';
import 'package:material_ui/material_ui.dart';

import 'dart:ui' as ui;

import '../story_player/data/media_catalog.dart';
import 'editor_platform.dart';
import 'editor_preview.dart';
import 'editor_project.dart';
import '../story_player/fx/fx_loader.dart';
import '../story_player/fx/fx_painter.dart';
import '../story_player/fx/fx_simulation.dart';

class EditorMaterialPicker extends StatefulWidget {
  const EditorMaterialPicker({
    super.key,
    required this.field,
    required this.current,
    required this.resources,
    required this.assets,
    required this.storage,
  });
  final EditorField field;
  final String current;
  final EditorPreviewResources resources;
  final Map<String, EditorAsset> assets;
  final EditorStorage storage;

  @override
  State<EditorMaterialPicker> createState() => _EditorMaterialPickerState();
}

class _FxThumbnail extends StatefulWidget {
  const _FxThumbnail({super.key, required this.name, required this.resources});
  final String name;
  final EditorPreviewResources resources;

  @override
  State<_FxThumbnail> createState() => _FxThumbnailState();
}

class _FxThumbnailState extends State<_FxThumbnail> {
  ui.Image? _preview;
  bool _failed = false;
  static const _size = 256;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    ui.Image? image;
    try {
      final loader = FxLoader(
        storyFxRoot,
        widget.resources.store,
        transient: true,
      );
      final asset = await loader.load(widget.name);
      final textures = <Uri, ui.Image>{};
      try {
        for (final file in asset.textures) {
          final uri = asset.textureUri(file);
          final codec = await ui.instantiateImageCodec(await loader.bytes(uri));
          try {
            textures[uri] = (await codec.getNextFrame()).image;
          } finally {
            codec.dispose();
          }
        }
        final simulation = FxSimulation(asset, loop: true);
        for (var step = 0; step < 30; step++) {
          simulation.advance(1 / 60);
        }
        const stage = Rect.fromLTWH(0, 0, 1280, 720);
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        final scale = math.min(_size / stage.width, _size / stage.height);
        canvas.translate(_size / 2, _size / 2);
        canvas.scale(scale);
        canvas.translate(-stage.center.dx, -stage.center.dy);
        canvas.clipRect(stage);
        final effect = StageEffect(simulation, group: 'effect', layer: 0);
        paintEffects(
          canvas,
          [effect],
          textures,
          'effect',
          afterBlocker: asset.drawAfterBlocker,
        );

        final background = StageEffect(simulation, group: 'bgeffect', layer: 0);
        paintEffects(canvas, [background], textures, 'bgeffect');
        paintScreenOverlays(canvas, stage, [effect]);
        final picture = recorder.endRecording();
        try {
          image = await picture.toImage(_size, _size);
        } finally {
          picture.dispose();
        }
      } finally {
        for (final texture in textures.values) {
          texture.dispose();
        }
      }
    } catch (_) {
      _failed = true;
    }

    if (!mounted) {
      image?.dispose();
      return;
    }
    setState(() => _preview = image);
  }

  @override
  void dispose() {
    _preview?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(8),
    ),
    child: _preview != null
        ? RawImage(image: _preview, fit: BoxFit.contain)
        : Icon(_failed ? Icons.broken_image_outlined : Icons.hourglass_empty),
  );
}

class _EditorMaterialPickerState extends State<EditorMaterialPicker> {
  String query = '';
  int page = 0;
  static const _pageSize = 24;
  MediaCatalog? catalog;
  List<String> effects = const [];
  List<String> cgImages = const [];
  bool loading = true;
  Object? error;
  final _player = AudioPlayer();
  String? playing;

  bool get image => {
    FieldType.background,
    FieldType.cg,
    FieldType.character,
  }.contains(widget.field.type);

  bool get _usesThumbnailGrid => image || widget.field.type == FieldType.fx;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      if (widget.field.type == FieldType.fx) {
        effects = await widget.resources.effects();
      } else {
        catalog = await widget.resources.prts();
        if (widget.field.type == FieldType.cg) {
          cgImages = await widget.resources.cgImages();
        }
      }
    } catch (_) {
      error = '素材目录读取失败，请检查资源目录或稍后重试';
    }
    if (mounted) setState(() => loading = false);
  }

  List<(String, String)> get matches {
    final items = <(String, String)>[];
    if (widget.field.type == FieldType.fx) {
      items.addAll(effects.map((value) => (value, value)));
    } else if (widget.field.type == FieldType.cg) {
      items.addAll(cgImages.map((key) => (key, key)));
    } else if (catalog != null) {
      final c = catalog!;
      if (image && widget.field.type == FieldType.character) {
        for (final entry in c.characters.entries) {
          final key = entry.key;
          items.add((key, key));
          final variants = (entry.value as Map)['array'] as List? ?? const [];
          for (final (i, raw) in variants.indexed) {
            if (raw is! Map) continue;
            final alias = raw['alias'];
            final index = (raw['index'] as int? ?? i) + 1;
            final body = (raw['body'] as int? ?? 0) + 1;
            final name = alias is String && alias.isNotEmpty
                ? '$key@$alias'
                : '$key#$index${body > 1 ? '\$$body' : ''}';
            items.add((name, name));
          }
        }
      } else if (widget.field.type == FieldType.background) {
        items.addAll(c.backgroundPpu.keys.map((key) => (key, key)));
      } else if (!image) {
        for (final value in c.variables.entries) {
          final key = '\$${value.key}';
          final uri = c.audio(key);
          if (uri == null) continue;
          final music = uri.path.toLowerCase().contains('/music/');
          if (music == (widget.field.type == FieldType.music)) {
            items.add((key, '${value.key} · ${value.value}'));
          }
        }
      }
    }
    final local = widget.field.type == FieldType.fx
        ? const <(String, String)>[]
        : widget.assets.values
              .where((a) => a.isImage == image)
              .map((a) => (a.key, '本地 · ${a.name}'));
    final needle = query.trim().toLowerCase();
    final combined = [...local, ...items].where(
      (entry) =>
          needle.isEmpty ||
          '${entry.$1} ${entry.$2}'.toLowerCase().contains(needle),
    );
    return combined.toSet().toList()..sort((a, b) => a.$2.compareTo(b.$2));
  }

  Future<void> _upload() async {
    try {
      final file = await widget.storage.pickMedia(image: image);
      if (file == null || !mounted) return;
      final (name, bytes) = file;
      var width = 0, height = 0;
      if (image) {
        final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
        try {
          final descriptor = await ui.ImageDescriptor.encoded(buffer);
          width = descriptor.width;
          height = descriptor.height;
          descriptor.dispose();
        } finally {
          buffer.dispose();
        }
      }
      if (!mounted) return;
      final asset = EditorAsset.create(
        name,
        bytes,
        width: width,
        height: height,
      );
      if (mounted) Navigator.pop(context, (asset.key, asset));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('素材无法使用，请确认文件格式和大小')));
      }
    }
  }

  Uri? _audioUri(String key) => widget.assets[key]?.uri ?? catalog?.audio(key);

  Future<void> _play(String key) async {
    if (playing == key) {
      await _player.stop();
      if (mounted) setState(() => playing = null);
      return;
    }
    final uri = _audioUri(key);
    if (uri == null) return;
    try {
      await _player.setAudioSource(AudioSource.uri(uri));
      if (mounted) setState(() => playing = key);
      await _player.play();
      if (mounted && playing == key) setState(() => playing = null);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('音频暂时无法试听')));
      }
    }
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Widget _materialTile(String key, String label) {
    final local = widget.assets[key];
    if (_usesThumbnailGrid) {
      final selected = key == widget.current;
      return SizedBox(
        width: 156,
        height: 194,
        child: Card(
          color: selected
              ? Theme.of(context).colorScheme.secondaryContainer
              : null,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => Navigator.pop(context, (key, local)),
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                children: [
                  Expanded(child: _thumbnail(key, local)),
                  const SizedBox(height: 6),
                  Text(
                    label,
                    maxLines: 2,
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (key.startsWith('local_'))
                    Text(key, maxLines: 1, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
          ),
        ),
      );
    }
    return ListTile(
      dense: true,
      selected: key == widget.current,
      leading: _thumbnail(key, local),
      title: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: IconButton(
        tooltip: playing == key ? '停止试听' : '试听',
        onPressed: () => _play(key),
        icon: Icon(playing == key ? Icons.stop : Icons.play_arrow),
      ),
      onTap: () => Navigator.pop(context, (key, local)),
    );
  }

  Widget _thumbnail(String key, EditorAsset? local) {
    if (!image) {
      if (widget.field.type == FieldType.fx) {
        return _FxThumbnail(
          key: ValueKey(key),
          name: key,
          resources: widget.resources,
        );
      }
      return const Icon(Icons.music_note);
    }
    if (local != null) {
      return Image.memory(
        local.bytes,
        width: double.infinity,
        height: double.infinity,
        fit: BoxFit.contain,
      );
    }
    final uri = widget.field.type == FieldType.character
        ? catalog?.character(key)?.body
        : catalog?.image(key, cg: widget.field.type == FieldType.cg);
    if (uri == null) return const Icon(Icons.image_outlined);
    return FutureBuilder<Uint8List>(
      key: ValueKey(uri),
      future: widget.resources.loadBytes(uri),
      builder: (_, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (!snapshot.hasData) return const Icon(Icons.broken_image_outlined);
        return Image.memory(
          snapshot.data!,
          width: double.infinity,
          height: double.infinity,
          fit: BoxFit.contain,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final results = matches;
    final pageCount = (results.length / _pageSize).ceil();
    final visible = results.skip(page * _pageSize).take(_pageSize);
    return Dialog(
      child: SizedBox(
        width: math.min(560, MediaQuery.sizeOf(context).width - 32),
        height: math.min(600, MediaQuery.sizeOf(context).height - 48),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.field.label,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  if (widget.field.type != FieldType.fx)
                    IconButton(
                      tooltip: '上传本地素材',
                      onPressed: _upload,
                      icon: const Icon(Icons.upload_file),
                    ),

                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: '搜索素材名称或命令键',
                ),
                onChanged: (v) => setState(() {
                  query = v;
                  page = 0;
                }),
              ),
            ),
            if (loading)
              const Expanded(child: Center(child: CircularProgressIndicator()))
            else
              Expanded(
                child: ListView(
                  children: [
                    if (error != null)
                      ListTile(
                        leading: const Icon(Icons.info_outline),
                        title: const Text('PRTS 素材目录暂不可用'),
                        subtitle: Text(
                          '$error',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    if (true)
                      ListTile(
                        selected:
                            widget.current == '' ||
                            (widget.field.type == FieldType.character &&
                                widget.current == 'char_empty'),
                        leading: const Icon(Icons.block),
                        title: const Text('无素材 / 清除'),
                        onTap: () => Navigator.pop(context, (
                          widget.field.type == FieldType.character
                              ? 'char_empty'
                              : '',
                          null,
                        )),
                      ),

                    if (_usesThumbnailGrid)
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final entry in visible)
                            _materialTile(entry.$1, entry.$2),
                        ],
                      )
                    else
                      for (final entry in visible)
                        _materialTile(entry.$1, entry.$2),
                    if (results.isEmpty && error == null)
                      const ListTile(title: Text('没有匹配素材')),
                  ],
                ),
              ),
            if (!loading && pageCount > 1)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    tooltip: '上一页',
                    onPressed: page > 0 ? () => setState(() => page--) : null,
                    icon: const Icon(Icons.chevron_left),
                  ),
                  Tooltip(
                    message: '选择页数',
                    child: DropdownButton<int>(
                      value: page,
                      isDense: true,
                      items: List.generate(
                        pageCount,
                        (index) => DropdownMenuItem(
                          value: index,
                          child: Text('${index + 1}'),
                        ),
                      ),
                      onChanged: (value) {
                        if (value != null) setState(() => page = value);
                      },
                    ),
                  ),
                  Text(' / $pageCount'),
                  IconButton(
                    tooltip: '下一页',
                    onPressed: page + 1 < pageCount
                        ? () => setState(() => page++)
                        : null,
                    icon: const Icon(Icons.chevron_right),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
