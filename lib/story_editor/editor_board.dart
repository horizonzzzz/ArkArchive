import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../app/archive_widgets.dart';

import 'editor_preview.dart';
import 'editor_project.dart';

/// 编排台卡片缩放档位（P1-1）。
enum BoardCardSize { small, medium, large }

/// 编排台筛选条件（P1-1）。
enum BoardFilter { all, warnings, marked }

/// 分镜卡片定位引用。
typedef BeatRef = ({int scene, int beat});

/// 单个分镜继承前序视觉状态后的缩略图摘要。
class _BeatVisualSummary {
  const _BeatVisualSummary({
    required this.backgroundKey,
    required this.cgKey,
    required this.characters,
    required this.focusedSlots,
    required this.headline,
    required this.blockerAlpha,
    required this.blockerColor,
  });

  final String backgroundKey;
  final String cgKey;
  final Map<String, String> characters;
  final Set<String> focusedSlots;
  final String headline;
  final double blockerAlpha;
  final Color blockerColor;

  int get characterCount => characters.length;
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
    this.resources,
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
  final EditorPreviewResources? resources;
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
  EditorProject? _visualProject;
  List<List<_BeatVisualSummary>> _visualSummaries = const [];
  static String _normalizeSlot(String raw) => switch (raw.trim().toLowerCase()) {
    'l' || 'left' => 'l',
    'm' || 'middle' || 'center' => 'm',
    'r' || 'right' => 'r',
    _ => '',
  };

  static Set<String> _parseFocusSlots(String raw) {
    final value = raw.trim().toLowerCase();
    if (value.isEmpty || value == 'all') return const {'l', 'm', 'r'};
    return {
      for (final part in value.split(','))
        if (_normalizeSlot(part).isNotEmpty) _normalizeSlot(part),
    };
  }

  static String _firstGroupImage(String group) => group
      .split('/')
      .map((s) => s.trim())
      .firstWhere((s) => s.isNotEmpty, orElse: () => '');

  List<List<_BeatVisualSummary>> _visualsForProject() {
    if (identical(_visualProject, widget.project)) return _visualSummaries;

    var backgroundKey = '';
    var cgKey = '';
    var characters = const <String, String>{};
    var focusedSlots = const <String>{'l', 'm', 'r'};
    var blockerAlpha = 0.0;
    var blockerColor = Colors.black;
    final scenes = <List<_BeatVisualSummary>>[];
    for (final scene in widget.project.scenes) {
      final summaries = <_BeatVisualSummary>[];
      for (final beat in scene.beats) {
        var headline = beat.leadLine;
        for (final command in beat.commands) {
          switch (command.tag) {
            case 'background':
              backgroundKey = command.value('image').trim();
            case 'image':
              cgKey = command.value('image').trim();
            case 'largebg' || 'gridbg' || 'verticalbg':
              backgroundKey = _firstGroupImage(command.value('imagegroup'));
            case 'largeimg':
              final raw = command.value('cggroup').isNotEmpty
                  ? command.value('cggroup')
                  : command.value('imagegroup');
              cgKey = _firstGroupImage(raw);
            case 'charslot':
              final rawSlot = command.value('slot').trim();
              final name = command.value('name').trim();
              if (rawSlot.isEmpty && name.isEmpty) {
                if (characters.isNotEmpty) characters = const {};
              } else {
                final slot = _normalizeSlot(rawSlot);
                if (slot.isNotEmpty) {
                  focusedSlots = _parseFocusSlots(command.value('focus'));
                  if (name == 'char_empty') {
                    if (characters.containsKey(slot)) {
                      characters = Map.unmodifiable(
                        {...characters}..remove(slot),
                      );
                    }
                  } else if (name.isNotEmpty && characters[slot] != name) {
                    characters = Map.unmodifiable({...characters, slot: name});
                  }
                }
              }
            case 'character':
              final first = command.value('name').trim();
              final second = command.value('name2').trim();
              if (first.isEmpty && second.isEmpty) {
                if (characters.isNotEmpty) characters = const {};
              } else {
                final next = <String, String>{...characters};
                if (second.isEmpty) {
                  next.removeWhere((k, _) => k != 'm');
                  if (first.isEmpty) {
                    next.remove('m');
                  } else {
                    next['m'] = first;
                  }
                } else {
                  next.remove('m');
                  next['l'] = first;
                  next['r'] = second;
                }
                final focus = int.tryParse(command.value('focus')) ?? 0;
                focusedSlots = switch (focus) {
                  1 => second.isEmpty ? const {'m'} : const {'l'},
                  2 => const {'r'},
                  3 => const <String>{},
                  _ => const {'l', 'm', 'r'},
                };
                characters = Map.unmodifiable(next);
              }
            case 'blocker':
              blockerAlpha = command.args.containsKey('a')
                  ? (double.tryParse(command.value('a')) ?? 1.0)
                        .clamp(0.0, 1.0)
                  : 1.0;
              double channel(String key, double fallback) =>
                  command.args.containsKey(key)
                  ? (double.tryParse(command.value(key)) ?? fallback)
                        .clamp(0.0, 1.0)
                  : fallback;
              blockerColor = Color.from(
                alpha: 1.0,
                red: channel('r', 0),
                green: channel('g', 0),
                blue: channel('b', 0),
              );
            case 'subtitle':
              if (headline.isEmpty) headline = command.value('text');
          }
        }
        summaries.add(
          _BeatVisualSummary(
            backgroundKey: backgroundKey,
            cgKey: cgKey,
            characters: characters,
            focusedSlots: focusedSlots,
            headline: headline,
            blockerAlpha: blockerAlpha.clamp(0.0, 0.85),
            blockerColor: blockerColor,
          ),
        );
      }
      scenes.add(summaries);
    }
    _visualProject = widget.project;
    _visualSummaries = scenes;
    return scenes;
  }

  List<List<_BeatVisualSummary>> get _visuals => _visualsForProject();
  List<EditorIssue>? _warningIssues;
  final Map<BeatRef, int> _warningCounts = {};

  // P1-1 框选批量：鼠标在卡片墙空白处拖出矩形选区。
  static const double _marqueeSlop = 4.0;
  final _scroll = ScrollController();
  static const _padding = 14.0,
      _gap = 12.0,
      _header = 40.0,
      _height = 188.0,
      _footer = 18.0;
  List<List<int>> _visible = const [];
  double _gridWidth = 0;
  int get _columns =>
      ((_gridWidth + _gap) / (_cardWidth + _gap)).floor().clamp(1, 10000);

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  final GlobalKey _boardAreaKey = GlobalKey();
  final GlobalKey _scrollbarKey = GlobalKey();
  int? _marqueePointer;
  Offset? _marqueeOrigin;
  Offset? _marqueeCurrent;
  Rect? _marquee;
  bool _marqueeAdditive = false;
  Set<BeatRef> _marqueeBase = const {};

  int _warningsFor(int sceneIndex, int beatIndex) {
    if (!identical(_warningIssues, widget.issues)) {
      _warningIssues = widget.issues;
      _warningCounts.clear();
      for (final issue in widget.issues) {
        final scene = issue.sceneIndex;
        final beat = issue.beatIndex;
        if (scene >= 0 && beat >= 0) {
          final ref = (scene: scene, beat: beat);
          _warningCounts[ref] = (_warningCounts[ref] ?? 0) + 1;
        }
      }
    }
    return _warningCounts[(scene: sceneIndex, beat: beatIndex)] ?? 0;
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

  Iterable<BeatRef> _intersections(Rect rect) sync* {
    final box = _boardAreaKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize || !_scroll.hasClients) return;
    final query = Rect.fromPoints(
      box.globalToLocal(rect.topLeft),
      box.globalToLocal(rect.bottomRight),
    ).shift(Offset(-_padding, _scroll.offset - _padding));
    final columns = _columns;
    final width = (_gridWidth - (columns - 1) * _gap) / columns;
    var top = 0.0;
    for (final (si, beats) in _visible.indexed) {
      top += _header;
      final count = beats.length + 1;
      final rows = (count + columns - 1) ~/ columns;
      if (top > query.bottom) break;
      const stride = _height + _gap;
      final first = ((query.top - top) / stride).floor().clamp(0, rows);
      final last = ((query.bottom - top) / stride).floor().clamp(-1, rows - 1);
      for (var row = first; row <= last; row++) {
        for (var col = 0; col < columns; col++) {
          final i = row * columns + col;
          if (i >= count) break;
          final cell = Rect.fromLTWH(
            col * (width + _gap),
            top + row * stride,
            width,
            _height,
          );
          if (cell.overlaps(query) ||
              (query.isEmpty && cell.contains(query.topLeft))) {
            yield (scene: si, beat: i == beats.length ? -1 : beats[i]);
          }
        }
      }
      top += rows * stride - _gap + _footer;
    }
  }

  bool _isOnScrollbar(Offset globalPosition) {
    if (!_scroll.hasClients || _scroll.position.maxScrollExtent <= 0) {
      return false;
    }
    final root = _scrollbarKey.currentContext?.findRenderObject();
    if (root == null) return false;
    RenderCustomPaint? target;
    void findPainter(RenderObject node) {
      if (target != null) return;
      if (node is RenderCustomPaint &&
          node.foregroundPainter is ScrollbarPainter) {
        target = node;
        return;
      }
      node.visitChildren(findPainter);
    }

    findPainter(root);
    final box = target;
    if (box == null || !box.hasSize) return false;
    final local = box.globalToLocal(globalPosition);
    if (local.dx >= box.size.width - _padding) return true;
    final painter = box.foregroundPainter! as ScrollbarPainter;
    return painter.hitTestInteractive(
      local,
      PointerDeviceKind.mouse,
      forHover: true,
    );
  }

  void _cancelMarquee() {
    if (_marqueePointer == null) return;
    final base = _marqueeBase;
    final hadMarquee = _marquee != null;
    _resetMarqueeTracking();
    if (!hadMarquee) return;
    setState(() {
      _marquee = null;
      _selected
        ..clear()
        ..addAll(base);
    });
  }

  void _onBoardPointerDown(PointerDownEvent event) {
    if (_marqueePointer != null) return;
    // 仅鼠标左键框选；触摸/触控笔不在框选范围（触控笔在默认 dragDevices
    // 内，同时框选会与列表滚动冲突，且 §4.2 移动端本就无多选）。
    if (event.kind != PointerDeviceKind.mouse) return;
    if ((event.buttons & kPrimaryButton) == 0) return;
    if (_isOnScrollbar(event.position)) return;
    if (_intersections(Rect.fromPoints(event.position, event.position))
        .isNotEmpty) {
      return;
    }
    _marqueePointer = event.pointer;
    _marqueeOrigin = event.position;
    _marqueeCurrent = event.position;
    _marqueeAdditive = HardwareKeyboard.instance.isControlPressed;
    // 始终保存框选前的完整选择：取消框选时恢复原选择，
    // Ctrl 追加与否在选区同步时再决定。
    _marqueeBase = {..._selected};
  }

  void _onBoardPointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent) _cancelMarquee();
  }

  bool _onBoardScrollNotification(ScrollNotification notification) {
    if (_marqueePointer == null) return false;
    if (notification is ScrollStartNotification ||
        (notification is ScrollUpdateNotification &&
            (notification.dragDetails != null ||
                (notification.scrollDelta?.abs() ?? 0) > 0))) {
      _cancelMarquee();
    }
    return false;
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
    _selected.addAll(_intersections(rect).where((ref) => ref.beat >= 0));
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
                  resources: widget.resources,
                  visual: _visuals[si][bi],
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
              Text('编排台 · 故事板', style: Theme.of(context).textTheme.titleSmall),
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
        // 按幕分组的卡片墙；Scrollbar 置于框选 Listener 外层，避免右侧滚动条拖动触发框选。
        Expanded(
          child: Scrollbar(
            key: _scrollbarKey,
            controller: _scroll,
            thumbVisibility: true,
            child: Listener(
              onPointerDown: _onBoardPointerDown,
              onPointerMove: _onBoardPointerMove,
              onPointerUp: _onBoardPointerUp,
              onPointerCancel: _onBoardPointerCancel,
              onPointerSignal: _onBoardPointerSignal,
              child: Stack(
                key: _boardAreaKey,
                fit: StackFit.expand,
                children: [
                  LayoutBuilder(
                    builder: (context, constraints) {
                      _gridWidth = (constraints.maxWidth - 2 * _padding).clamp(
                        0.0,
                        double.infinity,
                      );
                      _visible = [
                        for (final (si, scene) in widget.project.scenes.indexed)
                          [
                            for (final (bi, _) in scene.beats.indexed)
                              if (_matchesFilter(si, bi)) bi,
                          ],
                      ];
                      return ScrollConfiguration(
                        behavior: ScrollConfiguration.of(
                          context,
                        ).copyWith(scrollbars: false),
                        child: NotificationListener<ScrollNotification>(
                          onNotification: _onBoardScrollNotification,
                          child: CustomScrollView(
                            controller: _scroll,
                            slivers: [
                              SliverPadding(
                                padding: const EdgeInsets.all(_padding),
                                sliver: SliverMainAxisGroup(
                                  slivers: [
                                    for (final (si, visible)
                                        in _visible.indexed)
                                      _buildSceneSection(context, si, visible),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                  if (_marquee != null) _marqueeOverlay(),
                ],
              ),
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
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSceneSection(
    BuildContext context,
    int sceneIndex,
    List<int> visibleBeats,
  ) {
    final scene = widget.project.scenes[sceneIndex];
    final scheme = Theme.of(context).colorScheme;
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: SizedBox(
            height: _header,
            child: Row(
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
                  style: Theme.of(context).textTheme.labelSmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ),
        SliverGrid.builder(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: _columns,
            crossAxisSpacing: _gap,
            mainAxisSpacing: _gap,
            mainAxisExtent: _height,
          ),
          itemCount: visibleBeats.length + 1,
          itemBuilder: (context, index) {
            if (index < visibleBeats.length) {
              return _buildDraggableCard(
                context,
                sceneIndex,
                visibleBeats[index],
              );
            }
            return DragTarget<BeatRef>(
              onWillAcceptWithDetails: (details) =>
                  !(details.data.scene == sceneIndex &&
                      details.data.beat == scene.beats.length - 1),
              onAcceptWithDetails: (details) => widget.onMoveBeat(
                details.data,
                sceneIndex,
                scene.beats.length,
              ),
              builder: (context, candidate, _) => InkWell(
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
            );
          },
        ),
        const SliverToBoxAdapter(child: SizedBox(height: _footer)),
      ],
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
      height: _height,
      child: _BeatCard(
        project: widget.project,
        resources: widget.resources,
        visual: _visuals[sceneIndex][beatIndex],
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
      key: ValueKey(ref),
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
    required this.resources,
    required this.visual,
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
  final EditorPreviewResources? resources;
  final _BeatVisualSummary visual;
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
    final hasSceneVisual =
        visual.backgroundKey.isNotEmpty || visual.cgKey.isNotEmpty;
    final sceneLabel = visual.cgKey.isNotEmpty
        ? visual.cgKey
        : visual.backgroundKey;
    final scheme = Theme.of(context).colorScheme;
    final markerColor = Color(
      editorMarkerColors[beat.marker.color] ?? 0xFFA5C7D5,
    );

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
            // 16:9 缩略图区域（降采样并按资源键缓存复用）
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          const Color(0xFF17202A),
                          !hasSceneVisual
                              ? const Color(0xFF222B33)
                              : const Color(0xFF233845),
                        ],
                      ),
                    ),
                  ),
                  if (visual.backgroundKey.isNotEmpty)
                    _BoardThumbnail(
                      keyName: visual.backgroundKey,
                      cg: false,
                      isCharacter: false,
                      localAsset: project.assets[visual.backgroundKey],
                      resources: resources,
                      story: project.derivedFrom,
                      fit: BoxFit.cover,
                    ),
                  if (visual.cgKey.isNotEmpty)
                    _BoardThumbnail(
                      keyName: visual.cgKey,
                      cg: true,
                      isCharacter: false,
                      localAsset: project.assets[visual.cgKey],
                      resources: resources,
                      story: project.derivedFrom,
                      fit: BoxFit.cover,
                    ),
                  for (final slot in const ['l', 'm', 'r'])
                    if (visual.characters[slot] case final charKey?)
                      _buildCharacterThumbnail(
                        slot,
                        charKey,
                        focused: visual.focusedSlots.contains(slot),
                      ),
                  if (visual.blockerAlpha > 0)
                    Container(
                      color: visual.blockerColor.withValues(
                        alpha: visual.blockerAlpha,
                      ),
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
                            ? (sceneLabel.isEmpty
                                  ? '空分镜'
                                  : '场景：$sceneLabel')
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
                        ArchivePopupMenuItem(
                          value: 'open',
                          child: Text('在演出台打开'),
                        ),
                        ArchivePopupMenuItem(
                          value: 'insert_after',
                          child: Text('在此后插入分镜'),
                        ),
                        ArchivePopupMenuItem(
                          value: 'duplicate',
                          child: Text('从此派生副本'),
                        ),
                        ArchivePopupMenuItem(
                          value: 'mark',
                          child: Text('设置标记与备注'),
                        ),
                        PopupMenuDivider(),
                        ArchivePopupMenuItem(
                          value: 'delete',
                          child: Text('删除分镜'),
                        ),
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

  Widget _buildCharacterThumbnail(
    String slot,
    String keyName, {
    required bool focused,
  }) {
    final alignment = switch (slot) {
      'l' => const Alignment(-0.62, 1.0),
      'r' => const Alignment(0.62, 1.0),
      _ => Alignment.bottomCenter,
    };
    Widget child = Align(
      alignment: alignment,
      child: FractionallySizedBox(
        widthFactor: 0.54,
        heightFactor: 0.96,
        child: _BoardThumbnail(
          keyName: keyName,
          cg: false,
          isCharacter: true,
          localAsset: project.assets[keyName],
          resources: resources,
          story: project.derivedFrom,
          fit: BoxFit.contain,
          alignment: Alignment.bottomCenter,
        ),
      ),
    );
    if (!focused) {
      child = Opacity(opacity: 0.72, child: child);
    }
    return child;
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

class _BoardThumbnail extends StatefulWidget {
  const _BoardThumbnail({
    required this.keyName,
    required this.cg,
    required this.isCharacter,
    required this.localAsset,
    required this.resources,
    required this.story,
    required this.fit,
    this.alignment = Alignment.center,
  });

  final String keyName;
  final bool cg;
  final bool isCharacter;
  final EditorAsset? localAsset;
  final EditorPreviewResources? resources;
  final String? story;
  final BoxFit fit;
  final Alignment alignment;

  @override
  State<_BoardThumbnail> createState() => _BoardThumbnailState();
}

class _BoardThumbnailState extends State<_BoardThumbnail> {
  ImageProvider? _provider;
  int _loadToken = 0;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(_BoardThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.keyName != widget.keyName ||
        oldWidget.cg != widget.cg ||
        oldWidget.isCharacter != widget.isCharacter ||
        oldWidget.localAsset != widget.localAsset ||
        oldWidget.resources != widget.resources ||
        oldWidget.story != widget.story) {
      _resolve();
    }
  }

  void _resolve() {
    final token = ++_loadToken;
    final local = widget.localAsset;
    if (local != null && local.isImage) {
      _provider = ResizeImage.resizeIfNeeded(
        widget.isCharacter ? 240 : 480,
        null,
        MemoryImage(local.bytes),
      );
      return;
    }
    final resources = widget.resources;
    if (resources == null) {
      _provider = null;
      return;
    }
    final cached = resources.peekThumbnail(
      widget.keyName,
      cg: widget.cg,
      isCharacter: widget.isCharacter,
    );
    if (cached != null) {
      _provider = cached;
      return;
    }
    _provider = null;
    resources
        .loadThumbnail(
          widget.keyName,
          cg: widget.cg,
          isCharacter: widget.isCharacter,
          story: widget.story,
        )
        .then((provider) {
          if (!mounted || token != _loadToken || provider == null) return;
          setState(() => _provider = provider);
        });
  }

  @override
  Widget build(BuildContext context) {
    final provider = _provider;
    if (provider == null) return const SizedBox.shrink();
    return Image(
      image: provider,
      fit: widget.fit,
      alignment: widget.alignment,
      filterQuality: FilterQuality.low,
      gaplessPlayback: true,
      errorBuilder: (_, _, _) => const SizedBox.shrink(),
    );
  }
}
