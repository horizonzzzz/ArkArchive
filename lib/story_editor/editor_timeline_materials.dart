import 'package:material_ui/material_ui.dart';

import 'editor_materials.dart';
import 'editor_platform.dart';
import 'editor_preview.dart';
import 'editor_project.dart';

class TimelineMaterial {
  const TimelineMaterial(this.type, this.key, [this.asset]);
  final FieldType type;
  final String key;
  final EditorAsset? asset;
  String get label => asset?.name ?? key;
}

class TimelineMaterialBox extends StatefulWidget {
  const TimelineMaterialBox({
    super.key,
    required this.project,
    required this.resources,
    required this.storage,
  });
  final EditorProject project;
  final EditorPreviewResources resources;
  final EditorStorage storage;

  @override
  State<TimelineMaterialBox> createState() => _TimelineMaterialBoxState();
}

class _TimelineMaterialBoxState extends State<TimelineMaterialBox> {
  static const _types = {
    FieldType.background: '背景',
    FieldType.cg: 'CG',
    FieldType.character: '立绘',
    FieldType.music: 'BGM',
  };
  static final _references =
      Expando<Map<(FieldType, String), TimelineMaterial>>();
  final _picked = <(FieldType, String), TimelineMaterial>{};
  var _type = FieldType.background;

  Map<(FieldType, String), TimelineMaterial> _scan() {
    final project = widget.project;
    return {
      for (final scene in project.scenes)
        for (final beat in scene.beats)
          for (final command in beat.commands)
            for (final field
                in editorFields[command.tag]?.$2 ?? const <EditorField>[])
              if (_types.containsKey(field.type) &&
                  command.value(field.key).isNotEmpty &&
                  command.value(field.key) != 'char_empty')
                (field.type, command.value(field.key)): TimelineMaterial(
                  field.type,
                  command.value(field.key),
                  project.assets[command.value(field.key)],
                ),
    };
  }

  Future<void> _pick() async {
    final type = _type;
    final result = await showDialog<(String, EditorAsset?)>(
      context: context,
      builder: (_) => EditorMaterialPicker(
        field: EditorField('material', _types[type]!, type),
        current: '',
        resources: widget.resources,
        assets: widget.project.assets,
        storage: widget.storage,
      ),
    );
    if (!mounted || result == null || result.$1.isEmpty) return;
    setState(
      () => _picked[(type, result.$1)] = TimelineMaterial(
        type,
        result.$1,
        result.$2 ?? widget.project.assets[result.$1],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final assets =
        <(FieldType, String), TimelineMaterial>{
              for (final asset in widget.project.assets.values)
                if (asset.isImage == (_type != FieldType.music))
                  (_type, asset.key): TimelineMaterial(_type, asset.key, asset),
              ...(_references[widget.project] ??= _scan()),
              ..._picked,
            }.values
            .where(
              (item) =>
                  item.type == _type &&
                  (!item.key.startsWith('local_') || item.asset != null),
            )
            .toList();
    final theme = Theme.of(context);
    return SizedBox(
      height: 42,
      child: Row(
        children: [
          const SizedBox(width: 8),
          const Text('素材箱'),
          const SizedBox(width: 8),
          DropdownButton<FieldType>(
            value: _type,
            onChanged: (value) => setState(() => _type = value!),
            items: [
              for (final entry in _types.entries)
                DropdownMenuItem(value: entry.key, child: Text(entry.value)),
            ],
          ),
          IconButton(
            tooltip: '从目录或本地添加素材',
            onPressed: _pick,
            icon: const Icon(Icons.add),
          ),
          Expanded(
            child: assets.isEmpty
                ? Text(
                    '添加素材后拖入轨道或参数字段',
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall,
                  )
                : ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: assets.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 5),
                    itemBuilder: (context, index) {
                      final material = assets[index];
                      final chip = Tooltip(
                        message: '拖放 ${material.label}',
                        child: Chip(
                          label: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 170),
                            child: Text(
                              material.label,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          visualDensity: VisualDensity.compact,
                        ),
                      );
                      return LongPressDraggable<TimelineMaterial>(
                        key: ValueKey((
                          'timeline-material',
                          material.type,
                          material.key,
                        )),
                        delay: const Duration(milliseconds: 150),
                        data: material,
                        dragAnchorStrategy: pointerDragAnchorStrategy,
                        feedback: Material(
                          color: Colors.transparent,
                          child: chip,
                        ),
                        childWhenDragging: Opacity(opacity: .4, child: chip),
                        child: MouseRegion(
                          cursor: SystemMouseCursors.grab,
                          child: chip,
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
