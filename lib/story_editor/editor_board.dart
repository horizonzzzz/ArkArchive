import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'editor_project.dart';

/// 编排台卡片缩放档位（P1-1）。
enum BoardCardSize { small, medium, large }

/// 编排台筛选条件（P1-1）。
enum BoardFilter { all, warnings, marked }

/// 分镜卡片定位引用。
typedef BeatRef = ({int scene, int beat});

/// 分镜缩略图摘要缓存（按分镜视觉签名缓存，避免滚动与局部改动时重复解析）。
class _BeatVisualSummary {
  const _BeatVisualSummary({
    required this.backgroundKey,
    required this.characterCount,
    required this.headline,
    required this.blockerAlpha,
  });

  final String backgroundKey;
  final int characterCount;
  final String headline;
  final double blockerAlpha;
}

final Map<String, _BeatVisualSummary> _beatThumbnailCache = {};

_BeatVisualSummary _resolveBeatVisual(
  EditorProject project,
  int sceneIndex,
  int beatIndex,
) {
  final beat = project.scenes[sceneIndex].beats[beatIndex];
  final cacheKey = '${project.id}:$sceneIndex:$beatIndex:${beat.visualSignature}';
  final cached = _beatThumbnailCache[cacheKey];
  if (cached != null) return cached;

  // 继承前序分镜的背景与角色槽位，保证缩略图反映分镜末态视觉。
  String bg = '';
  final chars = <String>{};
  double blockerAlpha = 0;
  String headline = beat.leadLine;
  for (var si = 0; si <= sceneIndex; si++) {
    final s = project.scenes[si];
    final maxBeat = si == sceneIndex ? beatIndex : s.beats.length - 1;
    for (var bi = 0; bi <= maxBeat; bi++) {
      for (final cmd in s.beats[bi].commands) {
        switch (cmd.tag) {
          case 'background':
          case 'image':
            final img = cmd.value('image');
            if (img.isNotEmpty) bg = img;
          case 'charslot':
            final slot = cmd.value('slot');
            final name = cmd.value('name');
            if (slot.isEmpty && name.isEmpty) {
              chars.clear();
            } else if (slot.isNotEmpty) {
              if (name.isEmpty) {
                chars.remove(slot);
              } else {
                chars.add(slot);
              }
            }
          case 'blocker':
            blockerAlpha = double.tryParse(cmd.value('a')) ?? blockerAlpha;
          case 'subtitle':
            if (si == sceneIndex && bi == beatIndex && headline.isEmpty) {
              headline = cmd.value('text');
            }
        }
      }
    }
  }

  final summary = _BeatVisualSummary(
    backgroundKey: bg,
    characterCount: chars.length,
    headline: headline,
    blockerAlpha: blockerAlpha.clamp(0.0, 0.85),
  );
  if (_beatThumbnailCache.length > 256) {
    _beatThumbnailCache.clear();
  }
  _beatThumbnailCache[cacheKey] = summary;
  return summary;
}

/// 编排台：故事板卡片墙（P1-1 / F1）与移动端轻分镜切换（§4.2）。
class EditorBoardView extends StatefulWidget {
  const EditorBoardView({
    super.key,
    required this.project,
    required this.activeScene,
    required this.activeBeat,
    required this.issues,
    required this.compact,
    required this.onOpenBeat,
    required this.onAddBeat,
    required this.onInsertBeatAfter,
    required this.onDuplicateBeats,
    required this.onDeleteBeats,
    required this.onMoveBeat,
    required this.onMarkBeat,
  });

  final EditorProject project;
  final int activeScene;
  final int activeBeat;
  final List<EditorIssue> issues;
  final bool compact;
  final void Function(int scene, int beat) onOpenBeat;
  final void Function(int scene) onAddBeat;
  final void Function(int scene, int beat) onInsertBeatAfter;
  final void Function(List<BeatRef> refs) onDuplicateBeats;
  final void Function(List<BeatRef> refs) onDeleteBeats;
  final void Function(BeatRef from, int toScene, int toBeat) onMoveBeat;
  final void Function(int scene, int beat) onMarkBeat;

  @override
  State<EditorBoardView> createState() => _EditorBoardViewState();
}

class _EditorBoardViewState extends State<EditorBoardView> {
  BoardCardSize _cardSize = BoardCardSize.medium;
  BoardFilter _filter = BoardFilter.all;
  final Set<BeatRef> _selected = {};

  // P1-1 框选批量：鼠标在卡片墙空白处拖出矩形选区。
  static const double _marqueeSlop = 4.0;
  final Map<BeatRef, GlobalKey> _cardKeys = {};
  final Map<int, GlobalKey> _newBeatKeys = {};
  final GlobalKey _boardAreaKey = GlobalKey();
  int? _marqueePointer;
  Offset? _marqueeOrigin;
  Offset? _marqueeCurrent;
  Rect? _marquee;
  bool _marqueeAdditive = false;
  Set<BeatRef> _marqueeBase = const {};

  int _warningsFor(int sceneIndex, int beatIndex) {
    var count = 0;
    for (final issue in widget.issues) {
      if (issue.sceneIndex == sceneIndex && issue.beatIndex == beatIndex) {
        count++;
      }
    }
    return count;
  }

  bool _matchesFilter(int sceneIndex, int beatIndex) {
    final beat = widget.project.scenes[sceneIndex].beats[beatIndex];
    return switch (_filter) {
      BoardFilter.all => true,
      BoardFilter.warnings => _warningsFor(sceneIndex, beatIndex) > 0,
      BoardFilter.marked => beat.marker.isNotEmpty,
    };
  }

  double get _cardWidth => switch (_cardSize) {
    BoardCardSize.small => 188,
    BoardCardSize.medium => 244,
    BoardCardSize.large => 312,
  };

  void _toggleSelect(BeatRef ref) {
    setState(() {
      if (!_selected.remove(ref)) {
        _selected.add(ref);
      }
    });
  }

  GlobalKey _cardKey(BeatRef ref) => _cardKeys.putIfAbsent(ref, GlobalKey.new);

  GlobalKey _newBeatKey(int sceneIndex) =>
      _newBeatKeys.putIfAbsent(sceneIndex, GlobalKey.new);

  Rect? _globalRect(GlobalKey key) {
    final box = key.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  /// 框选只在卡片墙空白处生效；落在分镜卡片或「新建分镜」占位卡上时
  /// 让位给点选/勾选/拖拽重排等既有交互。
  bool _isOnInteractiveControl(Offset global) {
    for (final key in _cardKeys.values) {
      if (_globalRect(key)?.contains(global) ?? false) return true;
    }
    for (final key in _newBeatKeys.values) {
      if (_globalRect(key)?.contains(global) ?? false) return true;
    }
    return false;
  }

  void _onBoardPointerDown(PointerDownEvent event) {
    if (_marqueePointer != null) return;
    // 仅鼠标左键框选；触摸/触控笔不在框选范围（触控笔在默认 dragDevices
    // 内，同时框选会与列表滚动冲突，且 §4.2 移动端本就无多选）。
    if (event.kind != PointerDeviceKind.mouse) return;
    if ((event.buttons & kPrimaryButton) == 0) return;
    if (_isOnInteractiveControl(event.position)) return;
    _marqueePointer = event.pointer;
    _marqueeOrigin = event.position;
    _marqueeCurrent = event.position;
    _marqueeAdditive = HardwareKeyboard.instance.isControlPressed;
    // 始终保存框选前的完整选择：取消框选时恢复原选择，
    // Ctrl 追加与否在选区同步时再决定。
    _marqueeBase = {..._selected};
  }

  void _onBoardPointerMove(PointerMoveEvent event) {
    if (event.pointer != _marqueePointer) return;
    _marqueeCurrent = event.position;
    if (_marquee == null &&
        (_marqueeCurrent! - _marqueeOrigin!).distance <= _marqueeSlop) {
      return;
    }
    setState(_syncMarqueeSelection);
  }

  /// 以拖拽矩形实时覆盖卡片更新选择集；Ctrl 按住时在原选择上追加。
  void _syncMarqueeSelection() {
    final rect = Rect.fromPoints(_marqueeOrigin!, _marqueeCurrent!);
    _marquee = rect;
    _selected
      ..clear()
      ..addAll(_marqueeAdditive ? _marqueeBase : const {});
    for (final entry in _cardKeys.entries) {
      final cardRect = _globalRect(entry.value);
      if (cardRect != null && cardRect.overlaps(rect)) {
        _selected.add(entry.key);
      }
    }
  }

  void _onBoardPointerUp(PointerUpEvent event) {
    if (event.pointer != _marqueePointer) return;
    final wasMarquee = _marquee != null;
    final additive = _marqueeAdditive;
    _resetMarqueeTracking();
    setState(() {
      _marquee = null;
      // 未拖出矩形：视作点击空白处，清除已有选择。
      if (!wasMarquee && !additive) _selected.clear();
    });
  }

  void _onBoardPointerCancel(PointerCancelEvent event) {
    if (event.pointer != _marqueePointer) return;
    final base = _marqueeBase;
    _resetMarqueeTracking();
    setState(() {
      _marquee = null;
      _selected
        ..clear()
        ..addAll(base);
    });
  }

  void _resetMarqueeTracking() {
    _marqueePointer = null;
    _marqueeOrigin = null;
    _marqueeCurrent = null;
    _marqueeAdditive = false;
    _marqueeBase = const {};
  }

  /// 框选矩形覆盖层（全局坐标 → 卡片墙本地坐标）。
  Widget _marqueeOverlay() {
    final rect = _marquee;
    final box = _boardAreaKey.currentContext?.findRenderObject();
    if (rect == null || box is! RenderBox || !box.attached || !box.hasSize) {
      return const SizedBox.shrink();
    }
    final scheme = Theme.of(context).colorScheme;
    return Positioned.fromRect(
      rect: Rect.fromPoints(
        box.globalToLocal(rect.topLeft),
        box.globalToLocal(rect.bottomRight),
      ),
      child: IgnorePointer(
        child: Container(
          key: const ValueKey('board-marquee'),
          decoration: BoxDecoration(
            color: scheme.primary.withValues(alpha: 0.08),
            border: Border.all(color: scheme.primary),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 清理因删除导致的失效选择与对应 key。
    _selected.removeWhere(
      (r) =>
          r.scene >= widget.project.scenes.length ||
          r.beat >= widget.project.scenes[r.scene].beats.length,
    );
    _cardKeys.removeWhere(
      (r, _) =>
          r.scene >= widget.project.scenes.length ||
          r.beat >= widget.project.scenes[r.scene].beats.length,
    );
    _newBeatKeys.removeWhere((si, _) => si >= widget.project.scenes.length);

    if (widget.compact) {
      return _buildMobileSwitcher(context);
    }
    return _buildDesktopBoard(context);
  }

  /// §4.2 移动端轻量化分镜切换：不做多选批量，点击卡片直回演出台。
  Widget _buildMobileSwitcher(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            '轻分镜切换：点击卡片直接回演出台；多选批量与剧本表格请用桌面端。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        const SizedBox(height: 12),
        for (var si = 0; si < widget.project.scenes.length; si++) ...[
          Row(
            children: [
              Expanded(
                child: Text(
                  '${widget.project.scenes[si].title} · ${widget.project.scenes[si].beats.length} 镜',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              TextButton.icon(
                onPressed: () => widget.onAddBeat(si),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('新建分镜'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 168,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: widget.project.scenes[si].beats.length,
              separatorBuilder: (_, _) => const SizedBox(width: 10),
              itemBuilder: (context, bi) => SizedBox(
                width: 200,
                child: _BeatCard(
                  project: widget.project,
                  sceneIndex: si,
                  beatIndex: bi,
                  warnings: _warningsFor(si, bi),
                  active: si == widget.activeScene && bi == widget.activeBeat,
                  selected: false,
                  compact: true,
                  onTap: () => widget.onOpenBeat(si, bi),
                  onDoubleTap: () => widget.onOpenBeat(si, bi),
                  onToggleSelect: null,
                  onMenuAction: null,
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
        ],
      ],
    );
  }

  Widget _buildDesktopBoard(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final totalBeats = widget.project.beatCount;
    final totalDuration = formatEstimatedDuration(
      widget.project.estimatedSeconds,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 编排台工具栏
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
          ),
          child: Wrap(
            spacing: 10,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                '编排台 · 故事板',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              SegmentedButton<BoardFilter>(
                showSelectedIcon: false,
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                segments: const [
                  ButtonSegment(value: BoardFilter.all, label: Text('全部')),
                  ButtonSegment(
                    value: BoardFilter.warnings,
                    label: Text('有警告'),
                  ),
                  ButtonSegment(value: BoardFilter.marked, label: Text('有标记')),
                ],
                selected: {_filter},
                onSelectionChanged: (s) => setState(() => _filter = s.first),
              ),
              SegmentedButton<BoardCardSize>(
                showSelectedIcon: false,
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                segments: const [
                  ButtonSegment(value: BoardCardSize.small, label: Text('小卡')),
                  ButtonSegment(value: BoardCardSize.medium, label: Text('中卡')),
                  ButtonSegment(value: BoardCardSize.large, label: Text('大卡')),
                ],
                selected: {_cardSize},
                onSelectionChanged: (s) => setState(() => _cardSize = s.first),
              ),
              FilledButton.tonalIcon(
                onPressed: () => widget.onAddBeat(widget.activeScene),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('新建分镜'),
              ),
              if (_selected.isNotEmpty) ...[
                Chip(
                  label: Text('已选 ${_selected.length} 镜'),
                  visualDensity: VisualDensity.compact,
                ),
                OutlinedButton.icon(
                  onPressed: () {
                    final list = _selected.toList();
                    widget.onDuplicateBeats(list);
                    setState(_selected.clear);
                  },
                  icon: const Icon(Icons.copy, size: 15),
                  label: const Text('复制'),
                ),
                OutlinedButton.icon(
                  onPressed: () {
                    final list = _selected.toList();
                    widget.onDeleteBeats(list);
                    setState(_selected.clear);
                  },
                  icon: const Icon(Icons.delete_outline, size: 15),
                  label: const Text('删除'),
                ),
                TextButton(
                  onPressed: () => setState(_selected.clear),
                  child: const Text('取消选择'),
                ),
              ],
            ],
          ),
        ),
        // 按幕分组的卡片墙；Listener 支撑框选（鼠标空白处拖出矩形）。
        Expanded(
          child: Listener(
            onPointerDown: _onBoardPointerDown,
            onPointerMove: _onBoardPointerMove,
            onPointerUp: _onBoardPointerUp,
            onPointerCancel: _onBoardPointerCancel,
            child: Stack(
              key: _boardAreaKey,
              fit: StackFit.expand,
              children: [
                ListView(
                  padding: const EdgeInsets.all(14),
                  children: [
                    for (var si = 0; si < widget.project.scenes.length; si++)
                      _buildSceneSection(context, si),
                  ],
                ),
                if (_marquee != null) _marqueeOverlay(),
              ],
            ),
          ),
        ),
        // 底部全作品估算时长与分镜数统计
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: scheme.outlineVariant)),
          ),
          child: Row(
            children: [
              Text(
                '共 ${widget.project.scenes.length} 幕 · $totalBeats 个分镜 · 估算总时长 $totalDuration',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const Spacer(),
              Text(
                '空白处拖拽框选 · 双击卡片进入演出台 · 拖拽卡片可同幕或跨幕重排',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSceneSection(BuildContext context, int sceneIndex) {
    final scene = widget.project.scenes[sceneIndex];
    final scheme = Theme.of(context).colorScheme;
    final visibleBeats = [
      for (var bi = 0; bi < scene.beats.length; bi++)
        if (_matchesFilter(sceneIndex, bi)) bi,
    ];

    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 10,
                height: 10,
                margin: const EdgeInsets.only(right: 6),
                decoration: BoxDecoration(
                  color: Color(
                    editorMarkerColors[scene.marker.color] ?? 0xFFA5C7D5,
                  ),
                  shape: BoxShape.circle,
                ),
              ),
              Text(
                '${scene.title} · ${scene.beats.length} 镜 · 约 ${formatEstimatedDuration(scene.estimatedSeconds)}',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const Spacer(),
              Text(
                '双击卡片进演出台',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final bi in visibleBeats)
                _buildDraggableCard(context, sceneIndex, bi),
              // 原型 `.board-empty`：每幕末尾「＋ 新建分镜」虚线占位卡（可作为跨幕拖放落点）
              DragTarget<BeatRef>(
                onWillAcceptWithDetails: (details) =>
                    !(details.data.scene == sceneIndex &&
                        details.data.beat == scene.beats.length - 1),
                onAcceptWithDetails: (details) => widget.onMoveBeat(
                  details.data,
                  sceneIndex,
                  scene.beats.length,
                ),
                builder: (context, candidate, _) => InkWell(
                  key: _newBeatKey(sceneIndex),
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => widget.onAddBeat(sceneIndex),
                  child: Container(
                    width: _cardWidth,
                    height: 188,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: candidate.isNotEmpty
                            ? scheme.primary
                            : scheme.outlineVariant,
                        width: candidate.isNotEmpty ? 2 : 1,
                      ),
                      color: candidate.isNotEmpty
                          ? scheme.primaryContainer.withValues(alpha: 0.2)
                          : scheme.surfaceContainerLowest,
                    ),
                    alignment: Alignment.center,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.add_circle_outline,
                          color: scheme.onSurfaceVariant,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          candidate.isNotEmpty ? '释放移动到此幕末尾' : '＋ 新建分镜',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDraggableCard(
    BuildContext context,
    int sceneIndex,
    int beatIndex,
  ) {
    final ref = (scene: sceneIndex, beat: beatIndex);
    final active =
        sceneIndex == widget.activeScene && beatIndex == widget.activeBeat;
    final selected = _selected.contains(ref);
    final warnings = _warningsFor(sceneIndex, beatIndex);

    final card = SizedBox(
      width: _cardWidth,
      child: _BeatCard(
        project: widget.project,
        sceneIndex: sceneIndex,
        beatIndex: beatIndex,
        warnings: warnings,
        active: active,
        selected: selected,
        compact: false,
        onTap: () => _toggleSelect(ref),
        onDoubleTap: () => widget.onOpenBeat(sceneIndex, beatIndex),
        onToggleSelect: () => _toggleSelect(ref),
        onMenuAction: (action) {
          switch (action) {
            case 'open':
              widget.onOpenBeat(sceneIndex, beatIndex);
            case 'insert_after':
              widget.onInsertBeatAfter(sceneIndex, beatIndex);
            case 'duplicate':
              widget.onDuplicateBeats([ref]);
            case 'mark':
              widget.onMarkBeat(sceneIndex, beatIndex);
            case 'delete':
              widget.onDeleteBeats([ref]);
          }
        },
      ),
    );

    return DragTarget<BeatRef>(
      key: _cardKey(ref),
      onWillAcceptWithDetails: (details) => details.data != ref,
      onAcceptWithDetails: (details) =>
          widget.onMoveBeat(details.data, sceneIndex, beatIndex),
      builder: (context, candidate, _) => Draggable<BeatRef>(
        data: ref,
        feedback: Material(
          elevation: 6,
          borderRadius: BorderRadius.circular(10),
          child: Opacity(opacity: 0.9, child: card),
        ),
        childWhenDragging: Opacity(opacity: 0.35, child: card),
        child: Container(
          decoration: candidate.isNotEmpty
              ? BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Theme.of(context).colorScheme.primary,
                    width: 2,
                  ),
                )
              : null,
          child: card,
        ),
      ),
    );
  }
}

class _BeatCard extends StatelessWidget {
  const _BeatCard({
    required this.project,
    required this.sceneIndex,
    required this.beatIndex,
    required this.warnings,
    required this.active,
    required this.selected,
    required this.compact,
    required this.onTap,
    required this.onDoubleTap,
    required this.onToggleSelect,
    required this.onMenuAction,
  });

  final EditorProject project;
  final int sceneIndex;
  final int beatIndex;
  final int warnings;
  final bool active;
  final bool selected;
  final bool compact;
  final VoidCallback onTap;
  final VoidCallback onDoubleTap;
  final VoidCallback? onToggleSelect;
  final void Function(String action)? onMenuAction;

  @override
  Widget build(BuildContext context) {
    final beat = project.scenes[sceneIndex].beats[beatIndex];
    final visual = _resolveBeatVisual(project, sceneIndex, beatIndex);
    final bgAsset = project.assets[visual.backgroundKey];
    final scheme = Theme.of(context).colorScheme;
    final markerColor = Color(editorMarkerColors[beat.marker.color] ?? 0xFFA5C7D5);

    return Card(
      key: ValueKey(('board-card', sceneIndex, beatIndex)),
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: selected
              ? scheme.primary
              : active
              ? scheme.secondary
              : scheme.outlineVariant,
          width: selected || active ? 2 : 1,
        ),
      ),
      child: InkWell(
        onTap: onTap,
        onDoubleTap: compact ? null : onDoubleTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            // 16:9 缩略图区域（带签名缓存）
            AspectRatio(
              aspectRatio: 16 / 9,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (bgAsset != null && bgAsset.isImage)
                    Image.memory(bgAsset.bytes, fit: BoxFit.cover)
                  else
                    Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            const Color(0xFF17202A),
                            visual.backgroundKey.isEmpty
                                ? const Color(0xFF222B33)
                                : const Color(0xFF233845),
                          ],
                        ),
                      ),
                    ),
                  if (visual.blockerAlpha > 0)
                    Container(
                      color: Colors.black.withValues(alpha: visual.blockerAlpha),
                    ),
                  // 底部首句预览条
                  Positioned(
                    left: 6,
                    right: 6,
                    bottom: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xB8111518),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        visual.headline.isEmpty
                            ? (visual.backgroundKey.isEmpty
                                  ? '空分镜'
                                  : '场景：${visual.backgroundKey}')
                            : visual.headline,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ),
                  // 左上角标记色与勾选框
                  Positioned(
                    top: 4,
                    left: 4,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (onToggleSelect != null)
                          GestureDetector(
                            onTap: onToggleSelect,
                            child: Container(
                              width: 20,
                              height: 20,
                              decoration: BoxDecoration(
                                color: selected
                                    ? scheme.primary
                                    : const Color(0x99111518),
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(color: Colors.white54),
                              ),
                              child: selected
                                  ? Icon(
                                      Icons.check,
                                      size: 14,
                                      color: scheme.onPrimary,
                                    )
                                  : null,
                            ),
                          ),
                        if (beat.marker.isNotEmpty) ...[
                          const SizedBox(width: 4),
                          Tooltip(
                            message: beat.marker.note.isEmpty
                                ? (editorMarkerLabels[beat.marker.color] ??
                                      '已标记')
                                : beat.marker.note,
                            child: Container(
                              width: 12,
                              height: 12,
                              decoration: BoxDecoration(
                                color: markerColor,
                                shape: BoxShape.circle,
                                border: Border.all(color: Colors.white),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  // 右上角能力角标与警告徽标
                  Positioned(
                    top: 4,
                    right: 4,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (beat.hasBranch)
                          _miniBadge('分支', const Color(0xCCA5C7D5)),
                        if (beat.hasAudio)
                          _miniBadge('音频', const Color(0xCCA4C6A0)),
                        if (beat.hasFx)
                          _miniBadge('特效', const Color(0xCCDFC080)),
                        if (warnings > 0)
                          _miniBadge('!$warnings', const Color(0xDDF28D8D)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            // 卡片信息行
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 4, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          beat.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelLarge,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${beat.commands.length} 条指令 · 约 ${formatEstimatedDuration(beat.estimatedSeconds)}'
                          '${visual.characterCount > 0 ? ' · ${visual.characterCount} 立绘' : ''}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  if (!compact && onMenuAction != null)
                    PopupMenuButton<String>(
                      tooltip: '分镜操作',
                      iconSize: 18,
                      padding: EdgeInsets.zero,
                      onSelected: onMenuAction,
                      itemBuilder: (context) => const [
                        PopupMenuItem(value: 'open', child: Text('在演出台打开')),
                        PopupMenuItem(
                          value: 'insert_after',
                          child: Text('在此后插入分镜'),
                        ),
                        PopupMenuItem(
                          value: 'duplicate',
                          child: Text('从此派生副本'),
                        ),
                        PopupMenuItem(value: 'mark', child: Text('设置标记与备注')),
                        PopupMenuDivider(),
                        PopupMenuItem(value: 'delete', child: Text('删除分镜')),
                      ],
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _miniBadge(String text, Color bg) {
    return Container(
      margin: const EdgeInsets.only(left: 3),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Color(0xFF111518),
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
