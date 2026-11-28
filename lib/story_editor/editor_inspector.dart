import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../story_player/script.dart';
import 'editor_preview.dart';
import 'editor_project.dart';

/// 检查器字段分组（P0-5：内容 / 布局 / 时间 / 高级，高级默认收起）。
enum _FieldGroup { content, layout, timing, advanced }

_FieldGroup _groupOf(String tag, EditorField field) {
  if (field.key == 'name' ||
      field.key == 'text' ||
      field.key == 'image' ||
      field.key == 'key' ||
      field.key == 'slot' ||
      field.key == 'alignment' ||
      field.key == 'r' ||
      field.key == 'g' ||
      field.key == 'b' ||
      field.key == 'a') {
    return _FieldGroup.content;
  }
  if (field.key == 'x' ||
      field.key == 'y' ||
      field.key == 'width' ||
      field.key == 'size' ||
      field.key == 'posfrom' ||
      field.key == 'posto' ||
      field.key == 'screenadapt') {
    return _FieldGroup.layout;
  }
  if (field.key == 'fadetime' ||
      field.key == 'duration' ||
      field.key == 'time' ||
      field.key == 'delay' ||
      field.key == 'volume' ||
      field.key == 'crossfade' ||
      field.key == 'loop') {
    return _FieldGroup.timing;
  }
  if (tag == 'bgeffect' || tag == 'effect') {
    return _FieldGroup.advanced;
  }
  return _FieldGroup.advanced;
}

String _groupTitle(_FieldGroup group) => switch (group) {
  _FieldGroup.content => '内容',
  _FieldGroup.layout => '布局',
  _FieldGroup.timing => '时间与音频',
  _FieldGroup.advanced => '高级',
};

/// 单选与多选检查器组件（P0-5）。
///
/// 保持核心 `TextFormField` 渲染顺序与第一期一致：
/// - `dialogue`: 说话人 (0) -> 台词 (1)
/// - `subtitle`: 文字 (0) -> X (1) -> Y (2) -> 宽度 (3) -> 字号 (4)
class EditorInspector extends StatefulWidget {
  const EditorInspector({
    super.key,
    required this.project,
    required this.commands,
    required this.selectedIndices,
    required this.activeIndex,
    required this.formVersion,
    required this.onUpdateCommand,
    required this.onUpdateMany,
    required this.onReplaceSource,
    required this.onPickMedia,
    required this.onResetCommand,
    required this.onFocusTypingEnd,
  });

  final EditorProject project;
  final List<EditCommand> commands;
  final Set<int> selectedIndices;
  final int activeIndex;
  final int formVersion;
  final void Function(Map<String, String> values, {String? typing})
  onUpdateCommand;
  final void Function(Set<int> indices, Map<String, String> values)
  onUpdateMany;
  final void Function(EditCommand next) onReplaceSource;
  final Future<void> Function(EditorField field) onPickMedia;
  final VoidCallback onResetCommand;
  final void Function(String fieldKey) onFocusTypingEnd;

  @override
  State<EditorInspector> createState() => _EditorInspectorState();
}

class _EditorInspectorState extends State<EditorInspector> {
  bool _advancedExpanded = false;
  bool _layoutExpanded = true;
  bool _timingExpanded = true;

  @override
  Widget build(BuildContext context) {
    final validMulti =
        widget.selectedIndices
            .where((i) => i >= 0 && i < widget.commands.length)
            .toList()
          ..sort();
    if (validMulti.length > 1) {
      return _buildMultiInspector(context, validMulti);
    }
    final active =
        widget.activeIndex >= 0 && widget.activeIndex < widget.commands.length
        ? widget.commands[widget.activeIndex]
        : null;
    if (active == null) {
      return const Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('指令属性'),
            subtitle: Text('未选中指令'),
          ),
        ],
      );
    }
    return _buildSingleInspector(context, active);
  }

  /// 多选混合值检查器（P0-3 / P0-5）：展示共同字段与「多个值」占位，修改后统一写入。
  Widget _buildMultiInspector(BuildContext context, List<int> indices) {
    final selected = [for (final i in indices) widget.commands[i]];
    final tags = selected.map((c) => c.tag).toSet();
    final sameTag = tags.length == 1 ? tags.first : null;
    final definition = sameTag != null ? editorFields[sameTag] : null;
    final commonFields =
        definition != null && selected.every((c) => c.raw == null)
        ? definition.$2
        : _sharedCommonFields(selected);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                sameTag != null && definition != null
                    ? '批量属性 · ${definition.$1}（${indices.length} 条）'
                    : '批量属性（已选 ${indices.length} 条）',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          '仅修改的字段会统一写入所选指令，未改字段保持原值。',
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
        if (commonFields.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: Text('所选指令类型不同，无共同可编辑字段；可使用顶部批量操作条复制或删除。'),
          )
        else
          for (final field in commonFields)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: _buildMultiField(context, field, indices, selected),
            ),
      ],
    );
  }

  List<EditorField> _sharedCommonFields(List<EditCommand> selected) {
    if (selected.isEmpty || selected.any((c) => c.raw != null)) return const [];
    final sets = [
      for (final c in selected)
        {
          for (final f in editorFields[c.tag]?.$2 ?? const <EditorField>[])
            f.key: f,
        },
    ];
    final first = sets.first;
    final common = <EditorField>[];
    for (final entry in first.entries) {
      if (sets.skip(1).every((m) => m.containsKey(entry.key))) {
        common.add(entry.value);
      }
    }
    return common;
  }

  Widget _buildMultiField(
    BuildContext context,
    EditorField field,
    List<int> indices,
    List<EditCommand> selected,
  ) {
    final values = {
      for (final c in selected) c.args[field.key] ?? field.initial,
    };
    final mixed = values.length > 1;
    final singleVal = mixed ? '' : values.first;
    final idxSet = indices.toSet();
    final key = ValueKey((
      'multi',
      widget.formVersion,
      field.key,
      indices.join(','),
    ));

    if (field.type == FieldType.toggle) {
      return SwitchListTile(
        key: key,
        contentPadding: EdgeInsets.zero,
        title: Text(field.label),
        subtitle: mixed ? const Text('多个值') : null,
        value: !mixed && (singleVal == 'true' || singleVal == '1'),
        onChanged: (v) => widget.onUpdateMany(idxSet, {field.key: '$v'}),
      );
    }
    if (field.type == FieldType.choice) {
      return DropdownButtonFormField<String>(
        key: key,
        isExpanded: true,
        initialValue: !mixed && field.options.containsKey(singleVal)
            ? singleVal
            : null,
        decoration: InputDecoration(
          labelText: field.label,
          hintText: mixed ? '多个值' : null,
        ),
        items: [
          for (final item in field.options.entries)
            DropdownMenuItem(value: item.key, child: Text(item.value)),
        ],
        onChanged: (v) {
          if (v != null) widget.onUpdateMany(idxSet, {field.key: v});
        },
      );
    }
    return TextFormField(
      key: key,
      initialValue: singleVal,
      decoration: InputDecoration(
        labelText: field.label,
        hintText: mixed ? '多个值（输入后统一写入）' : null,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
      onFieldSubmitted: (v) => widget.onUpdateMany(idxSet, {field.key: v}),
    );
  }

  Widget _buildSingleInspector(BuildContext context, EditCommand current) {
    final definition = editorFields[current.tag];
    if (definition == null || current.raw != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            definition?.$1 ?? '高级指令',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          TextFormField(
            key: ValueKey((widget.formVersion, 'source')),
            initialValue: current.source,
            minLines: 5,
            maxLines: 12,
            keyboardType: TextInputType.multiline,
            decoration: const InputDecoration(
              labelText: '脚本源码',
              helperText: '编辑后会保留为单条指令；格式错误时不会覆盖当前内容。',
              border: OutlineInputBorder(),
            ),
            onChanged: (source) {
              try {
                final parsed = StoryScript.parse(source).commands;
                if (parsed.length != 1) return;
                widget.onReplaceSource(EditCommand.fromScript(parsed.single));
              } on FormatException {
                // 输入中的半成品等待用户继续编辑。
              }
            },
          ),
        ],
      );
    }

    final fields = definition.$2;
    final byGroup = <_FieldGroup, List<EditorField>>{};
    for (final f in fields) {
      byGroup.putIfAbsent(_groupOf(current.tag, f), () => []).add(f);
    }
    final hasMultipleGroups = byGroup.length > 1;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                definition.$1,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            if (fields.isNotEmpty)
              IconButton(
                tooltip: '重置整条指令参数',
                visualDensity: VisualDensity.compact,
                iconSize: 18,
                onPressed: widget.onResetCommand,
                icon: const Icon(Icons.restart_alt),
              ),
          ],
        ),
        if (current.tag == 'blocker') _blockerColorPresets(context, current),
        if (!hasMultipleGroups)
          for (final field in fields)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: _field(context, field, current),
            )
        else ...[
          for (final group in _FieldGroup.values)
            if (byGroup[group] != null && byGroup[group]!.isNotEmpty)
              _buildGroupSection(context, group, byGroup[group]!, current),
        ],
      ],
    );
  }

  Widget _buildGroupSection(
    BuildContext context,
    _FieldGroup group,
    List<EditorField> fields,
    EditCommand current,
  ) {
    final isContent = group == _FieldGroup.content;
    final expanded = switch (group) {
      _FieldGroup.content => true,
      _FieldGroup.layout => _layoutExpanded,
      _FieldGroup.timing => _timingExpanded,
      _FieldGroup.advanced => _advancedExpanded,
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!isContent)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: InkWell(
              borderRadius: BorderRadius.circular(4),
              onTap: () => setState(() {
                switch (group) {
                  case _FieldGroup.layout:
                    _layoutExpanded = !_layoutExpanded;
                  case _FieldGroup.timing:
                    _timingExpanded = !_timingExpanded;
                  case _FieldGroup.advanced:
                    _advancedExpanded = !_advancedExpanded;
                  case _FieldGroup.content:
                    break;
                }
              }),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Icon(
                      expanded ? Icons.expand_more : Icons.chevron_right,
                      size: 16,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _groupTitle(group),
                      style: Theme.of(context).textTheme.labelMedium
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
            ),
          ),
        if (expanded) ...[
          if (group == _FieldGroup.layout &&
              (current.tag == 'background' ||
                  current.tag == 'image' ||
                  current.tag == 'subtitle' ||
                  current.tag == 'charslot' ||
                  current.tag == 'character'))
            _quickCoordinateActions(context, current),
          for (final field in fields)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: _field(context, field, current),
            ),
        ],
      ],
    );
  }

  /// 坐标快捷操作条（居中 / 重置，P0-5）。
  Widget _quickCoordinateActions(BuildContext context, EditCommand current) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        children: [
          ActionChip(
            visualDensity: VisualDensity.compact,
            label: const Text('居中', style: TextStyle(fontSize: 12)),
            onPressed: () {
              if (current.tag == 'charslot') {
                widget.onUpdateCommand({'posto': '0,0'});
              } else if (current.tag == 'character') {
                widget.onUpdateCommand({
                  'xpos1': '0',
                  'ypos1': '0',
                  'xpos2': '0',
                  'ypos2': '0',
                });
              } else if (current.tag == 'subtitle') {
                final w = double.tryParse(current.value('width')) ?? 800;
                final cx = ((1280 - w) / 2).clamp(0, 1279).toStringAsFixed(0);
                widget.onUpdateCommand({'x': cx, 'y': '300'});
              } else {
                widget.onUpdateCommand({'x': '0', 'y': '0'});
              }
            },
          ),
          ActionChip(
            visualDensity: VisualDensity.compact,
            label: const Text('重置坐标', style: TextStyle(fontSize: 12)),
            onPressed: () {
              if (current.tag == 'charslot') {
                widget.onUpdateCommand({'posfrom': '', 'posto': '0,0'});
              } else if (current.tag == 'character') {
                widget.onUpdateCommand({
                  'xpos1': '0',
                  'ypos1': '0',
                  'xpos2': '0',
                  'ypos2': '0',
                });
              } else if (current.tag == 'subtitle') {
                widget.onUpdateCommand({
                  'x': '240',
                  'y': '300',
                  'width': '800',
                  'size': '36',
                });
              } else {
                widget.onUpdateCommand({'x': '0', 'y': '0'});
              }
            },
          ),
        ],
      ),
    );
  }

  /// 遮罩预设色板（黑场 / 白场 / 半透明黑 / 暖红警告，P0-5）。
  Widget _blockerColorPresets(BuildContext context, EditCommand current) {
    const presets = [
      ('黑场', '0', '0', '0', '1', Color(0xFF000000)),
      ('白场', '1', '1', '1', '1', Color(0xFFFFFFFF)),
      ('半透明黑', '0', '0', '0', '0.5', Color(0x88000000)),
      ('透明清除', '0', '0', '0', '0', Color(0x00000000)),
      ('暗红', '0.5', '0.08', '0.08', '0.6', Color(0x99801414)),
    ];
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final (label, r, g, b, a, swatch) in presets)
            ActionChip(
              visualDensity: VisualDensity.compact,
              avatar: Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: swatch,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Theme.of(context).colorScheme.outline,
                  ),
                ),
              ),
              label: Text(label, style: const TextStyle(fontSize: 12)),
              onPressed: () =>
                  widget.onUpdateCommand({'r': r, 'g': g, 'b': b, 'a': a}),
            ),
        ],
      ),
    );
  }

  Widget _field(BuildContext context, EditorField field, EditCommand current) {
    final value = current.args[field.key] ?? field.initial;
    final key = ValueKey((widget.formVersion, field.key));

    if (field.type == FieldType.toggle) {
      return SwitchListTile(
        key: key,
        contentPadding: EdgeInsets.zero,
        title: Text(field.label),
        value: value == 'true' || value == '1',
        onChanged: (v) => widget.onUpdateCommand({field.key: '$v'}),
      );
    }

    // 枚举字段：<=4 项采用分段按钮（P0-5），更直观且一步切换。
    if (field.type == FieldType.choice) {
      if (field.options.length <= 4) {
        final effective = field.options.containsKey(value)
            ? value
            : field.options.keys.first;
        return Column(
          key: key,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(field.label, style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(height: 6),
            SegmentedButton<String>(
              showSelectedIcon: false,
              style: const ButtonStyle(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              segments: [
                for (final item in field.options.entries)
                  ButtonSegment(
                    value: item.key,
                    label: Text(
                      item.value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
              ],
              selected: {effective},
              onSelectionChanged: (next) {
                if (next.isNotEmpty) {
                  widget.onUpdateCommand({field.key: next.first});
                }
              },
            ),
          ],
        );
      }
      return DropdownButtonFormField<String>(
        key: key,
        isExpanded: true,
        initialValue: field.options.containsKey(value) ? value : null,
        decoration: InputDecoration(labelText: field.label),
        items: [
          for (final item in field.options.entries)
            DropdownMenuItem(value: item.key, child: Text(item.value)),
        ],
        onChanged: (v) {
          if (v != null) widget.onUpdateCommand({field.key: v});
        },
      );
    }

    // 媒体字段：缩略图/图标 + 名称 + 来源徽标（本地/PRTS）+ 更换/清除按钮（P0-5）。
    if (isMediaField(field.type)) {
      final asset = widget.project.assets[value];
      final isLocal = value.startsWith('local_');
      final displayName = value.isEmpty ? '未选择' : (asset?.name ?? value);
      return Container(
        key: key,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: Container(
                width: 40,
                height: 40,
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                alignment: Alignment.center,
                child: asset != null && asset.isImage
                    ? Image.memory(
                        asset.bytes,
                        width: 40,
                        height: 40,
                        fit: BoxFit.cover,
                      )
                    : Icon(
                        field.type == FieldType.fx
                            ? Icons.auto_awesome
                            : field.type == FieldType.music ||
                                  field.type == FieldType.sound
                            ? Icons.audiotrack
                            : Icons.perm_media_outlined,
                        size: 20,
                      ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          field.label,
                          style: Theme.of(context).textTheme.labelSmall,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (value.isNotEmpty)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: isLocal
                                ? const Color(0x33A4C6A0)
                                : const Color(0x33A5C7D5),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            isLocal ? '本地' : 'PRTS',
                            style: const TextStyle(fontSize: 10),
                          ),
                        ),
                    ],
                  ),
                  Text(
                    displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: '更换${field.label}',
              visualDensity: VisualDensity.compact,
              iconSize: 18,
              onPressed: () => widget.onPickMedia(field),
              icon: const Icon(Icons.swap_horiz),
            ),
            if (value.isNotEmpty)
              IconButton(
                tooltip: '清除${field.label}',
                visualDensity: VisualDensity.compact,
                iconSize: 18,
                onPressed: () => widget.onUpdateCommand({field.key: ''}),
                icon: const Icon(Icons.close),
              ),
          ],
        ),
      );
    }

    // 音量滑杆（0–1 + dB 显示 + 静音 + 复位 1.0，P0-5）。
    if (field.key == 'volume') {
      final numVal = (double.tryParse(value) ?? 1.0).clamp(0.0, 1.0);
      final db = numVal <= 0.001
          ? '-∞ dB'
          : '${(20 * math.log(numVal) / math.ln10).toStringAsFixed(1)} dB';
      return Column(
        key: key,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${field.label}  $db',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ),
              IconButton(
                tooltip: numVal == 0 ? '恢复音量' : '静音',
                visualDensity: VisualDensity.compact,
                iconSize: 18,
                onPressed: () => widget.onUpdateCommand({
                  field.key: numVal == 0 ? '1' : '0',
                }),
                icon: Icon(numVal == 0 ? Icons.volume_off : Icons.volume_up),
              ),
              TextButton(
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                ),
                onPressed: () => widget.onUpdateCommand({field.key: '1'}),
                child: const Text('1.0', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
          Slider(
            value: numVal,
            min: 0,
            max: 1,
            divisions: 20,
            label: numVal.toStringAsFixed(2),
            onChanged: (v) => widget.onUpdateCommand({
              field.key: v.toStringAsFixed(2),
            }, typing: field.key),
          ),
        ],
      );
    }

    // 时长/淡入淡出/延迟：数值框 + 0–5s 滑杆（P0-5）。
    final isDurationField = const {
      'fadetime',
      'duration',
      'time',
      'delay',
      'crossfade',
    }.contains(field.key);
    final isAlphaOrChannel =
        current.tag == 'blocker' &&
        const {'r', 'g', 'b', 'a'}.contains(field.key);
    final isCoordinate = field.key == 'x' || field.key == 'y';

    final input = Focus(
      key: key,
      onFocusChange: (focused) {
        if (!focused) widget.onFocusTypingEnd(field.key);
      },
      child: TextFormField(
        initialValue: value,
        minLines: field.type == FieldType.multiline ? 3 : 1,
        maxLines: field.type == FieldType.multiline ? 6 : 1,
        keyboardType: field.type == FieldType.number
            ? const TextInputType.numberWithOptions(decimal: true, signed: true)
            : TextInputType.text,
        decoration: InputDecoration(
          labelText: field.label,
          border: const OutlineInputBorder(),
          isDense: true,
          suffixIcon: isCoordinate
              ? GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onHorizontalDragUpdate: (d) {
                    final currentNum = double.tryParse(value) ?? 0;
                    final next = (currentNum + d.delta.dx).clamp(
                      field.key == 'x' ? -1280.0 : -720.0,
                      field.key == 'x' ? 1280.0 : 720.0,
                    );
                    widget.onUpdateCommand({
                      field.key: next.toStringAsFixed(1),
                    }, typing: field.key);
                  },
                  child: const Tooltip(
                    message: '左右拖拽微调数值',
                    child: Icon(Icons.unfold_more_double, size: 16),
                  ),
                )
              : (field.initial.isNotEmpty && value != field.initial
                    ? IconButton(
                        tooltip: '重置为 ${field.initial}',
                        iconSize: 16,
                        onPressed: () =>
                            widget.onUpdateCommand({field.key: field.initial}),
                        icon: const Icon(Icons.refresh),
                      )
                    : null),
        ),
        onChanged: (v) =>
            widget.onUpdateCommand({field.key: v}, typing: field.key),
      ),
    );

    if (isDurationField) {
      final parsed = (double.tryParse(value) ?? 0).clamp(0.0, 5.0);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          input,
          Slider(
            value: parsed,
            min: 0,
            max: 5,
            divisions: 50,
            label: '${parsed.toStringAsFixed(1)}s',
            onChanged: (v) => widget.onUpdateCommand({
              field.key: v.toStringAsFixed(1),
            }, typing: field.key),
          ),
        ],
      );
    }

    if (isAlphaOrChannel) {
      final parsed = (double.tryParse(value) ?? 0).clamp(0.0, 1.0);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          input,
          Slider(
            value: parsed,
            min: 0,
            max: 1,
            divisions: 20,
            label: parsed.toStringAsFixed(2),
            onChanged: (v) => widget.onUpdateCommand({
              field.key: v.toStringAsFixed(2),
            }, typing: field.key),
          ),
        ],
      );
    }

    return input;
  }
}
