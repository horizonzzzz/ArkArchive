import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'editor_project.dart';
import 'editor_timeline.dart';
import 'editor_timeline_materials.dart';

class EditorTimelineView extends StatefulWidget {
  const EditorTimelineView({
    super.key,
    required this.timeline,
    required this.project,
    required this.playhead,
    required this.source,
    required this.affectedCount,
    required this.missing,
    required this.monitor,
    required this.materials,
    required this.inspector,
    required this.onSeek,
    required this.onSelectSource,
    required this.onOpen,
    required this.onInsert,
    required this.onSplit,
    required this.onTrim,
    required this.onReplace,
    required this.onFreeze,
  });

  final EditorTimeline timeline;
  final EditorProject project;
  final int playhead, affectedCount;
  final TrackAddress? source;
  final bool Function(TrackValue value, TrackKind kind) missing;
  final Widget monitor, materials, inspector;
  final void Function(TrackAddress cursor) onSeek, onOpen;
  final void Function(TrackAddress cursor, TrackAddress source) onSelectSource;
  final void Function(
    TrackAddress address,
    List<EditCommand> commands, [
    EditorAsset? asset,
  ])
  onInsert;
  final void Function(TrackAddress address, EditCommand command) onSplit;
  final void Function(
    TrackAddress address,
    EditCommand clear,
    List<TrackAddress> reentries,
  )
  onTrim;
  final void Function(
    TrackAddress address,
    String field,
    TimelineMaterial material,
  )
  onReplace;
  final VoidCallback onFreeze;

  @override
  State<EditorTimelineView> createState() => _EditorTimelineViewState();
}

class _EditorTimelineViewState extends State<EditorTimelineView> {
  static const double _unit = 38, _row = 32;
  final _horizontal = ScrollController();
  final _boardKey = GlobalKey();
  TrackKind? _filter;
  String? _role;
  TrackSlot? _slot;
  bool _showInspector = false;
  (TrackSpan, int)? _trim;

  EditorTimeline get _timeline => widget.timeline;

  @override
  void initState() {
    super.initState();
    _reveal();
  }

  @override
  void didUpdateWidget(EditorTimelineView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.timeline.scene != _timeline.scene) {
      _trim = null;
      _slot = null;
      _role = null;
      _clipColumn = null;
    }
    if (oldWidget.playhead != widget.playhead ||
        oldWidget.timeline.scene != _timeline.scene) {
      _reveal();
    }
  }

  void _reveal() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_horizontal.hasClients) return;
      final x = (widget.playhead + .5) * _unit;
      final viewport = _horizontal.position.viewportDimension;
      if (x < _horizontal.offset || x > _horizontal.offset + viewport) {
        _horizontal.jumpTo(
          (x - viewport / 2).clamp(0, _horizontal.position.maxScrollExtent),
        );
      }
    });
  }

  @override
  void dispose() {
    _horizontal.dispose();
    super.dispose();
  }

  String _label(TrackValue value) =>
      widget.project.assets[value.label]?.name ?? value.label;

  String _tooltip(TrackValue value, TrackKind kind, {bool inherited = false}) {
    final address = value.source;
    final beat = widget.project.scenes[address.scene].beats[address.beat];
    final command = beat.commands[address.command];
    return [
      '${inherited ? '继承 · ' : ''}${_label(value)}',
      if (widget.missing(value, kind)) '素材缺失',
      '${widget.project.scenes[address.scene].title} / ${beat.title} / 指令 ${address.command + 1}',
      ?command.raw,
      for (final entry in command.args.entries) '${entry.key} = ${entry.value}',
    ].join('\n');
  }

  Color _color(TrackKind kind) {
    final scheme = Theme.of(context).colorScheme;
    return switch (kind) {
      TrackKind.background => scheme.primaryContainer,
      TrackKind.cg => const Color(0xff64548d),
      TrackKind.character => const Color(0xff3f695c),
      TrackKind.subtitle => const Color(0xff885d35),
      TrackKind.music || TrackKind.sound => const Color(0xff386777),
      TrackKind.effect => const Color(0xff874e55),
      TrackKind.blocker => scheme.surfaceContainerHighest,
      _ => scheme.secondaryContainer,
    };
  }

  Iterable<TrackSlot> get _rows sync* {
    const fixed = <TrackSlot>[
      (kind: TrackKind.dialogue, id: ''),
      (kind: TrackKind.background, id: ''),
      (kind: TrackKind.cg, id: ''),
      (kind: TrackKind.character, id: 'l'),
      (kind: TrackKind.character, id: 'm'),
      (kind: TrackKind.character, id: 'r'),
      (kind: TrackKind.subtitle, id: ''),
      (kind: TrackKind.music, id: ''),
      (kind: TrackKind.blocker, id: ''),
    ];
    final dynamicRows =
        {
          ..._timeline.tracks.keys,
          ..._timeline.events.keys,
        }.where((s) => !fixed.contains(s)).toList()..sort(
          (a, b) => (a.kind.index - b.kind.index) == 0
              ? a.id.compareTo(b.id)
              : a.kind.index - b.kind.index,
        );
    for (final slot in [...fixed, ...dynamicRows]) {
      if (_filter != null && _filter != slot.kind) continue;
      if (_role != null &&
          slot.kind == TrackKind.character &&
          !(_timeline.tracks[slot] ?? []).any(_matchesRole)) {
        continue;
      }
      yield slot;
    }
  }

  bool _matchesRole(TrackSpan span) =>
      _role == null ||
      span.slot.kind != TrackKind.character ||
      [
        span.initial,
        for (final marker in span.markers) marker.$2,
      ].any((value) => characterTrackBase(value.label) == _role);

  int _columnAt(double x) =>
      (x / _unit).floor().clamp(0, _timeline.columns.length - 1);

  TrackSpan? get _selectedSpan {
    final slot = _slot;
    if (slot == null) return null;
    final span = _timeline.spanAt(slot, widget.playhead);
    if (span == null || widget.source == null) return null;
    return span.initial.source == widget.source ||
            span.markers.any((m) => m.$2.source == widget.source)
        ? span
        : null;
  }

  void _split(TrackSpan span) {
    final command = settledTrackCommand(span.at(widget.playhead).command);
    widget.onSplit(
      _timeline.insertAfter(widget.playhead),
      span.slot.kind == TrackKind.character
          ? command.withArgs({'focus': _timeline.focusAt(widget.playhead)})
          : command,
    );
  }

  int _trimBoundary(TrackSpan span, Offset global) {
    final box = _boardKey.currentContext!.findRenderObject()! as RenderBox;
    return (box.globalToLocal(global).dx / _unit).round().clamp(
      span.start + 1,
      span.end,
    );
  }

  void _finishTrim(TrackSpan span, int boundary) {
    final clear = clearTrack(span.slot);
    if (clear == null || boundary <= span.start || boundary >= span.end) return;
    final address = _timeline.columns[boundary].address;
    widget.onTrim(
      (
        scene: address.scene,
        beat: address.beat,
        command: math.max(0, address.command),
      ),
      span.slot.kind == TrackKind.character
          ? clear.withArgs({'focus': _timeline.focusAt(boundary - 1)})
          : clear,
      [
        for (final (column, value) in span.markers)
          if (column >= boundary && value.field == 'name') value.source,
      ],
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final wide = box.maxWidth >= 690;
      final scheme = Theme.of(context).colorScheme;
      final roles = _roles;
      if (!roles.contains(_role)) _role = null;
      final rows = _rows.toList();
      // 投影与播放头共享地址。窄屏可在轨道和来源参数间来回切换，素材箱始终可拖放。
      final showInspector = _showInspector && widget.source != null;
      final toolbar = _toolbar(roles);
      return ColoredBox(
        color: scheme.surfaceContainerLow,
        child: Column(
          children: [
            if (wide)
              toolbar
            else
              SizedBox(
                height: 70,
                child: Row(
                  children: [
                    SizedBox(width: 124, child: Center(child: widget.monitor)),
                    Expanded(child: toolbar),
                  ],
                ),
              ),
            widget.materials,
            const Divider(height: 1),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: !wide && showInspector
                        ? widget.inspector
                        : _grid(rows),
                  ),
                  if (wide) ...[
                    const VerticalDivider(width: 1),
                    SizedBox(
                      width: 230,
                      child: Column(
                        children: [
                          Flexible(
                            child: SizedBox(
                              height: showInspector ? 105 : 135,
                              child: Center(child: widget.monitor),
                            ),
                          ),
                          if (showInspector) Expanded(child: widget.inspector),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      );
    },
  );

  Set<String> get _roles => {
    for (final entry in _timeline.tracks.entries)
      if (entry.key.kind == TrackKind.character)
        for (final span in entry.value) ...[
          characterTrackBase(span.initial.label),
          for (final marker in span.markers)
            characterTrackBase(marker.$2.label),
        ],
  };

  Widget _toolbar(Set<String> roles) {
    final span = _selectedSpan;
    return SizedBox(
      height: 42,
      child: ListView(
        key: const ValueKey('timeline-toolbar'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        children: [
          Center(child: Text('轨道 · 第 ${_timeline.scene + 1} 幕')),
          const SizedBox(width: 10),
          DropdownButton<TrackKind?>(
            value: _filter,
            onChanged: (kind) => setState(() => _filter = kind),
            items: [
              const DropdownMenuItem(value: null, child: Text('全部类型')),
              for (final kind in TrackKind.values)
                DropdownMenuItem(value: kind, child: Text(kind.label)),
            ],
          ),
          const SizedBox(width: 8),
          if (roles.isNotEmpty)
            DropdownButton<String?>(
              value: _role,
              onChanged: (value) => setState(() => _role = value),
              items: [
                const DropdownMenuItem(value: null, child: Text('全部角色')),
                for (final role in roles)
                  DropdownMenuItem(value: role, child: Text(role)),
              ],
            ),
          const SizedBox(width: 6),
          if (widget.affectedCount > 0)
            Center(child: Text('影响 ${widget.affectedCount} 个分镜')),
          if (widget.source != null) ...[
            IconButton(
              tooltip: _showInspector ? '收起来源参数' : '编辑来源参数（影响整段）',
              onPressed: () => setState(() => _showInspector = !_showInspector),
              icon: Icon(
                _showInspector ? Icons.view_timeline_outlined : Icons.tune,
              ),
            ),
            IconButton(
              tooltip: '在演出台定位来源',
              onPressed: () => widget.onOpen(widget.source!),
              icon: const Icon(Icons.my_location),
            ),
          ],
          IconButton(
            tooltip: '在播放头后插入状态更新（分割区间）',
            onPressed: span != null && widget.playhead + 1 < span.end
                ? () => _split(span)
                : null,
            icon: const Icon(Icons.call_split),
          ),
          IconButton(
            tooltip: '在播放头后裁尾',
            onPressed:
                span != null &&
                    widget.playhead + 1 < span.end &&
                    clearTrack(span.slot) != null
                ? () => _finishTrim(span, widget.playhead + 1)
                : null,
            icon: const Icon(Icons.content_cut),
          ),
          IconButton(
            tooltip: '在此固化状态',
            onPressed: widget.onFreeze,
            icon: const Icon(Icons.push_pin_outlined),
          ),
        ],
      ),
    );
  }

  Widget _grid(List<TrackSlot> rows) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, box) {
        final headWidth = box.maxWidth < 400 ? 88.0 : 129.0;
        final width = math.max(
          _timeline.columns.length * _unit,
          box.maxWidth - headWidth,
        );
        final height = (rows.length + 1) * _row;
        return SingleChildScrollView(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: headWidth,
                child: Column(
                  children: [
                    _header(
                      '分镜 / 指令',
                      '播放头 ${_timeline.columns[widget.playhead].globalEnd}',
                    ),
                    for (final slot in rows)
                      _header(trackSlotLabel(slot), switch (_timeline
                          .spanAt(slot, widget.playhead)
                          ?.at(widget.playhead)) {
                        final value? => _label(value),
                        _ => '—',
                      }),
                  ],
                ),
              ),
              Expanded(
                child: Scrollbar(
                  controller: _horizontal,
                  thumbVisibility: true,
                  child: SingleChildScrollView(
                    controller: _horizontal,
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(
                      key: _boardKey,
                      width: width,
                      height: height,
                      child: Stack(
                        clipBehavior: Clip.hardEdge,
                        children: [
                          for (final (i, range) in _timeline.beats.indexed)
                            Positioned(
                              left: range.$1 * _unit,
                              width: (range.$2 - range.$1) * _unit,
                              top: 0,
                              bottom: 0,
                              child: IgnorePointer(
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: i.isEven
                                        ? scheme.surfaceContainer
                                        : scheme.surface,
                                    border: Border(
                                      left: BorderSide(
                                        color: scheme.outlineVariant,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          _ruler(width),
                          for (final (i, slot) in rows.indexed)
                            Positioned(
                              left: 0,
                              right: 0,
                              top: (i + 1) * _row,
                              height: _row,
                              child: _track(slot),
                            ),
                          Positioned(
                            left: (widget.playhead + .5) * _unit,
                            top: 0,
                            bottom: 0,
                            child: IgnorePointer(
                              child: ColoredBox(
                                color: scheme.onSurface,
                                child: const SizedBox(width: 2),
                              ),
                            ),
                          ),
                          if (_trim case (_, final target))
                            Positioned(
                              left: target * _unit,
                              top: _row,
                              bottom: 0,
                              child: IgnorePointer(
                                child: ColoredBox(
                                  color: scheme.error,
                                  child: const SizedBox(width: 2),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _header(String name, String value) => Container(
    height: _row,
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 6),
    decoration: BoxDecoration(
      border: Border(
        bottom: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
      ),
    ),
    child: Tooltip(
      message: '$name · $value',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelMedium,
          ),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 10, height: 1.1),
          ),
        ],
      ),
    ),
  );

  Widget _ruler(double width) => Positioned(
    left: 0,
    top: 0,
    width: width,
    height: _row,
    child: Stack(
      children: [
        for (final (index, range) in _timeline.beats.indexed)
          Positioned(
            left: range.$1 * _unit,
            width: (range.$2 - range.$1) * _unit,
            top: 0,
            bottom: 0,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '${index + 1} · ${widget.project.scenes[_timeline.scene].beats[index].title}',
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
            ),
          ),
        Positioned.fill(child: _seekSurface()),
      ],
    ),
  );

  Widget _seekSurface() => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTapUp: (event) => widget.onSeek(
      _timeline.columns[_columnAt(event.localPosition.dx)].address,
    ),
    onDoubleTapDown: (event) => widget.onOpen(
      _timeline.columns[_columnAt(event.localPosition.dx)].address,
    ),
    onDoubleTap: () {},
  );

  Widget _track(TrackSlot slot) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      key: ValueKey(('timeline-lane', slot)),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Stack(
        children: [
          Positioned.fill(child: _seekSurface()),
          if (slot.kind.media case final type?)
            Positioned.fill(
              child: DragTarget<TimelineMaterial>(
                key: ValueKey(('timeline-drop', slot)),
                onWillAcceptWithDetails: (details) =>
                    details.data.type == type &&
                    _timeline.spanAt(slot, widget.playhead) == null,
                onAcceptWithDetails: (details) {
                  if (_timeline.spanAt(slot, widget.playhead) != null) return;
                  final material = details.data;
                  final command = trackMaterialCommand(slot, material.key)!;
                  widget.onInsert(_timeline.insertAfter(widget.playhead), [
                    command,
                  ], material.asset);
                },
                builder: (context, candidates, rejected) {
                  final active =
                      candidates.isNotEmpty ||
                      rejected.whereType<TimelineMaterial>().any(
                        (m) => m.type == type,
                      );
                  final occupied =
                      _timeline.spanAt(slot, widget.playhead) != null;
                  final color = occupied ? scheme.error : scheme.primary;
                  return IgnorePointer(
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (active) ...[
                          ColoredBox(color: color.withValues(alpha: .18)),
                          Positioned(
                            left: (widget.playhead + 1) * _unit - 2,
                            top: 0,
                            bottom: 0,
                            width: 2,
                            child: ColoredBox(
                              key: ValueKey((
                                'timeline-insertion',
                                slot,
                                occupied,
                              )),
                              color: color,
                            ),
                          ),
                        ],
                      ],
                    ),
                  );
                },
              ),
            ),
          if (slot.kind == TrackKind.dialogue)
            for (final tick in _timeline.ticks)
              _tick(tick.column, tick.label, tick.speaker),
          for (final (column, event)
              in _timeline.events[slot] ?? const <(int, TrackValue)>[])
            _tick(
              column,
              _label(event),
              '',
              tooltip: _tooltip(event, slot.kind),
              source: event.source,
              missing:
                  event.mediaOrigin != null && widget.missing(event, slot.kind),
            ),
          for (final span in _timeline.tracks[slot] ?? const <TrackSpan>[])
            if (_matchesRole(span)) _clip(span),
        ],
      ),
    );
  }

  Widget _tick(
    int column,
    String label,
    String speaker, {
    String? tooltip,
    TrackAddress? source,
    bool missing = false,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final color = speaker.isEmpty
        ? scheme.secondaryContainer
        : HSLColor.fromAHSL(
            1,
            (speaker.codeUnits.fold(
              0,
              (a, b) => (a * 31 + b) % 360,
            )).toDouble(),
            .44,
            .39,
          ).toColor();
    return Positioned(
      left: column * _unit + 2,
      width: _unit - 3,
      top: 3,
      bottom: 3,
      child: Tooltip(
        message: tooltip ?? (speaker.isEmpty ? label : '$speaker · $label'),
        child: Material(
          color: color,
          child: InkWell(
            onTap: () {
              final cursor = _timeline.columns[column].address;
              if (source == null) {
                widget.onSeek(cursor);
              } else {
                widget.onSelectSource(cursor, source);
                setState(() => _showInspector = true);
              }
            },
            onDoubleTap: () => widget.onOpen(_timeline.columns[column].address),
            child: CustomPaint(
              painter: missing ? _Hatch(scheme.error) : null,
              child: Center(
                child: Text(
                  speaker.isEmpty ? label : speaker,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10,
                    color: speaker.isEmpty
                        ? scheme.onSecondaryContainer
                        : Colors.white,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _clip(TrackSpan span) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final initial = span.initial;
    final inherited = initial.source.scene != _timeline.scene;
    final selected =
        widget.source != null &&
        (initial.dependsOn(widget.source!) ||
            span.markers.any((marker) => marker.$2.dependsOn(widget.source!)));
    final missing = widget.missing(initial, span.slot.kind);
    final type = span.slot.kind.media;
    final media = initial.mediaOrigin;
    final canReplace =
        media != null &&
        widget
                .project
                .scenes[media.$1.scene]
                .beats[media.$1.beat]
                .commands[media.$1.command]
                .raw ==
            null;
    final color = _color(span.slot.kind);
    final width = (span.end - span.start) * _unit;
    final fg = switch (span.slot.kind) {
      TrackKind.background => scheme.onPrimaryContainer,
      TrackKind.blocker => scheme.onSurface,
      _ => Colors.white,
    };
    final content = Material(
      color: color,
      child: CustomPaint(
        painter: inherited || missing
            ? _Hatch(missing ? Colors.redAccent : fg.withValues(alpha: .35))
            : null,
        child: Listener(
          onPointerDown: (event) => _clipColumn =
              (span.start + (event.localPosition.dx / _unit).floor()).clamp(
                span.start,
                span.end - 1,
              ),
          onPointerCancel: (_) => _clipColumn = null,
          child: InkWell(
            onTap: () {
              final column =
                  _clipColumn ??
                  widget.playhead.clamp(span.start, span.end - 1);
              _clipColumn = null;
              widget.onSelectSource(
                _timeline.columns[column].address,
                initial.source,
              );
              setState(() {
                _slot = span.slot;
                _showInspector = true;
              });
            },
            onDoubleTap: () {
              final column =
                  _clipColumn ??
                  widget.playhead.clamp(span.start, span.end - 1);
              _clipColumn = null;
              widget.onOpen(_timeline.columns[column].address);
            },
            child: Padding(
              padding: const EdgeInsets.fromLTRB(5, 0, 9, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '${missing
                      ? '缺失 · '
                      : inherited
                      ? '继承 · '
                      : ''}${_label(initial)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: fg, fontSize: 11),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return Positioned(
      left: span.start * _unit,
      top: 3,
      bottom: 3,
      width: width,
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          border: selected
              ? Border.all(color: scheme.onSurface, width: 2)
              : null,
        ),
        child: Stack(
          children: [
            Positioned.fill(
              child: Tooltip(
                message: _tooltip(
                  initial,
                  span.slot.kind,
                  inherited: inherited,
                ),
                child: type != null && canReplace
                    ? DragTarget<TimelineMaterial>(
                        onWillAcceptWithDetails: (details) =>
                            details.data.type == type,
                        onAcceptWithDetails: (details) =>
                            widget.onReplace(media.$1, media.$2, details.data),
                        builder: (context, candidates, rejected) =>
                            candidates.isEmpty
                            ? content
                            : ColoredBox(
                                color: scheme.primary,
                                child: Padding(
                                  padding: const EdgeInsets.all(2),
                                  child: content,
                                ),
                              ),
                      )
                    : content,
              ),
            ),
            for (final (column, marker) in span.markers)
              Positioned(
                left: (column - span.start) * _unit,
                width: 13,
                top: 0,
                bottom: 0,
                child: Tooltip(
                  message: '立绘状态更新 · ${_tooltip(marker, span.slot.kind)}',
                  child: InkWell(
                    onTap: () {
                      widget.onSelectSource(
                        _timeline.columns[column].address,
                        marker.source,
                      );
                      setState(() {
                        _slot = span.slot;
                        _showInspector = true;
                      });
                    },
                    child: Center(
                      child: ColoredBox(
                        color:
                            widget.source != null &&
                                    marker.dependsOn(widget.source!) ||
                                widget.missing(marker, span.slot.kind)
                            ? scheme.error
                            : fg,
                        child: const SizedBox(width: 3, height: 16),
                      ),
                    ),
                  ),
                ),
              ),
            if (span.end - span.start > 1 && clearTrack(span.slot) != null)
              Positioned(
                right: 0,
                top: 0,
                bottom: 0,
                width: 12,
                child: Tooltip(
                  message: '向左拖动裁尾',
                  child: MouseRegion(
                    cursor: SystemMouseCursors.resizeColumn,
                    child: GestureDetector(
                      key: ValueKey(('timeline-trim', span.slot, span.start)),
                      behavior: HitTestBehavior.opaque,
                      onHorizontalDragStart: (event) => setState(
                        () => _trim = (
                          span,
                          _trimBoundary(span, event.globalPosition),
                        ),
                      ),
                      onHorizontalDragUpdate: (event) => setState(
                        () => _trim = (
                          span,
                          _trimBoundary(span, event.globalPosition),
                        ),
                      ),
                      onHorizontalDragEnd: (event) {
                        setState(() => _trim = null);
                        _finishTrim(
                          span,
                          _trimBoundary(span, event.globalPosition),
                        );
                      },
                      onHorizontalDragCancel: () =>
                          setState(() => _trim = null),
                      child: Center(
                        child: ColoredBox(
                          color: fg.withValues(alpha: .6),
                          child: const SizedBox(width: 2, height: 12),
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
  }

  int? _clipColumn;
}

class _Hatch extends CustomPainter {
  const _Hatch(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    final paint = Paint()..color = color;
    for (var x = -size.height; x < size.width; x += 8) {
      canvas.drawLine(
        Offset(x, size.height),
        Offset(x + size.height, 0),
        paint,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_Hatch oldDelegate) => oldDelegate.color != color;
}
