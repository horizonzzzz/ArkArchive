import '../app/archive_widgets.dart';

import 'package:material_ui/material_ui.dart';

import 'editor_project.dart';

/// 全局搜索命中结果（P1-4）。
class EditorSearchHit {
  const EditorSearchHit({
    required this.sceneIndex,
    required this.beatIndex,
    this.commandIndex = -1,
    required this.title,
    required this.subtitle,
    required this.kind,
  });

  final int sceneIndex;
  final int beatIndex;
  final int commandIndex;
  final String title;
  final String subtitle;
  final String kind;
}

/// 检索作品中的幕标题、分镜标题、台词、说话人、素材键名与标记备注（P1-4）。
List<EditorSearchHit> searchProjectContent(EditorProject project, String raw) {
  final q = raw.trim().toLowerCase();
  if (q.isEmpty) return const [];
  final hits = <EditorSearchHit>[];
  for (var si = 0; si < project.scenes.length; si++) {
    final scene = project.scenes[si];
    if (scene.title.toLowerCase().contains(q) ||
        scene.marker.note.toLowerCase().contains(q)) {
      hits.add(
        EditorSearchHit(
          sceneIndex: si,
          beatIndex: 0,
          title: scene.title,
          subtitle: scene.marker.note.isNotEmpty
              ? '幕标记：${scene.marker.note}'
              : '第 ${si + 1} 幕 · ${scene.beats.length} 镜',
          kind: '幕',
        ),
      );
    }
    for (var bi = 0; bi < scene.beats.length; bi++) {
      final beat = scene.beats[bi];
      if (beat.title.toLowerCase().contains(q) ||
          beat.marker.note.toLowerCase().contains(q)) {
        hits.add(
          EditorSearchHit(
            sceneIndex: si,
            beatIndex: bi,
            title: '${scene.title} / ${beat.title}',
            subtitle: beat.marker.note.isNotEmpty
                ? '分镜标记：${beat.marker.note}'
                : '${beat.commands.length} 条指令',
            kind: '分镜',
          ),
        );
      }
      for (var ci = 0; ci < beat.commands.length; ci++) {
        final cmd = beat.commands[ci];
        final matched =
            (cmd.raw != null && cmd.raw!.toLowerCase().contains(q)) ||
            cmd.tag.toLowerCase().contains(q) ||
            cmd.args.values.any((v) => v.toLowerCase().contains(q));
        if (matched) {
          final label = editorFields[cmd.tag]?.$1 ?? cmd.tag;
          final preview =
              cmd.raw ??
              (cmd.value('text').isNotEmpty
                  ? cmd.value('text')
                  : cmd.value('name').isNotEmpty
                  ? cmd.value('name')
                  : cmd.value('image').isNotEmpty
                  ? cmd.value('image')
                  : cmd.value('key'));
          hits.add(
            EditorSearchHit(
              sceneIndex: si,
              beatIndex: bi,
              commandIndex: ci,
              title: '$label · ${preview.replaceAll('\n', ' ')}',
              subtitle: '${scene.title} / ${beat.title} · 指令 #${ci + 1}',
              kind: '指令',
            ),
          );
          if (hits.length >= 80) return hits;
        }
      }
    }
  }
  return hits;
}

/// 左栏常驻三级折叠结构树（P1-4：作品 → 幕 → 分镜，含指令数/警告数/标记色/估算时长/拖拽重排/操作菜单）。
class EditorStructureTree extends StatefulWidget {
  const EditorStructureTree({
    super.key,
    required this.project,
    required this.activeScene,
    required this.activeBeat,
    required this.issues,
    required this.onSelectBeat,
    required this.onSceneAction,
    required this.onBeatAction,
    required this.onMarkScene,
    required this.onMarkBeat,
    required this.onMoveBeat,
    required this.onOpenSearch,
  });

  final EditorProject project;
  final int activeScene;
  final int activeBeat;
  final List<EditorIssue> issues;
  final void Function(int scene, int beat) onSelectBeat;
  final void Function(int scene, String action) onSceneAction;
  final void Function(int scene, int beat, String action) onBeatAction;
  final void Function(int scene) onMarkScene;
  final void Function(int scene, int beat) onMarkBeat;
  final void Function(({int scene, int beat}) from, int toScene, int toBeat)
  onMoveBeat;
  final VoidCallback onOpenSearch;

  @override
  State<EditorStructureTree> createState() => _EditorStructureTreeState();
}

class _EditorStructureTreeState extends State<EditorStructureTree> {
  final Map<int, bool> _expansion = {};
  bool _onlyMarked = false;
  List<EditorIssue>? _indexedIssues;
  final _sceneWarnings = <int, int>{};
  final _beatWarnings = <(int, int), int>{};

  bool _expanded(int scene) => _expansion[scene] ?? scene == widget.activeScene;

  @override
  void didUpdateWidget(EditorStructureTree oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.project.id != widget.project.id ||
        oldWidget.activeScene != widget.activeScene) {
      _expansion.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!identical(_indexedIssues, widget.issues)) {
      _indexedIssues = widget.issues;
      _sceneWarnings.clear();
      _beatWarnings.clear();
      for (final issue in widget.issues) {
        _sceneWarnings.update(
          issue.sceneIndex,
          (n) => n + 1,
          ifAbsent: () => 1,
        );
        _beatWarnings.update(
          (issue.sceneIndex, issue.beatIndex),
          (n) => n + 1,
          ifAbsent: () => 1,
        );
      }
    }
    final rows = <(int, int)>[
      for (final (si, scene) in widget.project.scenes.indexed) ...[
        (si, -1),
        if (_expanded(si))
          for (final (bi, beat) in scene.beats.indexed)
            if (!_onlyMarked || beat.marker.isNotEmpty) (si, bi),
      ],
    ];
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 6, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '结构树 · ${widget.project.beatCount} 镜',
                  style: Theme.of(context).textTheme.labelLarge,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                tooltip: '全局搜索（Ctrl+K）',
                visualDensity: VisualDensity.compact,
                iconSize: 18,
                onPressed: widget.onOpenSearch,
                icon: const Icon(Icons.search),
              ),
              IconButton(
                tooltip: _onlyMarked ? '显示全部分镜' : '仅看已标记',
                visualDensity: VisualDensity.compact,
                iconSize: 18,
                isSelected: _onlyMarked,
                onPressed: () => setState(() => _onlyMarked = !_onlyMarked),
                icon: Icon(
                  _onlyMarked ? Icons.bookmark : Icons.bookmark_border,
                ),
              ),
              IconButton(
                tooltip: '新建幕',
                visualDensity: VisualDensity.compact,
                iconSize: 18,
                onPressed: () =>
                    widget.onSceneAction(widget.activeScene, 'add'),
                icon: const Icon(Icons.create_new_folder_outlined),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 4),
            itemCount: rows.length,
            itemBuilder: (context, index) {
              final (si, bi) = rows[index];
              return KeyedSubtree(
                key: ValueKey((si, bi)),
                child: bi < 0
                    ? _buildSceneNode(context, si, scheme)
                    : _buildBeatNode(context, si, bi, scheme),
              );
            },
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: scheme.outlineVariant)),
          ),
          child: Text(
            '约 ${formatEstimatedDuration(widget.project.estimatedSeconds)} · ${widget.issues.length} 警告',
            style: Theme.of(context).textTheme.labelSmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }

  Widget _buildSceneNode(BuildContext context, int si, ColorScheme scheme) {
    final scene = widget.project.scenes[si];
    final collapsed = !_expanded(si);
    final sceneWarnings = _sceneWarnings[si] ?? 0;
    final markerColor = Color(
      editorMarkerColors[scene.marker.color] ?? 0xFFA5C7D5,
    );

    return DragTarget<({int scene, int beat})>(
      onAcceptWithDetails: (d) =>
          widget.onMoveBeat(d.data, si, scene.beats.length),
      builder: (context, candidate, _) => Container(
        color: candidate.isNotEmpty
            ? scheme.primaryContainer.withValues(alpha: 0.25)
            : null,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(
          children: [
            IconButton(
              visualDensity: VisualDensity.compact,
              iconSize: 16,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
              onPressed: () => setState(() {
                _expansion[si] = collapsed;
              }),
              icon: Icon(collapsed ? Icons.chevron_right : Icons.expand_more),
            ),
            Container(
              width: 8,
              height: 8,
              margin: const EdgeInsets.only(right: 5),
              decoration: BoxDecoration(
                color: markerColor,
                shape: BoxShape.circle,
              ),
            ),
            Expanded(
              child: InkWell(
                onTap: () => widget.onSelectBeat(si, 0),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        scene.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(
                              fontWeight: si == widget.activeScene
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                            ),
                      ),
                      Text(
                        '${scene.beats.length} 镜 · ${formatEstimatedDuration(scene.estimatedSeconds)}'
                        '${sceneWarnings > 0 ? ' · !$sceneWarnings' : ''}',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          fontSize: 10,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            PopupMenuButton<String>(
              tooltip: '幕操作 ${si + 1}',
              iconSize: 16,
              padding: EdgeInsets.zero,
              onSelected: (action) {
                if (action == 'mark') {
                  widget.onMarkScene(si);
                } else {
                  widget.onSceneAction(si, action);
                }
              },
              itemBuilder: (_) => [
                const ArchivePopupMenuItem(
                  value: 'add_beat',
                  child: Text('新建分镜'),
                ),
                const ArchivePopupMenuItem(
                  value: 'rename',
                  child: Text('重命名幕'),
                ),
                const ArchivePopupMenuItem(value: 'mark', child: Text('标记与备注')),
                ArchivePopupMenuItem(
                  value: 'up',
                  enabled: si > 0,
                  child: const Text('上移幕'),
                ),
                ArchivePopupMenuItem(
                  value: 'down',
                  enabled: si + 1 < widget.project.scenes.length,
                  child: const Text('下移幕'),
                ),
                ArchivePopupMenuItem(
                  value: 'delete',
                  enabled: widget.project.scenes.length > 1,
                  child: const Text('删除幕'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBeatNode(
    BuildContext context,
    int si,
    int bi,
    ColorScheme scheme,
  ) {
    final beat = widget.project.scenes[si].beats[bi];
    final selected = si == widget.activeScene && bi == widget.activeBeat;
    final warnings = _beatWarnings[(si, bi)] ?? 0;
    final markerColor = Color(
      editorMarkerColors[beat.marker.color] ?? 0xFFA5C7D5,
    );
    final ref = (scene: si, beat: bi);

    final row = Container(
      key: ValueKey(('tree-beat', si, bi)),
      color: selected ? scheme.primaryContainer.withValues(alpha: 0.35) : null,
      padding: const EdgeInsets.only(left: 24, right: 4, top: 2, bottom: 2),
      child: Row(
        children: [
          Container(
            width: 7,
            height: 7,
            margin: const EdgeInsets.only(right: 5),
            decoration: BoxDecoration(
              color: markerColor,
              shape: BoxShape.circle,
            ),
          ),
          Expanded(
            child: InkWell(
              onTap: () => widget.onSelectBeat(si, bi),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      beat.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontWeight: selected ? FontWeight.w600 : null,
                      ),
                    ),
                    Text(
                      '${beat.commands.length} 条 · ${formatEstimatedDuration(beat.estimatedSeconds)}'
                      '${warnings > 0 ? ' · !$warnings' : ''}',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        fontSize: 10,
                        color: warnings > 0
                            ? const Color(0xFFF28D8D)
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          PopupMenuButton<String>(
            tooltip: '分镜操作 ${si + 1}-${bi + 1}',
            iconSize: 15,
            padding: EdgeInsets.zero,
            onSelected: (action) {
              if (action == 'mark') {
                widget.onMarkBeat(si, bi);
              } else {
                widget.onBeatAction(si, bi, action);
              }
            },
            itemBuilder: (_) => [
              const ArchivePopupMenuItem(value: 'rename', child: Text('重命名分镜')),
              const ArchivePopupMenuItem(
                value: 'duplicate',
                child: Text('复制分镜'),
              ),
              const ArchivePopupMenuItem(value: 'mark', child: Text('标记与备注')),
              ArchivePopupMenuItem(
                value: 'delete',
                enabled: widget.project.scenes[si].beats.length > 1,
                child: const Text('删除分镜'),
              ),
            ],
          ),
        ],
      ),
    );

    return DragTarget<({int scene, int beat})>(
      onWillAcceptWithDetails: (d) => d.data != ref,
      onAcceptWithDetails: (d) => widget.onMoveBeat(d.data, si, bi),
      builder: (context, candidate, _) => Draggable<({int scene, int beat})>(
        data: ref,
        feedback: Material(
          elevation: 4,
          borderRadius: BorderRadius.circular(6),
          child: SizedBox(width: 190, child: row),
        ),
        childWhenDragging: Opacity(opacity: 0.4, child: row),
        child: Container(
          decoration: candidate.isNotEmpty
              ? BoxDecoration(
                  border: Border(
                    top: BorderSide(color: scheme.primary, width: 2),
                  ),
                )
              : null,
          child: row,
        ),
      ),
    );
  }
}

/// 标记颜色 + 备注弹窗（P1-4）。
Future<({bool clear, EditorMarker? marker})?> showMarkerDialog(
  BuildContext context, {
  required String targetTitle,
  EditorMarker? initial,
}) async {
  var selectedColor = initial?.color ?? 'cyan';
  final noteController = TextEditingController(text: initial?.note ?? '');
  final result = await showDialog<({bool clear, EditorMarker? marker})>(
    context: context,
    builder: (dialog) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text('标记 · $targetTitle'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final entry in editorMarkerColors.entries)
                  ChoiceChip(
                    avatar: Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: Color(entry.value),
                        shape: BoxShape.circle,
                      ),
                    ),
                    label: Text(editorMarkerLabels[entry.key] ?? entry.key),
                    selected: selectedColor == entry.key,
                    onSelected: (_) =>
                        setState(() => selectedColor = entry.key),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: noteController,
              maxLength: 80,
              decoration: const InputDecoration(
                labelText: '备注（可选）',
                hintText: '例如：待补配音 / 需复查台词',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ],
        ),
        actions: [
          if (initial != null)
            TextButton(
              onPressed: () =>
                  Navigator.pop(dialog, (clear: true, marker: null)),
              child: const Text('清除标记'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, (
              clear: false,
              marker: EditorMarker(
                color: selectedColor,
                note: noteController.text.trim(),
              ),
            )),
            child: const Text('保存标记'),
          ),
        ],
      ),
    ),
  );
  noteController.dispose();
  return result;
}
