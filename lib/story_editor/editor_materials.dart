import 'package:material_ui/material_ui.dart';

import 'dart:ui' as ui;

import '../story_player/data/media_catalog.dart';
import 'editor_platform.dart';
import 'editor_preview.dart';
import 'editor_project.dart';

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

class _EditorMaterialPickerState extends State<EditorMaterialPicker> {
  String query = '';
  MediaCatalog? catalog;
  List<String> effects = const [];
  bool loading = true;
  Object? error;

  bool get image => {
    FieldType.background,
    FieldType.cg,
    FieldType.character,
  }.contains(widget.field.type);

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
      }
    } catch (e) {
      error = e;
    }
    if (mounted) setState(() => loading = false);
  }

  List<(String, String)> get matches {
    final items = <(String, String)>[];
    if (widget.field.type == FieldType.fx) {
      items.addAll(effects.map((value) => (value, value)));
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
            .showSnackBar(SnackBar(content: Text('素材无法使用：$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) => Dialog(
    child: SizedBox(
      width: 560,
      height: 600,
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
                  tooltip: '清除素材',
                  onPressed: () => Navigator.pop(context, ('', null)),
                  icon: const Icon(Icons.clear),
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
              onChanged: (v) => setState(() => query = v),
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
                  if (widget.current.isNotEmpty)
                    ListTile(
                      selected: widget.current == '',
                      leading: const Icon(Icons.block),
                      title: const Text('无素材 / 清除'),
                      onTap: () => Navigator.pop(context, ('', null)),
                    ),
                  for (final (key, label) in matches.take(500))
                    ListTile(
                      dense: true,
                      selected: key == widget.current,
                      leading: Icon(
                        key.startsWith('local_')
                            ? Icons.phone_android
                            : widget.field.type == FieldType.fx
                            ? Icons.auto_awesome
                            : image
                            ? Icons.image
                            : Icons.music_note,
                      ),
                      title: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: key.startsWith('local_')
                          ? Text(
                              key,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            )
                          : null,
                      onTap: () => Navigator.pop(context, (key, null)),
                    ),
                  if (matches.isEmpty && error == null)
                    const ListTile(title: Text('没有匹配素材')),
                ],
              ),
            ),
        ],
      ),
    ),
  );
}
