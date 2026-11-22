import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../story_player/ui/story_stage.dart';
import 'editor_preview.dart';
import 'editor_project.dart';

typedef _Handle = ({
  int index,
  Offset anchor,
  Offset position,
  bool yUp,
  void Function(Offset) update,
});

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

  @override
  State<EditorStage> createState() => _EditorStageState();
}

class _EditorStageState extends State<EditorStage> {
  PreparedStage? _stage;
  Timer? _refresh;
  int _generation = 0;
  String? _error;
  bool _loading = true;
  _Handle? _drag;
  Offset _point = Offset.zero;

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  @override
  void didUpdateWidget(EditorStage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.project != widget.project ||
        oldWidget.scene != widget.scene ||
        oldWidget.beat != widget.beat ||
        oldWidget.resources != widget.resources) {
      _schedule();
    }
  }

  void _schedule() {
    _refresh?.cancel();
    final generation = ++_generation;
    _loading = true;
    _drag = null;
    _refresh = Timer(
      const Duration(milliseconds: 100),
      () => _rebuild(generation),
    );
  }

  Future<void> _rebuild(int generation) async {
    PreparedStage? prepared;
    bool active() => mounted && generation == _generation;
    try {
      final compiled = widget.project.compile();
      final end = compiled.ranges[(widget.scene, widget.beat)]!.$2;
      prepared = await widget.resources.prepare(
        widget.project,
        compiled,
        end: end,
        audible: false,
        active: active,
      );
      if (!active()) return;
      final reached = await prepared.engine.rebuildBefore(end);
      if (!active()) return;
      _stage?.dispose();
      setState(() {
        _stage = prepared;
        _error = reached ? null : '无法重建此分镜的舞台';
        _loading = false;
      });
      prepared = null;
    } catch (e) {
      if (active()) {
        setState(() {
          _error = '舞台加载失败：$e';
          _loading = false;
        });
      }
    } finally {
      prepared?.dispose();
    }
  }

  @override
  void dispose() {
    _refresh?.cancel();
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
    final commands =
        widget.project.scenes[widget.scene].beats[widget.beat].commands;
    final handles = <_Handle>[];
    final seen = <String>{};
    var clearedSlots = false;
    for (var i = commands.length - 1; i >= 0; i--) {
      final command = commands[i];
      if (command.raw != null) continue;
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
            index: i,
            anchor: origin + Offset(layer.x, -layer.y),
            position: Offset(layer.x, layer.y),
            yUp: true,
            update: (p) {
              layer.x = p.dx;
              layer.y = p.dy;
            },
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
          handles.add((
            index: i,
            anchor: Offset(x + node.actionX, y - node.actionY),
            position: Offset(node.actionX, node.actionY),
            yUp: true,
            update: (p) {
              node.actionX = p.dx;
              node.actionY = p.dy;
            },
          ));
        case 'subtitle':
          if (!seen.add(command.tag)) continue;
          final subtitle = state.subtitle;
          if (subtitle == null || command.value('text').isEmpty) continue;
          handles.add((
            index: i,
            anchor: Offset(subtitle.x, subtitle.y),
            position: Offset(subtitle.x, subtitle.y),
            yUp: false,
            update: (p) {
              subtitle.x = p.dx;
              subtitle.y = p.dy;
            },
          ));
      }
    }
    return handles.reversed.toList();
  }

  String _format(double value) => value.toStringAsFixed(1);

  Widget _handle(_Handle handle, Size size, double scale) {
    final index = handle.index;
    final command =
        widget.project.scenes[widget.scene].beats[widget.beat].commands[index];
    final tag = command.tag;
    final label = editorFields[tag]!.$1;
    final selected = widget.selected == index || _drag?.index == index;
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
        label: '拖动$label',
        child: MouseRegion(
          cursor: SystemMouseCursors.move,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (_) {
              _drag = handle;
              _point = handle.position;
            },
            onPanUpdate: (d) {
              final drag = _drag;
              if (drag == null) return;
              _point +=
                  Offset(d.delta.dx, drag.yUp ? -d.delta.dy : d.delta.dy) /
                  scale;
              final min = drag.yUp ? -1.0 : 0.0;
              _point = Offset(
                _point.dx.clamp(
                  min * 1280,
                  tag == 'subtitle' ? 1279.0 : 1280.0,
                ),
                _point.dy.clamp(min * 720, 720.0),
              );
              setState(() => drag.update(_point));
            },
            onPanCancel: () {
              final drag = _drag;
              if (drag != null) {
                setState(() {
                  drag.update(drag.position);
                  _drag = null;
                });
              }
            },
            onPanEnd: (_) {
              final drag = _drag;
              if (drag == null) return;
              _drag = null;
              final x = _format(_point.dx), y = _format(_point.dy);
              widget.onMove(
                index,
                tag == 'charslot' ? {'posto': '$x,$y'} : {'x': x, 'y': y},
              );
            },
            child: SizedBox.square(
              dimension: 44,
              child: Center(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: selected
                        ? Theme.of(context).colorScheme.primary
                        : Colors.black54,
                    shape: BoxShape.circle,
                  ),
                  child: const Padding(
                    padding: EdgeInsets.all(3),
                    child: Icon(Icons.open_with, color: Colors.white, size: 16),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final scale = math.min(box.maxWidth / 1280, box.maxHeight / 720);
      if (scale <= 0 || !scale.isFinite) return const SizedBox.shrink();
      final size = Size(1280 * scale, 720 * scale);
      final stage = _stage;
      final warnings = [?_error, ...?stage?.engine.warnings];
      return SizedBox.fromSize(
        size: size,
        child: ClipRect(
          child: ColoredBox(
            color: const Color(0xff181c1f),
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
                if (stage != null && !_loading)
                  for (final handle in _handles(stage))
                    _handle(handle, size, scale),
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
      );
    },
  );
}
